//
//  VoiceAudioEngine.swift
//  ClaudeTalkCore
//
//  claude-talk-voice の録音と読み上げを 1 つの AVAudioEngine で行う (段 b の層 1)。
//
//  macOS の voice processing (VPIO: エコー除去・ノイズ抑制・AGC) は、同じ engine の出力を参照信号にして
//  マイクからエコーを消す。別の engine・別のプロセスで鳴らした音は消えない ([事実] research/claude-talk-native-voice.md 3.1)。
//  そのため読み上げ (Qwen の PCM、速さの TimePitch を含む) の PlayerNode をこの engine に繋ぐ (StreamPlayer(host:))。
//
//  もう 1 つの役目: 実際に鳴らした音 (参照信号) を時刻付きで `reference` に残す。割り込みの判定 (EchoGate) が
//  マイクの音と比べて「自分の声の残り」かを決める。
//
//  テスト用の入力 (ScriptedWavInput / WavFileInput) を渡した時はマイクを開かず、VPIO も使わない
//  (出力だけこの engine で鳴らし、参照信号も同じように残す)。
//

@preconcurrency import AVFoundation
import Foundation

public final class VoiceAudioEngine: AudioInput, @unchecked Sendable {
    public struct Options: Sendable, Equatable {
        /// VPIO (エコー除去・ノイズ抑制) を使う
        public var voiceProcessing: Bool = true
        /// VPIO の AGC (自動で音量を上げる)。既定は切る (残りのエコーが 10dB 小さかった: AGC 有り -61dB / 無し -71dB)
        public var agc: Bool = false
        /// VPIO が他のアプリの音を下げる (ducking) 度合い: default / min / mid / max (macOS 14 以降)
        public var ducking: String = "min"
        /// true なら、こちらが話している (音を出している) 時だけ他のアプリの音を下げる (macOS 14 以降)
        public var advancedDucking: Bool = false
        public init() {}
    }

    public let engine = AVAudioEngine()
    public let options: Options
    /// 実際に鳴らした音 (24kHz mono Int16、時刻はスピーカーから出る見込みの時刻)。
    public let reference = AudioRing(retainSeconds: 15)
    private let testInput: AudioInput?
    /// テスト用の入力 (渡した時だけ)
    public var wrappedTestInput: AudioInput? { testInput }
    private let lock = NSLock()
    private var started = false
    private var tapped = false
    private var refConverters: [ObjectIdentifier: AVAudioConverter] = [:]
    private var configObserver: NSObjectProtocol?
    private var ring: AudioRing?
    public private(set) var name: String
    /// VPIO が実際に有効になったか (start の後)
    public private(set) var voiceProcessingActive = false
    /// 状態の変化 (VPIO の有効化・ducking・engine の作り直し) をログに出す口
    public var onEvent: (@Sendable (String, [String: Any]) -> Void)?

    public init(options: Options, testInput: AudioInput? = nil) {
        self.options = options
        self.testInput = testInput
        name = testInput.map { "shared-engine(\($0.name))" } ?? "shared-engine(mic)"
    }

    public func trigger(_ event: String) { testInput?.trigger(event) }

