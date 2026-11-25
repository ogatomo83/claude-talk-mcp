//
//  IrodoriSpeaker.swift
//  ClaudeTalkCore
//
//  direct モードの読み上げ (speech.cpp の Qwen3-TTS / Irodori-TTS。名前は最初の Irodori のまま)。
//  speech serve の /v1/audio/speech に response_format=pcm で頼み、
//  届いた PCM を届いたそばから AVAudioEngine の PlayerNode で鳴らす (最初の音を早くする)。
//  speak の戻りは「最後の音が鳴り終わった時」: 最後のバッファの .dataPlayedBack (出力まで出た) を待つ。
//
//  AVAudioEngine にしたのは、将来エコー除去 (inputNode の voice processing) を同じ engine で入れられるようにするため。
//  今はマイク (Audio.swift の MicInput) と別の engine。voice processing を入れる時は 1 つの engine にまとめる。
//
//  速さ (ttsSpeed): Irodori は serve の speed、Qwen は PlayerNode と mainMixer の間の AVAudioUnitTimePitch (高さはそのまま)。
//
//  テスト用の口 (音を鳴らさない確認):
//    CLAUDE_TALK_TTS_OUTPUT_FILE=<path.wav> … スピーカーを使わず、engine の offline 描画で WAV に書く
//    CLAUDE_TALK_TTS_VOLUME=0               … 出力の音量 (mainMixer) を 0 にして実時間で再生する
//

@preconcurrency import AVFoundation
import Foundation

/// Irodori の読み上げの失敗。audioStarted が false なら、まだ何も鳴っていない (avspeech に落としてよい)。
public struct IrodoriFailure: LocalizedError {
    public let message: String
    public let audioStarted: Bool
    public var errorDescription: String? { "読み上げ (speech.cpp): \(message)" }
}

/// 1 回の読み上げの時間 (ms、speak を受けてから)。
public struct IrodoriTiming: Sendable {
    public var firstChunkMs: Int?
    /// 応答のヘッダーが届いた時 / 再生の engine が使えるようになった時。
    public var headerMs: Int?
    public var requestMs: Int?
    public var playerReadyMs: Int?
    /// 最初のチャンクの頭の無音を足した「声が出始める」までの目安。
    public var firstVoicedMs: Int?
    public var streamDoneMs: Int?
    public var audioSeconds: Double = 0
}

public final class IrodoriSpeaker: @unchecked Sendable {
    private let lock = NSLock()
    private var current: (stream: PCMHTTPStream, player: StreamPlayer?)?

    public init() {}

