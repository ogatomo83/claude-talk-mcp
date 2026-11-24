//
//  Audio.swift
//  ClaudeTalkCore
//
//  録音した音 (24kHz mono Int16 LE、speech.cpp の Realtime の形) を時刻付きで溜めるリングと、
//  その入力 (マイク = AVAudioEngine / テスト用の WAV ファイル)。
//

@preconcurrency import AVFoundation
import Foundation

public enum PCM {
    public static let sampleRate = 24_000
    public static let bytesPerSecond = sampleRate * 2

    public static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    public static func nanoseconds(bytes: Int) -> UInt64 {
        UInt64(bytes / 2) * 1_000_000_000 / UInt64(sampleRate)
    }

    public static func bytes(nanoseconds ns: UInt64) -> Int {
        Int(ns * UInt64(sampleRate) / 1_000_000_000) * 2
    }

    /// Int16 LE の最大振幅 (0〜32768)。
    public static func peakAbs(_ data: Data) -> Int {
        data.withUnsafeBytes { raw -> Int in
            let samples = raw.bindMemory(to: Int16.self)
            var peak = 0
            for s in samples {
                let v = s == Int16.min ? 32768 : Int(abs(s))
                if v > peak { peak = v }
            }
            return peak
        }
    }

    /// 任意の形式のバッファを 24kHz mono Int16 に変換する (ストリーム用。同じ converter を使い続ける)。
    static func convert(_ buffer: AVAudioPCMBuffer, using converter: AVAudioConverter, to outFormat: AVAudioFormat) -> Data? {
        let ratio = outFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, let ch = out.int16ChannelData, out.frameLength > 0 else { return nil }
        return Data(bytes: ch[0], count: Int(out.frameLength) * 2)
    }

    public static var outputFormat: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(sampleRate), channels: 1, interleaved: true)!
    }

    /// 音声ファイル (WAV / AIFF など AVAudioFile が読めるもの) を丸ごと 24kHz mono Int16 にする。
    public static func loadFile(_ url: URL) throws -> Data {
        let file = try AVAudioFile(forReading: url)
        let inFormat = file.processingFormat
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw TalkError.audio("WAV のバッファを作れません")
        }
        try file.read(into: inBuf)
        let outFormat = outputFormat
        guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw TalkError.audio("WAV の変換器を作れません (\(inFormat))")
        }
        let ratio = outFormat.sampleRate / inFormat.sampleRate
        let cap = AVAudioFrameCount(Double(inBuf.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: cap) else {
            throw TalkError.audio("WAV の出力バッファを作れません")
        }
        var given = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, st in
            if given {
                st.pointee = .endOfStream
                return nil
            }
            given = true
            st.pointee = .haveData
            return inBuf
        }
        if status == .error { throw TalkError.audio("WAV の変換に失敗: \(error?.localizedDescription ?? "")") }
        guard let ch = out.int16ChannelData else { throw TalkError.audio("WAV の変換結果が空") }
        return Data(bytes: ch[0], count: Int(out.frameLength) * 2)
    }
}

/// 時刻付きの音の断片。start は最初のサンプルの単調時刻 (ns)。
public struct AudioPiece: Sendable {
    public let start: UInt64
    public let data: Data
    public var end: UInt64 { start &+ PCM.nanoseconds(bytes: data.count) }

    /// `since` より後の部分 (サンプル境界にそろえる)。全部 `since` 以前なら nil。
    public func sliced(from since: UInt64) -> AudioPiece? {
        guard end > since else { return nil }
        if start >= since { return self }
        let skip = min(PCM.bytes(nanoseconds: since - start), data.count)
        let rest = data.subdata(in: skip..<data.count)
        return rest.isEmpty ? nil : AudioPiece(start: start + PCM.nanoseconds(bytes: skip), data: rest)
    }
}

/// 録った音を一定時間ぶん残しておくリング。listen は「この時刻から後」をまとめて受け取り (プリロール)、
/// その後は届いた順に受け取る。
public final class AudioRing: @unchecked Sendable {
    private let lock = NSLock()
    private var pieces: [AudioPiece] = []
    private let retainNs: UInt64
    private var subscribers: [Int: AsyncStream<AudioPiece>.Continuation] = [:]
    private var nextId = 0
    private var _firstDataAt: UInt64?
    private var _lastDataAt: UInt64?
    private var _peak = 0
    private var _bytes = 0

    public init(retainSeconds: Double = 15) {
        retainNs = UInt64(retainSeconds * 1_000_000_000)
    }