    public func start(into ring: AudioRing) throws {
        self.ring = ring
        if let testInput {
            try testInput.start(into: ring)
            try configureOutput()
            try ensureRunning()
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted: throw TalkError.micPermission
        default: break
        }
        if let dev = AVCaptureDevice.default(for: .audio) { name = "shared-engine(mic: \(dev.localizedName))" }
        let input = engine.inputNode
        if options.voiceProcessing {
            do {
                try input.setVoiceProcessingEnabled(true)
                input.isVoiceProcessingAGCEnabled = options.agc
                if #available(macOS 14.0, *) {
                    let level: AVAudioVoiceProcessingOtherAudioDuckingConfiguration.Level
                    switch options.ducking.lowercased() {
                    case "max": level = .max
                    case "mid": level = .mid
                    case "default": level = .default
                    default: level = .min
                    }
                    input.voiceProcessingOtherAudioDuckingConfiguration =
                        .init(enableAdvancedDucking: ObjCBool(options.advancedDucking), duckingLevel: level)
                }
                voiceProcessingActive = input.isVoiceProcessingEnabled
            } catch {
                // VPIO が使えない機材でも、録音と読み上げは続ける (エコー除去なし)。
                onEvent?("audio.vp_failed", ["error": error.localizedDescription])
                voiceProcessingActive = false
            }
        }
        let hw = input.outputFormat(forBus: 0)
        guard hw.sampleRate > 0, hw.channelCount > 0 else {
            throw TalkError.audio("入力デバイスがありません (システム設定 > サウンド > 入力)")
        }
        try configureOutput()
        installInputTap(ring: ring)
        do {
            try ensureRunning()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            tapped = false
            throw TalkError.audio("録音を開始できません: \(error.localizedDescription)")
        }
        var f: [String: Any] = ["vp": voiceProcessingActive, "agc": voiceProcessingActive && input.isVoiceProcessingAGCEnabled,
                                "input_format": "\(hw)",
                                "output_format": "\(engine.outputNode.outputFormat(forBus: 0))",
                                "output_latency_ms": Int(engine.outputNode.presentationLatency * 1000),
                                "input_latency_ms": Int(input.presentationLatency * 1000)]
        if #available(macOS 14.0, *), voiceProcessingActive {
            let d = input.voiceProcessingOtherAudioDuckingConfiguration
            f["ducking_level"] = d.duckingLevel.rawValue
            f["advanced_ducking"] = d.enableAdvancedDucking.boolValue
        }
        onEvent?("audio.engine_start", f)
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.configurationChanged()
        }
    }

    /// 出力の接続を明示する (VPIO を有効にした engine は mainMixer → output を出力の形式で繋がないと
    /// kAUInitialize が -10875 で失敗する [事実])。
    private func configureOutput() throws {
        let out = engine.outputNode.inputFormat(forBus: 0)
        let rate = out.sampleRate > 0 ? out.sampleRate : 48_000
        guard let f = AVAudioFormat(standardFormatWithSampleRate: rate, channels: max(1, min(out.channelCount, 2))) else {
            throw TalkError.audio("出力の形式を作れません")
        }
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: f)
    }

    private func installInputTap(ring: AudioRing) {
        let input = engine.inputNode
        let outFormat = PCM.outputFormat
        final class Box: @unchecked Sendable { var conv: AVAudioConverter?; var mono: AVAudioFormat? }
        let box = Box()
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, when in
            // VPIO の入力は複数チャンネル (中身は同じ) なので 1 チャンネル目だけ使う。
            guard let mono = Self.firstChannel(buffer, cache: &box.mono) else { return }
            if box.conv == nil || box.conv?.inputFormat != mono.format {
                box.conv = AVAudioConverter(from: mono.format, to: outFormat)
            }
            guard let conv = box.conv, let data = PCM.convert(mono, using: conv, to: outFormat) else { return }
            let dur = PCM.nanoseconds(bytes: data.count)
            let start = Self.uptimeNs(when) ?? { let n = PCM.now(); return n > dur ? n - dur : 0 }()
            ring.append(AudioPiece(start: start, data: data))
        }
        tapped = true
    }

    static func firstChannel(_ b: AVAudioPCMBuffer, cache: inout AVAudioFormat?) -> AVAudioPCMBuffer? {
        if b.format.channelCount == 1 { return b }
        guard let src = b.floatChannelData else { return b }
        if cache == nil || cache!.sampleRate != b.format.sampleRate {
            cache = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: b.format.sampleRate, channels: 1, interleaved: false)
        }
        guard let f = cache, let out = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: b.frameLength),
              let dst = out.floatChannelData else { return nil }
        out.frameLength = b.frameLength
        dst[0].update(from: src[0], count: Int(b.frameLength))
        return out
    }

    /// AVAudioTime の hostTime を PCM.now() と同じ時計 (単調、ns) にする。
    static func uptimeNs(_ t: AVAudioTime) -> UInt64? {
        guard t.isHostTimeValid else { return nil }
        let s = AVAudioTime.seconds(forHostTime: t.hostTime)
        return s > 0 ? UInt64(s * 1e9) : nil
    }

    /// engine が止まっていれば動かす (読み上げの PlayerNode を繋いだ後にも呼ぶ)。
    public func ensureRunning() throws {
        lock.lock(); defer { lock.unlock() }
        if engine.isRunning { return }
        engine.prepare()
        try engine.start()
        started = true
    }

    /// 読み上げの最後の段から届いた音を参照信号に足す (StreamPlayer の tap から呼ばれる)。
    func appendReference(_ buffer: AVAudioPCMBuffer, when: AVAudioTime) {
        let outFormat = PCM.outputFormat
        let key = ObjectIdentifier(buffer.format)
        lock.lock()
        var conv = refConverters[key]
        if conv == nil || conv?.inputFormat != buffer.format {
            conv = AVAudioConverter(from: buffer.format, to: outFormat)
            refConverters = [key: conv!]
        }
        lock.unlock()
        guard let c = conv, let data = PCM.convert(buffer, using: c, to: outFormat) else { return }
        let dur = PCM.nanoseconds(bytes: data.count)
        // tap の時刻は描画した時刻。スピーカーから出るのは出力の遅れの後。
        let latency = UInt64(max(0, engine.outputNode.presentationLatency) * 1e9)
        let start = Self.uptimeNs(when).map { $0 + latency } ?? { let n = PCM.now(); return n > dur ? n - dur : 0 }()
        reference.append(AudioPiece(start: start, data: data))
    }

    private func configurationChanged() {
        // 入出力の機器が変わった (ヘッドホンの抜き差しなど)。engine は止まるので、繋ぎ直して動かす。
        onEvent?("audio.config_change", ["running": engine.isRunning])
        do {
            if testInput == nil, let ring {
                engine.inputNode.removeTap(onBus: 0)
                installInputTap(ring: ring)
            }
            try configureOutput()
            try ensureRunning()
            onEvent?("audio.engine_restart", ["ok": true])
        } catch {
            onEvent?("audio.engine_restart", ["ok": false, "error": error.localizedDescription])
        }
    }

    public func stop() {
        if let o = configObserver { NotificationCenter.default.removeObserver(o); configObserver = nil }
        testInput?.stop()
        if tapped { engine.inputNode.removeTap(onBus: 0); tapped = false }
        engine.stop()
        if voiceProcessingActive { try? engine.inputNode.setVoiceProcessingEnabled(false) }
    }
}