    /// 読み上げて、鳴り終わる (または止められる) まで待つ。戻り値: 最後まで鳴らしたら true、止められたら false。
    /// - outputFile: 指定するとスピーカーを使わず WAV に書く (既定は CLAUDE_TALK_TTS_OUTPUT_FILE)
    /// - probe: 実時間の再生で、描画したバッファと時刻を受け取る (測定用)
    public func speak(text: String, settings: DirectSettings,
                      outputFile: URL? = ProcessInfo.processInfo.environment["CLAUDE_TALK_TTS_OUTPUT_FILE"]
                          .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) },
                      volume: Float? = ProcessInfo.processInfo.environment["CLAUDE_TALK_TTS_VOLUME"].flatMap(Float.init),
                      probe: (@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)? = nil,
                      onTiming: (@Sendable (String, IrodoriTiming) -> Void)? = nil) async throws -> Bool {
        let sw = Stopwatch()
        var timing = IrodoriTiming()
        var req = URLRequest(url: settings.ttsBaseURL.appendingPathComponent("v1/audio/speech"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: Self.requestBody(text: text, settings: settings))

        stop()
        // 再生の engine は HTTP の応答を待つ間に作る (Irodori 48 kHz / Qwen 24 kHz。違えば header で作り直す)。
        let expectedRate = settings.ttsProfile.sampleRate
        let speed = settings.ttsLocalSpeed
        let early = Task.detached { () -> StreamPlayer? in
            try? StreamPlayer(sampleRate: expectedRate, outputFile: outputFile, volume: volume, speed: speed, probe: probe)
        }
        let stream = PCMHTTPStream(request: req)
        timing.requestMs = sw.ms
        setCurrent(stream, nil)
        defer { clearCurrent() }

        // 最初の音が来なければ打ち切る (その回は avspeech に落とせる)。
        let gotAudio = FlagBox()
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: UInt64(max(settings.ttsFirstAudioTimeoutSeconds, 0.5) * 1e9))
            if !gotAudio.value { stream.fail("最初の音が \(settings.ttsFirstAudioTimeoutSeconds) 秒で届きません") }
        }
        defer { watchdog.cancel() }

        var player: StreamPlayer?
        defer {
            if player == nil { Task.detached { await early.value?.shutdown() } }
        }
        return try await withTaskCancellationHandler {
            do {
                for try await ev in stream.events {
                    switch ev {
                    case .header(let rate):
                        timing.headerMs = sw.ms
                        var p: StreamPlayer
                        if rate == expectedRate, let e = await early.value {
                            p = e
                        } else {
                            await early.value?.shutdown()
                            p = try StreamPlayer(sampleRate: rate, outputFile: outputFile, volume: volume, speed: speed, probe: probe)
                        }
                        player = p
                        timing.playerReadyMs = sw.ms
                        setCurrent(stream, p)
                    case .audio(let data):
                        guard let p = player else { continue }
                        if timing.firstChunkMs == nil {
                            gotAudio.value = true
                            timing.firstChunkMs = sw.ms
                            let lead = PCMHTTPStream.leadingSilenceSeconds(data, sampleRate: p.format.sampleRate)
                            timing.firstVoicedMs = sw.ms + Int(lead * 1000)
                            onTiming?("first_audio", timing)
                        }
                        try p.schedule(int16: data)
                        timing.audioSeconds += Double(data.count / 2) / p.format.sampleRate / speed
                    }
                }
            } catch {
                player?.stop()
                player?.shutdown()
                if Task.isCancelled { return false }
                throw IrodoriFailure(message: error.localizedDescription, audioStarted: timing.firstChunkMs != nil)
            }
            timing.streamDoneMs = sw.ms
            onTiming?("stream_done", timing)
            guard let p = player else {
                if Task.isCancelled { return false }
                throw IrodoriFailure(message: "音が 1 つも届きません", audioStarted: false)
            }
            let played = await p.finishAndWait()
            p.shutdown()
            return played && !Task.isCancelled
        } onCancel: {
            // MCP の取り消し (Esc) で止める。
            stream.cancel()
            self.stopPlayer()
        }
    }

    private func setCurrent(_ s: PCMHTTPStream, _ p: StreamPlayer?) {
        lock.lock(); current = (s, p); lock.unlock()
    }

    private func clearCurrent() {
        lock.lock(); current = nil; lock.unlock()
    }

    public func stop() {
        lock.lock(); let c = current; lock.unlock()
        c?.stream.cancel()
        c?.player?.stop()
    }

    private func stopPlayer() {
        lock.lock(); let p = current?.player; lock.unlock()
        p?.stop()
    }

    static func requestBody(text: String, settings: DirectSettings) -> [String: Any] {
        var body: [String: Any] = ["input": text, "voice": settings.ttsVoiceName, "response_format": "pcm"]
        if !settings.ttsInstructions.isEmpty { body["instructions"] = settings.ttsInstructions }
        // Qwen3-TTS 0.6B は speed を受け付けない (HTTP 400 unsupported_parameter)。その時は手元で伸縮する。
        if settings.ttsServerSpeed, let speed = settings.ttsSpeed { body["speed"] = speed }
        if let seed = settings.ttsSeed { body["seed"] = seed }
        return body
    }
}

final class FlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var v = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return v }
        set { lock.lock(); v = newValue; lock.unlock() }
    }
}

// MARK: - HTTP の PCM ストリーム