    public func append(_ piece: AudioPiece) {
        lock.lock()
        pieces.append(piece)
        let cutoff = piece.end > retainNs ? piece.end - retainNs : 0
        while let first = pieces.first, first.end < cutoff { pieces.removeFirst() }
        if _firstDataAt == nil { _firstDataAt = piece.start }
        _lastDataAt = piece.end
        _peak = max(_peak, PCM.peakAbs(piece.data))
        _bytes += piece.data.count
        let subs = Array(subscribers.values)
        lock.unlock()
        for s in subs { s.yield(piece) }
    }

    /// 入力を開け直した時に呼ぶ (統計を消す)。
    public func reset() {
        lock.lock()
        pieces.removeAll()
        _firstDataAt = nil
        _lastDataAt = nil
        _peak = 0
        _bytes = 0
        lock.unlock()
    }

    public struct Stats: Sendable {
        public let firstDataAt: UInt64?
        public let lastDataAt: UInt64?
        public let peak: Int
        public let bytes: Int
    }

    public var stats: Stats {
        lock.lock(); defer { lock.unlock() }
        return Stats(firstDataAt: _firstDataAt, lastDataAt: _lastDataAt, peak: _peak, bytes: _bytes)
    }

    /// `since` 以降に録った音 (残っている分) と、これから届く音の流れ。
    public func subscribe(since: UInt64) -> (backlog: [AudioPiece], stream: AsyncStream<AudioPiece>, id: Int) {
        let (stream, cont) = AsyncStream<AudioPiece>.makeStream(bufferingPolicy: .unbounded)
        lock.lock()
        let id = nextId
        nextId += 1
        subscribers[id] = cont
        var backlog: [AudioPiece] = []
        for p in pieces { if let piece = p.sliced(from: since) { backlog.append(piece) } }
        lock.unlock()
        return (backlog, stream, id)
    }

    public func unsubscribe(_ id: Int) {
        lock.lock()
        let c = subscribers.removeValue(forKey: id)
        lock.unlock()
        c?.finish()
    }
}

/// 音の入力。
public protocol AudioInput: AnyObject, Sendable {
    var name: String { get }
    func start(into ring: AudioRing) throws
    func stop()
    /// テスト用の WAV 入力で「ここで話し始める」合図。マイクでは何もしない。
    func trigger(_ event: String)
}

public extension AudioInput {
    func trigger(_ event: String) {}
}

/// マイク (既定の入力デバイス) を AVAudioEngine で録る。
public final class MicInput: AudioInput, @unchecked Sendable {
    private var engine: AVAudioEngine?
    public private(set) var name = "mic"

    public init() {}

    public func start(into ring: AudioRing) throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted:
            throw TalkError.micPermission
        default:
            break
        }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let hw = input.outputFormat(forBus: 0)
        guard hw.sampleRate > 0, hw.channelCount > 0 else {
            throw TalkError.audio("入力デバイスがありません (システム設定 > サウンド > 入力)")
        }
        if let dev = AVCaptureDevice.default(for: .audio) { name = "mic: \(dev.localizedName)" }
        let outFormat = PCM.outputFormat
        final class Box: @unchecked Sendable { var conv: AVAudioConverter? }
        let box = Box()
        input.removeTap(onBus: 0)
        // format nil = 入力ノードの実際の形式 (固定すると形式違いで例外になる)。
        input.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
            let now = PCM.now()
            if box.conv == nil || box.conv?.inputFormat != buffer.format {
                box.conv = AVAudioConverter(from: buffer.format, to: outFormat)
            }
            guard let conv = box.conv, let data = PCM.convert(buffer, using: conv, to: outFormat) else { return }
            let dur = PCM.nanoseconds(bytes: data.count)
            ring.append(AudioPiece(start: now > dur ? now - dur : 0, data: data))
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw TalkError.audio("録音を開始できません: \(error.localizedDescription)")
        }
        self.engine = engine
    }

    public func stop() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }
}

/// テスト用: マイクの代わりに WAV を実時間で流す。`trigger` の合図で WAV の頭から流し、それ以外は部屋の音
/// (小さな雑音)。`silent` なら全部 0 (許可が無い時のマイク)、`nodata` なら何も届かない。
///
/// 環境変数 `CLAUDE_TALK_TEST_WAV` = WAV のパス | `silent` | `nodata`
///         `CLAUDE_TALK_TEST_WAV_TRIGGER` = `listen` (既定) | `speak_done`
///         `CLAUDE_TALK_TEST_WAV_DELAY_MS` = 合図から話し始めまで (既定 300)
public final class WavFileInput: AudioInput, @unchecked Sendable {
    public enum Kind { case file(Data), silent, noData }

