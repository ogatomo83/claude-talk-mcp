//
//  ReplySpeaker.swift
//  ClaudeTalkCore
//
//  1 つの返事を文ごとに Irodori で読み上げる。文が届いたら順に /v1/audio/speech に頼み、届いた PCM を
//  1 つの PlayerNode に続けて積む (前の文が鳴っている間に次の文を作る)。stop() ですぐ止める (割り込み)。
//
//  テスト用の口: CLAUDE_TALK_TTS_VOLUME=0 (音量 0 で実時間再生)、CLAUDE_TALK_VOICE_TTS_DUMP_DIR=<dir>
//  (返事ごとに、届いた音を <dir>/reply-<turn>.wav に書く。割り込みで止めても届いた分は全部書く)。
//

@preconcurrency import AVFoundation
import Foundation

public final class ReplySpeaker: @unchecked Sendable {
    public struct Progress: Sendable {
        /// 鳴り始めた文の数 / 積んだ文の数
        public var sentencesStarted: Int
        public var sentencesQueued: Int
        /// 聞こえた所までの文 (最後の文は途中のことがある)
        public var heardText: String
        public var playedSeconds: Double
    }

    public enum Stage: Sendable {
        /// その返事の最初の音を積んだ (lead = 頭の無音の秒数)
        case firstAudio(leadSeconds: Double)
        /// 文 i の最初の音が届いた (requestMs = 頼んでから)。starved = その時何も鳴っていなかった
        case sentence(index: Int, chars: Int, firstChunkMs: Int, starved: Bool)
        case error(String)
    }

    private let settings: DirectSettings
    private let volume: Float?
    private let dumpDir: URL?
    private let turn: Int
    private let onStage: @Sendable (Stage) -> Void
    private let lock = NSLock()
    private var queue: [String] = []
    private var closed = false
    private var stopped = false
    private var wake: CheckedContinuation<Void, Never>?
    private var worker: Task<Bool, Never>?
    private var player: StreamPlayer?
    private var currentStream: PCMHTTPStream?
    /// 文 i の音の最初のフレーム位置 (積んだ順)。
    private var sentenceStartFrame: [Int] = []
    private var sentenceTexts: [String] = []
    private var scheduledFrames = 0
    private var dumpFile: AVAudioFile?

