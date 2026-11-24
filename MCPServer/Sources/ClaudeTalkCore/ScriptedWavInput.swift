//
//  ScriptedWavInput.swift
//  ClaudeTalkCore
//
//  テスト用: マイクの代わりに、決めた順で WAV を実時間で流す (claude-talk-voice の確かめ用)。
//  各 WAV は「前の WAV を流し始めた後に、指定の合図が来てから delay ms 後」に流れる。それ以外は小さな雑音。
//
//  書式 (環境変数 CLAUDE_TALK_VOICE_TEST_SCRIPT): `パス@合図+ms;パス@合図+ms;…`
//    合図: ready (聞き始めた) / tts_audio (返事の最初の音) / reply_done (返事を読み終えた) / sent (claude に送った)
//    例: `/tmp/q1.wav@ready+300;/tmp/q2.wav@tts_audio+1500;/tmp/q3.wav@reply_done+500`
//

import Foundation

public final class ScriptedWavInput: AudioInput, @unchecked Sendable {
    public struct Clip: Sendable {
        public let name: String
        public let data: Data
        public let trigger: String
        public let delayMs: Int
    }

    public let name: String
    public let clips: [Clip]
    private let queue = DispatchQueue(label: "claude-talk.scripted-input")
    private var timer: DispatchSourceTimer?
    private let lock = NSLock()
    private var nextClip = 0
    private var playing: (clip: Int, offset: Int, startAt: UInt64)?
    /// 全部流し終えた時に呼ぶ。
    public var onFinished: (@Sendable () -> Void)?
    private var finishedReported = false

    public init(clips: [Clip]) {
        self.clips = clips
        name = "test-script: \(clips.map(\.name).joined(separator: ","))"
    }

    public static func parse(_ spec: String) throws -> [Clip] {
        try spec.split(separator: ";").map { part in
            let s = part.trimmingCharacters(in: .whitespaces)
            guard let at = s.lastIndex(of: "@") else { throw TalkError.audio("スクリプトの書式: パス@合図+ms (\(s))") }
            let path = String(s[..<at])
            let rest = s[s.index(after: at)...]
            let bits = rest.split(separator: "+", maxSplits: 1)
            let trigger = String(bits.first ?? "ready")
            let delay = bits.count > 1 ? Int(bits[1]) ?? 0 : 0
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            return Clip(name: url.lastPathComponent, data: try PCM.loadFile(url), trigger: trigger, delayMs: delay)
        }
    }

    public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) throws -> ScriptedWavInput? {
        guard let spec = env["CLAUDE_TALK_VOICE_TEST_SCRIPT"], !spec.isEmpty else { return nil }
        return ScriptedWavInput(clips: try parse(spec))
    }

    public func start(into ring: AudioRing) throws {
        let chunkBytes = PCM.bytesPerSecond * 40 / 1000
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(40), leeway: .milliseconds(2))
        var nextStart = PCM.now()
        t.setEventHandler { [weak self] in
            guard let self else { return }
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
        lock.lock()
        guard playing == nil || playing!.offset >= clips[playing!.clip].data.count,
              nextClip < clips.count, clips[nextClip].trigger == event else { lock.unlock(); return }
        let i = nextClip
        nextClip += 1
        let startAt = PCM.now() + UInt64(clips[i].delayMs) * 1_000_000
        playing = (i, 0, startAt)
        lock.unlock()
        let startDate = Date().addingTimeInterval(Double(clips[i].delayMs) / 1000)
        let endDate = startDate.addingTimeInterval(Double(Self.speechEndMs(clips[i].data)) / 1000)
        lock.lock(); _lastSpeechEnd = endDate; lock.unlock()
        TimingLog.shared.event("test.wav_play", modeName: "voice", fields: [
            "trigger": event, "file": clips[i].name, "clip": i,
            "speech_begin_at": Int64((startDate.timeIntervalSince1970 * 1000).rounded()),
            "speech_end_at": Int64((endDate.timeIntervalSince1970 * 1000).rounded())])
    }

    /// 次の WAV の話し終わりの時刻を外から知るため (テストの時間の表)。
    public static func speechEndMs(_ data: Data) -> Int {
        data.withUnsafeBytes { raw -> Int in
            let s = raw.bindMemory(to: Int16.self)
            var last = 0
            for i in 0..<s.count where abs(Int(s[i])) > 500 { last = i }
            return last * 1000 / PCM.sampleRate
        }
    }

    private var _lastSpeechEnd: Date?
    /// 最後に流し始めた WAV の中で、本当に話し終わる時刻 (テストの「話し終え」に使う)。
    public var lastSpeechEnd: Date? {
        lock.lock(); defer { lock.unlock() }
        return _lastSpeechEnd
    }

    public var allPlayed: Bool {
        lock.lock(); defer { lock.unlock() }
        guard nextClip >= clips.count else { return false }
        guard let p = playing else { return true }
        return p.offset >= clips[p.clip].data.count
    }

    private func nextChunk(bytes: Int, at start: UInt64) -> Data {
        var out = Data(count: bytes)
        out.withUnsafeMutableBytes { raw in
            let s = raw.bindMemory(to: Int16.self)
            for i in 0..<s.count { s[i] = Int16.random(in: -40...40) }
        }
        lock.lock()
        defer { lock.unlock() }
        guard var p = playing, start + PCM.nanoseconds(bytes: bytes) > p.startAt else { return out }
        let wav = clips[p.clip].data
        guard p.offset < wav.count else { return out }
        let lead = start >= p.startAt ? 0 : PCM.bytes(nanoseconds: p.startAt - start)
        let n = min(bytes - lead, wav.count - p.offset)
        if n > 0 {
            out.replaceSubrange(lead..<(lead + n), with: wav.subdata(in: p.offset..<(p.offset + n)))
            p.offset += n
        }
        playing = p
        if p.offset >= wav.count, nextClip >= clips.count, !finishedReported {
            finishedReported = true
            let cb = onFinished
            queue.async { cb?() }
        }
        return out
    }
}