/// `response_format: pcm` の応答を、届いたそばから流す。16-bit LE mono。チャンクは 2 バイト境界に揃える。
final class PCMHTTPStream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Event: Sendable {
        case header(sampleRate: Double)
        case audio(Data)
    }

    let events: AsyncThrowingStream<Event, Error>
    private let cont: AsyncThrowingStream<Event, Error>.Continuation
    private var task: URLSessionDataTask?
    // 以下は delegate のキュー (直列) だけが触る。
    private var status = 0
    private var errorBody = Data()
    private var carry: UInt8?

    init(request: URLRequest) {
        (events, cont) = AsyncThrowingStream<Event, Error>.makeStream()
        super.init()
        // 共有のセッションにタスクごとの delegate を付ける (リクエストごとにセッションを作らない)。
        let t = URLSession.shared.dataTask(with: request)
        t.delegate = self
        task = t
        t.resume()
    }

    func cancel() {
        task?.cancel()
        cont.finish()
    }

    func fail(_ message: String) {
        task?.cancel()
        cont.finish(throwing: TTSError.stream(message))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let http = response as? HTTPURLResponse
        status = http?.statusCode ?? 0
        if status == 200 {
            let rate = Double(http?.value(forHTTPHeaderField: "X-Sample-Rate") ?? "") ?? 48_000
            cont.yield(.header(sampleRate: rate))
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard status == 200 else {
            if errorBody.count < 4096 { errorBody.append(data) }
            return
        }
        var bytes = Data()
        if let c = carry { bytes.append(c); carry = nil }
        bytes.append(data)
        if bytes.count % 2 == 1 { carry = bytes.removeLast() }
        if !bytes.isEmpty { cont.yield(.audio(bytes)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            cont.finish(throwing: TTSError.stream(error.localizedDescription))
        } else if status != 200 {
            let body = String(data: errorBody, encoding: .utf8) ?? ""
            cont.finish(throwing: TTSError.stream("HTTP \(status) \(body.prefix(300))"))
        } else {
            cont.finish()
        }
    }

    /// 頭の無音 (|x| <= 500、約 -36 dBFS) の長さ。
    static func leadingSilenceSeconds(_ data: Data, sampleRate: Double, threshold: Int = 500) -> Double {
        data.withUnsafeBytes { raw -> Double in
            let s = raw.bindMemory(to: Int16.self)
            let i = s.firstIndex { abs(Int($0)) > threshold } ?? s.count
            return Double(i) / sampleRate
        }
    }
}

// MARK: - 再生 (AVAudioEngine + PlayerNode)

/// 届いた PCM を順に鳴らす。finishAndWait() は最後のバッファが出力まで出た (.dataPlayedBack) 時に返る。
/// speed が 1 以外なら PlayerNode → AVAudioUnitTimePitch → mainMixer (高さを変えずに速さだけ変える)。
final class StreamPlayer: @unchecked Sendable {
    let engine: AVAudioEngine
    let node = AVAudioPlayerNode()
    /// 録音と同じ engine (VoiceAudioEngine) に繋いだ時の持ち主。nil なら自分の engine を持つ (今までの動き)。
    private let host: VoiceAudioEngine?
    let format: AVAudioFormat
    let speed: Double
    private let timePitch: AVAudioUnitTimePitch?
    private let file: AVAudioFile?
    private let renderBuffer: AVAudioPCMBuffer?
    private let lock = NSLock()
    private var pending = 0
    private var inputDone = false
    private var stopped = false
    private var waiter: CheckedContinuation<Bool, Never>?
    private var result: Bool?
    private var tapped = false
    /// offline 描画 (WAV) で、積んだ入力のフレーム数 / 描画した出力のフレーム数。
    private var fileInFrames = 0
    private var fileOutFrames = 0

    init(sampleRate: Double, outputFile: URL?, volume: Float?, speed: Double = 1,
         probe: (@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)?, host: VoiceAudioEngine? = nil) throws {
        guard let f = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw TTSError.stream("再生の形式を作れません (\(sampleRate) Hz)")
        }
        format = f
        self.host = outputFile == nil ? host : nil
        engine = self.host?.engine ?? AVAudioEngine()
        self.speed = speed
        engine.attach(node)
        if abs(speed - 1) > 0.001 {
            let tp = AVAudioUnitTimePitch()
            tp.rate = Float(speed)
            engine.attach(tp)
            timePitch = tp
        } else {
            timePitch = nil
        }
        // 最後の段 (mainMixer の手前)。測定の probe はここに付ける (聞こえる音そのもの)。
        let last: AVAudioNode = timePitch ?? node
        tapNode = last
        if let outputFile {
            try engine.enableManualRenderingMode(.offline, format: f, maximumFrameCount: 4096)
            Self.wire(engine, node, timePitch, f)
            let fileSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            ]
            file = try AVAudioFile(forWriting: outputFile, settings: fileSettings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
            renderBuffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096)
        } else if let host = self.host {
            // 録音と同じ engine に繋ぐ (VPIO はこの engine の出力を参照信号にしてエコーを消す)。
            // 音量は mainMixer ではなく自分のノードで下げる (録音側や他の返事に影響しない)。
            file = nil
            renderBuffer = nil
            Self.wire(engine, node, timePitch, f)
            if let volume { node.volume = max(0, min(volume, 1)) }
            // 参照信号 (実際に鳴らした音) を host に渡す。測定の probe も同じ所で受ける。
            last.installTap(onBus: 0, bufferSize: 1024, format: f) { buf, when in
                host.appendReference(buf, when: when)
                probe?(buf, when)
            }
            tapped = true
            try host.ensureRunning()
            node.play()
            return
        } else {
            file = nil
            renderBuffer = nil
            Self.wire(engine, node, timePitch, f)
            if let volume { engine.mainMixerNode.outputVolume = max(0, min(volume, 1)) }
            if let probe {
                last.installTap(onBus: 0, bufferSize: 1024, format: f) { buf, when in probe(buf, when) }
                tapped = true
            }
        }
        engine.prepare()
        try engine.start()
        node.play()
    }

    private let tapNode: AVAudioNode

    private static func wire(_ engine: AVAudioEngine, _ node: AVAudioPlayerNode, _ tp: AVAudioUnitTimePitch?, _ f: AVAudioFormat) {
        if let tp {
            engine.connect(node, to: tp, format: f)
            engine.connect(tp, to: engine.mainMixerNode, format: f)
        } else {
            engine.connect(node, to: engine.mainMixerNode, format: f)
        }
    }

    /// offline 描画で、入力が足りている所まで出力を描画する。flush なら残りと伸縮の遅れの分まで全部。
    private func renderFile(flush: Bool) throws {
        guard let file, let rb = renderBuffer else { return }
        let target: Int
        if flush {
            // 残りを描き切る。PlayerNode は offline でも最初の音を少し (実測 0.1 s) 遅れて出し、伸縮はさらに latency 分遅れるので、
            // その分 (+ 余裕) を足す。足した分は無音。
            let tail = Int(((timePitch?.latency ?? 0) + 0.3) * format.sampleRate)
            target = Int((Double(fileInFrames) / speed).rounded(.up)) + tail
        } else if timePitch == nil {
            target = fileInFrames
        } else {
            // 伸縮は先の入力を少し読むので、4096 フレームの余裕を残して描く (途中で入力が尽きて隙間が入らないように)
            target = max(0, Int(Double(fileInFrames - 4096) / speed))
        }
        while fileOutFrames < target {
            let n = AVAudioFrameCount(min(target - fileOutFrames, Int(rb.frameCapacity)))
            let st = try engine.renderOffline(n, to: rb)
            guard st == .success else { throw TTSError.stream("offline 描画に失敗 (\(st.rawValue))") }
            try file.write(from: rb)
            fileOutFrames += Int(n)
        }
    }

    /// 16-bit LE mono を 1 つ足す。
    func schedule(int16 data: Data) throws {
        let frames = AVAudioFrameCount(data.count / 2)
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let ch = buf.floatChannelData else { return }
        buf.frameLength = frames
        data.withUnsafeBytes { raw in
            let s = raw.bindMemory(to: Int16.self)
            for i in 0..<Int(frames) { ch[0][i] = Float(Int16(littleEndian: s[i])) / 32768 }
        }
        if file != nil {
            node.scheduleBuffer(buf, completionHandler: nil)
            fileInFrames += Int(frames)
            try renderFile(flush: false)
            return
        }
        lock.lock()
        if stopped { lock.unlock(); return }
        pending += 1
        lock.unlock()
        node.scheduleBuffer(buf, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            self?.bufferPlayed(frames)
        }
    }

    private var _playedFrames: Int = 0

    /// 鳴り終わったバッファのフレーム数の合計 (どこまで聞こえたかの目安。バッファ単位)。
    var playedFrames: Int {
        lock.lock(); defer { lock.unlock() }
        return _playedFrames
    }

    /// まだ鳴り終わっていないバッファの数 (0 なら今は何も鳴っていない)。
    var pendingBuffers: Int {
        lock.lock(); defer { lock.unlock() }
        return pending
    }

    private func bufferPlayed(_ frames: AVAudioFrameCount) {
        lock.lock()
        _playedFrames += Int(frames)
        pending -= 1
        let done = inputDone && pending == 0
        let ok = !stopped
        lock.unlock()
        if done { resolve(ok) }
    }

    /// もう足さない。鳴り終わるまで待つ。最後まで鳴ったら true、stop() されたら false。
    func finishAndWait() async -> Bool {
        if file != nil {
            do { try renderFile(flush: true) } catch { return false }
            return true
        }
        let played = await waitPlayedBack()
        // 伸縮を掛けた時は、TimePitch の中に残った分 (latency) が鳴り終わるまで待つ。
        if played, let tp = timePitch, tp.latency > 0 {
            try? await Task.sleep(nanoseconds: UInt64(tp.latency * 1e9))
        }
        return played && !isStopped
    }

    private var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    private func waitPlayedBack() async -> Bool {
        return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            lock.lock()
            inputDone = true
            if let r = result {
                lock.unlock()
                c.resume(returning: r)
                return
            }
            waiter = c
            let done = pending == 0
            let ok = !stopped
            lock.unlock()
            if done { resolve(ok) }
        }
    }

    private func resolve(_ ok: Bool) {
        lock.lock()
        if result == nil { result = ok }
        let r = result!
        let w = waiter
        waiter = nil
        lock.unlock()
        w?.resume(returning: r)
    }

    /// すぐ止める (待っている finishAndWait は false で返る)。
    func stop() {
        lock.lock()
        stopped = true
        inputDone = true
        lock.unlock()
        node.stop()
        resolve(false)
    }

    func shutdown() {
        if tapped { tapNode.removeTap(onBus: 0); tapped = false }
        node.stop()
        if host != nil {
            // 共有の engine は止めない (録音が続いている)。自分のノードだけ外す。
            if let tp = timePitch { engine.disconnectNodeOutput(tp); engine.detach(tp) }
            engine.disconnectNodeOutput(node)
            engine.detach(node)
        } else {
            engine.stop()
        }
    }
}