    public init(settings: DirectSettings, turn: Int,
                volume: Float? = ProcessInfo.processInfo.environment["CLAUDE_TALK_TTS_VOLUME"].flatMap(Float.init),
                dumpDir: URL? = ProcessInfo.processInfo.environment["CLAUDE_TALK_VOICE_TTS_DUMP_DIR"]
                    .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) },
                onStage: @escaping @Sendable (Stage) -> Void) {
        self.settings = settings
        self.turn = turn
        self.volume = volume
        self.dumpDir = dumpDir
        self.onStage = onStage
        worker = Task.detached { [weak self] in await self?.run() ?? false }
    }

    /// 文を 1 つ積む。
    public func enqueue(_ sentence: String) {
        lock.lock()
        guard !closed, !stopped else { lock.unlock(); return }
        queue.append(sentence)
        let w = wake; wake = nil
        lock.unlock()
        w?.resume()
    }

    /// もう文は来ない。鳴り終わるまで待つ。最後まで鳴らしたら true、止められたら false。
    public func finish() async -> Bool {
        let w: CheckedContinuation<Void, Never>? = locked {
            closed = true
            let w = wake; wake = nil
            return w
        }
        w?.resume()
        return await worker?.value ?? false
    }

    /// すぐ止める。聞こえた所までを返す。
    @discardableResult
    public func stop() -> Progress {
        lock.lock()
        let p = player
        let s = currentStream
        stopped = true
        closed = true
        let w = wake; wake = nil
        lock.unlock()
        // stop() の前に読む (止めると残りのバッファの完了も呼ばれ、playedFrames が増えてしまう)。
        let played = p?.playedFrames ?? 0
        locked { frozenPlayed = played }
        let progress = makeProgress(playedFrames: played)
        s?.cancel()
        p?.stop()
        w?.resume()
        return progress
    }

    public var progress: Progress {
        makeProgress(playedFrames: locked { frozenPlayed } ?? player?.playedFrames ?? 0)
    }

    private var frozenPlayed: Int?

    /// 今、音が鳴っているか (積んだ音が残っている)。
    public var isSounding: Bool { (player?.pendingBuffers ?? 0) > 0 }

    private func makeProgress(playedFrames: Int) -> Progress {
        lock.lock(); defer { lock.unlock() }
        let rate = player?.format.sampleRate ?? 48_000
        var started = 0
        for f in sentenceStartFrame where f <= playedFrames { started += 1 }
        if playedFrames == 0 { started = 0 }
        var heard = ""
        if started > 0 {
            let full = sentenceTexts.prefix(started - 1).joined()
            let last = sentenceTexts[started - 1]
            let startF = sentenceStartFrame[started - 1]
            let endF = started < sentenceStartFrame.count ? sentenceStartFrame[started] : scheduledFrames
            let frac = endF > startF ? min(1, Double(playedFrames - startF) / Double(endF - startF)) : 1
            heard = full + String(last.prefix(Int((Double(last.count) * frac).rounded(.up))))
        }
        return Progress(sentencesStarted: started, sentencesQueued: sentenceTexts.count + queue.count,
                        heardText: heard, playedSeconds: Double(playedFrames) / rate)
    }

    private enum Pick { case sentence(String), done, wait }

    private func pick() -> Pick {
        locked {
            if stopped { return .done }
            if !queue.isEmpty { return .sentence(queue.removeFirst()) }
            return closed ? .done : .wait
        }
    }

    /// 待つ準備: 待たなくてよい時は false。
    private func park(_ c: CheckedContinuation<Void, Never>) -> Bool {
        locked {
            if stopped || closed || !queue.isEmpty { return false }
            wake = c
            return true
        }
    }

    private func next() async -> String? {
        while true {
            switch pick() {
            case .sentence(let s): return s
            case .done: return nil
            case .wait:
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    if !park(c) { c.resume() }
                }
            }
        }
    }

    private var isStopped: Bool { locked { stopped } }

    /// async の中から使うロック (NSLock を直接 async の中で使わない)。
    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    private func run() async -> Bool {
        var index = 0
        var firstAudioSent = false
        while let sentence = await next() {
            let prepared = Readings.prepare(sentence, settings: settings)
            var req = URLRequest(url: settings.ttsBaseURL.appendingPathComponent("v1/audio/speech"))
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: IrodoriSpeaker.requestBody(text: prepared, settings: settings))
            let sw = Stopwatch()
            let stream = PCMHTTPStream(request: req)
            let go: Bool = locked {
                if stopped { return false }
                currentStream = stream
                return true
            }
            if !go { stream.cancel(); break }
            var gotFirst = false
            do {
                for try await ev in stream.events {
                    switch ev {
                    case .header(let rate):
                        if player == nil {
                            let p = try StreamPlayer(sampleRate: rate, outputFile: nil, volume: volume, probe: nil)
                            let ok: Bool = locked {
                                if stopped { return false }
                                player = p
                                return true
                            }
                            if !ok { p.shutdown(); throw CancellationError() }
                            openDump(rate: rate)
                        }
                    case .audio(let data):
                        guard let p = player else { continue }
                        if !gotFirst {
                            gotFirst = true
                            let starved = index > 0 && p.pendingBuffers == 0
                            locked {
                                sentenceStartFrame.append(scheduledFrames)
                                sentenceTexts.append(sentence)
                            }
                            onStage(.sentence(index: index, chars: sentence.count, firstChunkMs: sw.ms, starved: starved))
                            if !firstAudioSent {
                                firstAudioSent = true
                                onStage(.firstAudio(leadSeconds: PCMHTTPStream.leadingSilenceSeconds(data, sampleRate: p.format.sampleRate)))
                            }
                        }
                        try p.schedule(int16: data)
                        locked { scheduledFrames += data.count / 2 }
                        writeDump(data)
                    }
                }
            } catch {
                if isStopped { break }
                onStage(.error("文 \(index): \(error.localizedDescription)"))
            }
            locked { currentStream = nil }
            index += 1
        }
        closeDump()
        guard let p = player else { return !isStopped }
        if isStopped { p.shutdown(); return false }
        let played = await p.finishAndWait()
        p.shutdown()
        return played && !isStopped
    }

    // MARK: 書き出し (テスト用)

    private func openDump(rate: Double) {
        guard let dir = dumpDir else { return }
        TalkPaths.ensureDir(dir)
        let url = dir.appendingPathComponent("reply-\(turn).wav")
        let fileSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        dumpFile = try? AVAudioFile(forWriting: url, settings: fileSettings, commonFormat: .pcmFormatInt16, interleaved: true)
    }

    private func writeDump(_ data: Data) {
        guard let f = dumpFile else { return }
        let frames = AVAudioFrameCount(data.count / 2)
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: frames),
              let ch = buf.int16ChannelData else { return }
        buf.frameLength = frames
        data.withUnsafeBytes { raw in
            let s = raw.bindMemory(to: Int16.self)
            for i in 0..<Int(frames) { ch[0][i] = Int16(littleEndian: s[i]) }
        }
        try? f.write(from: buf)
    }

    private func closeDump() { dumpFile = nil }
}