    public let name: String
    private let kind: Kind
    private let triggerEvent: String
    private let delayMs: Int
    private let queue = DispatchQueue(label: "claude-talk.wav-input")
    private var timer: DispatchSourceTimer?
    private let lock = NSLock()
    private var playOffset: Int?
    private var playStartAt: UInt64 = 0
    private var rng = SystemRandomNumberGenerator()

    public init(spec: String, trigger: String = "listen", delayMs: Int = 300) throws {
        triggerEvent = trigger
        self.delayMs = delayMs
        switch spec {
        case "silent": kind = .silent; name = "test: silent"
        case "nodata": kind = .noData; name = "test: nodata"
        default:
            let url = URL(fileURLWithPath: (spec as NSString).expandingTildeInPath)
            kind = .file(try PCM.loadFile(url))
            name = "test: \(url.lastPathComponent)"
        }
    }

    public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) throws -> WavFileInput? {
        guard let spec = env["CLAUDE_TALK_TEST_WAV"], !spec.isEmpty else { return nil }
        return try WavFileInput(spec: spec,
                                trigger: env["CLAUDE_TALK_TEST_WAV_TRIGGER"] ?? "listen",
                                delayMs: Int(env["CLAUDE_TALK_TEST_WAV_DELAY_MS"] ?? "") ?? 300)
    }

    /// WAV の中で話し終わる位置 (ms)。末尾の小さな音は無音とみなす。テストの時間の表に使う。
    public var speechEndMs: Int? {
        guard case .file(let data) = kind else { return nil }
        return data.withUnsafeBytes { raw -> Int in
            let s = raw.bindMemory(to: Int16.self)
            var last = 0
            for i in 0..<s.count where abs(Int(s[i])) > 500 { last = i }
            return last * 1000 / PCM.sampleRate
        }
    }

    public func start(into ring: AudioRing) throws {
        if case .noData = kind { return }
        let chunkBytes = PCM.bytesPerSecond * 40 / 1000
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(40), leeway: .milliseconds(2))
        var nextStart = PCM.now()
        t.setEventHandler { [weak self] in
            guard let self else { return }
            // 遅れた分は追いつくまで続けて出す (実時間の速さを保つ)。
            while nextStart <= PCM.now() {
                let piece = AudioPiece(start: nextStart, data: self.nextChunk(bytes: chunkBytes, at: nextStart))
                ring.append(piece)
                nextStart = piece.end
            }
        }
        timer = t
        t.resume()
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    public func trigger(_ event: String) {
        guard event == triggerEvent, case .file = kind else { return }
        lock.lock()
        playOffset = 0
        playStartAt = PCM.now() + UInt64(delayMs) * 1_000_000
        lock.unlock()
        // 時間の表のため、WAV の中で本当に話し終わる時刻を残す。
        let startDate = Date().addingTimeInterval(Double(delayMs) / 1000)
        let endDate = startDate.addingTimeInterval(Double(speechEndMs ?? 0) / 1000)
        TimingLog.shared.event("test.wav_play", mode: .direct, fields: [
            "trigger": event, "file": name,
            "speech_begin_at": Int64((startDate.timeIntervalSince1970 * 1000).rounded()),
            "speech_end_at": Int64((endDate.timeIntervalSince1970 * 1000).rounded())])
    }

    private func nextChunk(bytes: Int, at start: UInt64) -> Data {
        var out = Data(count: bytes)
        if case .silent = kind { return out }
        lock.lock()
        defer { lock.unlock() }
        out.withUnsafeMutableBytes { raw in
            let s = raw.bindMemory(to: Int16.self)
            for i in 0..<s.count { s[i] = Int16.random(in: -40...40, using: &rng) }
        }
        guard case .file(let wav) = kind, var off = playOffset, start + PCM.nanoseconds(bytes: bytes) > playStartAt else {
            return out
        }
        // 話し始めの位置 (チャンクの途中なら途中から)。
        let lead = start >= playStartAt ? 0 : PCM.bytes(nanoseconds: playStartAt - start)
        let n = min(bytes - lead, wav.count - off)
        if n > 0 {
            out.replaceSubrange(lead..<(lead + n), with: wav.subdata(in: off..<(off + n)))
            off += n
        }
        playOffset = off >= wav.count ? nil : off
        return out
    }
}
