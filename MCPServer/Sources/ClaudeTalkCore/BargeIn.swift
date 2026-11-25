//
//  BargeIn.swift
//  ClaudeTalkCore
//
//  direct モードの speak の割り込み (T-0035)。claude-talk-voice の段 b と同じ部品を使う:
//    - 録音と読み上げを 1 つの AVAudioEngine (VoiceAudioEngine、VPIO・AGC 切り) で行い、鳴らした音を参照信号に残す
//    - 読み上げの間も speech serve の Realtime (Silero VAD) に流し、話し始めから bargeInMs たってもまだ話していて、
//      EchoGate が「人の声」と言ったら読み上げを止めて speak を返す (足りなければ発話が続く間 100ms ごとに見直す)
//    - 割り込んだ発話は、直後の listen が話し始めから受け取る (DirectEngine の handoff)
//  設定は direct/settings.json の "bargeIn" ({"bargeIn": {"enabled": false}} で今までの動きに戻る)。
//

import Foundation

/// direct/settings.json の "bargeIn"。全項目省略可。
public struct BargeInSettings: Codable, Equatable, Sendable {
    /// false なら今までの speak (録音と別の engine で鳴らし、割り込まない)。
    public var enabled: Bool = true
    /// 読み上げ中に話し始めてから、この ms 話し続けたら止める (短い相づち・物音で止めない)。
    public var bargeInMs: Int = 300
    /// VPIO (エコー除去・ノイズ抑制)。ヘッドホンなら false でもよい。
    public var voiceProcessing: Bool = true
    public var vpAGC: Bool = false
    public var vpDucking: String = "min"
    public var vpAdvancedDucking: Bool = false
    /// 人の声か、読み上げの残りかの判定 (enabled=false なら VAD と bargeInMs だけで止める)。
    public var echoGate: EchoGateConfig = EchoGateConfig()
    /// 割り込んだ発話の書き起こしの頭が読み上げの残りなら外す。
    public var echoFilter: Bool = true
    /// 割り込みから listen までがこの秒数を超えたら、割り込んだ発話の頭からは渡さない (リングは 15 秒)。
    public var handoffMaxSeconds: Double = 14
    /// 渡す音の始点を、話し始めよりこの ms 前にする (頭切れの保険)。
    public var handoffLeadMs: Int = 200
    /// 割り込んだ発話の前に、この ms 以内に始まった発話があれば (判定では止めなかった短い言葉など) その頭から渡す。
    public var handoffLookbackMs: Int = 2000

    public init() {}

    enum CodingKeys: String, CodingKey {
        case enabled, bargeInMs, voiceProcessing, vpAGC, vpDucking, vpAdvancedDucking, echoGate, echoFilter
        case handoffMaxSeconds, handoffLeadMs, handoffLookbackMs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BargeInSettings()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        bargeInMs = try c.decodeIfPresent(Int.self, forKey: .bargeInMs) ?? d.bargeInMs
        voiceProcessing = try c.decodeIfPresent(Bool.self, forKey: .voiceProcessing) ?? d.voiceProcessing
        vpAGC = try c.decodeIfPresent(Bool.self, forKey: .vpAGC) ?? d.vpAGC
        vpDucking = try c.decodeIfPresent(String.self, forKey: .vpDucking) ?? d.vpDucking
        vpAdvancedDucking = try c.decodeIfPresent(Bool.self, forKey: .vpAdvancedDucking) ?? d.vpAdvancedDucking
        echoGate = try c.decodeIfPresent(EchoGateConfig.self, forKey: .echoGate) ?? d.echoGate
        echoFilter = try c.decodeIfPresent(Bool.self, forKey: .echoFilter) ?? d.echoFilter
        handoffMaxSeconds = try c.decodeIfPresent(Double.self, forKey: .handoffMaxSeconds) ?? d.handoffMaxSeconds
        handoffLeadMs = try c.decodeIfPresent(Int.self, forKey: .handoffLeadMs) ?? d.handoffLeadMs
        handoffLookbackMs = try c.decodeIfPresent(Int.self, forKey: .handoffLookbackMs) ?? d.handoffLookbackMs
    }

    public var audioOptions: VoiceAudioEngine.Options {
        var o = VoiceAudioEngine.Options()
        o.voiceProcessing = voiceProcessing
        o.agc = vpAGC
        o.ducking = vpDucking
        o.advancedDucking = vpAdvancedDucking
        return o
    }
}

/// speak の結果。MCP の speak ツールはこれを toolText で返す。
public struct SpeakOutcome: Sendable, Equatable {
    /// 最後まで読んだ
    public var finished: Bool
    /// 読み上げ中にユーザーが話し始めたので止めた
    public var interrupted: Bool
    /// 聞こえた所までの文 (最後の文は途中のことがある)。割り込みが無い時は読んだ文全部
    public var heardText: String
    public var totalChars: Int
    public var playedSeconds: Double
    /// 読み上げの終わり際にユーザーが話し始めていた (止める前に読み終えた)。次の listen は話し始めから受け取る
    public var userStartedNearEnd: Bool = false

    public init(finished: Bool, interrupted: Bool = false, heardText: String = "", totalChars: Int = 0,
                playedSeconds: Double = 0, userStartedNearEnd: Bool = false) {
        self.finished = finished
        self.interrupted = interrupted
        self.heardText = heardText
        self.totalChars = totalChars
        self.playedSeconds = playedSeconds
        self.userStartedNearEnd = userStartedNearEnd
    }

    /// speak ツールの返す文。1 行目は done / stopped / interrupted (今までの done / stopped はそのまま)。
    public var toolText: String {
        guard interrupted else { return finished ? "done" : "stopped" }
        let tail = heardText.count > 40 ? "…" + String(heardText.suffix(40)) : heardText
        let secs = (playedSeconds * 10).rounded() / 10
        return """
        interrupted
        読み上げ中にユーザーが話し始めたので止めました。読み上げた所: 「\(tail)」 (\(heardText.count)/\(totalChars) 文字、\(secs) 秒)。
        続きを読み直さずに、すぐ listen を呼んでください (割り込んだ発話を頭から受け取れます)。
        """
    }
}

/// 読み上げ中の発話 (Realtime の item) を追い、割り込みの判定をどの時点の音でするかを決める (音や通信を持たない部分)。
/// 判定の時点は音の時刻 (マイクの時計) で数える: 話し始め s から bargeInMs 後 (窓は [s, s+bargeInMs])、人の声と言えなければ
/// 100ms ずつ後ろへ (窓は直近 bargeInMs)。speech_started は話し始めより 0.4〜0.6 秒遅れて届くので、届いた時には
/// 過ぎた時点をまとめて判定する (録音で数える EvalEchoGate.decide と同じ時点・同じ窓になる)。
public struct BargeInTracker: Sendable {
    public struct Item: Sendable, Equatable {
        /// 話し始めの音の時刻 (マイクの時計)
        public var audioStart: UInt64
        /// 次に判定する時点 (音の時刻)
        public var nextCheckAt: UInt64
        public var rejections: Int = 0
        public var gaveUp = false
    }

    public let bargeInNs: UInt64
    /// EchoGateConfig.recheckMs (-1 = 話している間ずっと、0 = 見直さない)
    public let recheckMs: Int
    public private(set) var open: [String: Item] = [:]
    private var order: [String] = []
    /// 読み上げ中に始まった発話の話し始め (判定で止めなかったものも含む)
    public private(set) var starts: [UInt64] = []

    public init(bargeInMs: Int, recheckMs: Int) {
        bargeInNs = UInt64(max(bargeInMs, 0)) * 1_000_000
        self.recheckMs = recheckMs
    }

    public mutating func started(_ item: String, audioStart: UInt64) {
        open[item] = Item(audioStart: audioStart, nextCheckAt: audioStart &+ bargeInNs)
        order.append(item)
        starts.append(audioStart)
    }

    /// speech_stopped: 話し終えた (bargeInMs に届く前なら相づち・物音として止めない)
    public mutating func stopped(_ item: String) {
        open[item] = nil
        order.removeAll { $0 == item }
    }

    /// `now` (届いている音の終わり) までに判定する時点が来ている発話の、一番早いもの: (item, 話し始め, 判定の時点)。
    public func nextDue(now: UInt64) -> (item: String, audioStart: UInt64, at: UInt64)? {
        var best: (String, UInt64, UInt64)?
        for k in order {
            guard let it = open[k], !it.gaveUp, it.nextCheckAt <= now else { continue }
            if best == nil || it.nextCheckAt < best!.2 { best = (k, it.audioStart, it.nextCheckAt) }
        }
        return best.map { (item: $0.0, audioStart: $0.1, at: $0.2) }
    }

    /// 判定で人の声と言えなかった。100ms 後の時点で見直す (recheckMs を超えたら見直さない)。
    public mutating func rejected(_ item: String) {
        guard var it = open[item] else { return }
        it.rejections += 1
        let next = it.nextCheckAt &+ 100_000_000
        let elapsedMs = Int((next &- it.audioStart) / 1_000_000)
        let limit = Int(bargeInNs / 1_000_000) + recheckMs
        if recheckMs == 0 || (recheckMs > 0 && elapsedMs > limit) {
            it.gaveUp = true
        } else {
            it.nextCheckAt = next
        }
        open[item] = it
    }

    /// 割り込んだ発話 (話し始め s) の直前の発話もまとめて渡すための始点: s から遡って、間が gapNs 以内で続く発話の一番早い話し始め
    /// (「ストップ」のような短い言葉は判定で止めず、続く言葉で止めることがある。その頭も listen に渡す)。
    public func handoffStart(for s: UInt64, gapNs: UInt64) -> UInt64 {
        var start = s
        for t in starts.sorted(by: >) where t < start && start - t <= gapNs { start = t }
        return start
    }

    /// 話している途中の発話のうち一番古いものの話し始め。
    public var earliestOpenAudioStart: UInt64? {
        order.compactMap { open[$0]?.audioStart }.min()
    }
}

public extension EchoGate {
    /// 録音のリングと参照信号のリングから、話し始め `itemAudioStart` の発話を判定する
    /// (claude-talk-voice の VoiceSession と speak の割り込みで同じもの)。窓は直近 bargeInMs、その前が履歴。
    static func evaluateRings(mic: AudioRing, reference: AudioRing?, itemAudioStart: UInt64?, now: UInt64,
                              bargeInMs: Int, config g: EchoGateConfig) -> Verdict {
        var to = min(now, mic.stats.lastDataAt ?? now)
        // 参照信号が流れている時は、届いている所まで (tap は少し遅れて届く。無い所を「静か」と見ないように)
        if let r = reference?.stats.lastDataAt, r + 500_000_000 > now, r < to { to = r }
        let b = UInt64(max(bargeInMs, 100)) * 1_000_000
        let s = itemAudioStart ?? (to > b ? to - b : 0)
        let winStart = min(to, max(s, to > b ? to - b : 0))
        let back = UInt64(g.historyMs + g.maxLagMs) * 1_000_000
        let from = winStart > back ? winStart - back : 0
        let micS = mic.samples(from: from, to: to)
        let refS = reference?.samples(from: from, to: to) ?? [Int16](repeating: 0, count: micS.count)
        let judgeFrom = PCM.bytes(nanoseconds: winStart - from) / 2
        return evaluate(mic: micS, ref: refS, judgeFrom: judgeFrom, config: g)
    }
}

// MARK: - 読み上げ中の見張り (Realtime の VAD + EchoGate)

/// speak の間、マイクの音を speech serve の Realtime に流し、割り込みを見つけたら onFire を 1 回呼んで終わる。
public final class BargeInWatch: @unchecked Sendable {
    public struct Fire: Sendable {
        /// 割り込んだ発話の話し始め (マイクの時計)
        public let audioStart: UInt64
        /// listen に渡す始点 (直前に続けて話した発話があればその話し始め)
        public let handoffStart: UInt64
        public let firedAt: UInt64
        /// 判定した時点 (音の時刻。話し始め + bargeInMs 以降)
        public let decidedAt: UInt64
        public let verdict: EchoGate.Verdict?
        public let rejections: Int
    }

    private let settings: DirectSettings
    private let mic: AudioRing
    private let reference: AudioRing?
    private let log: TimingLog
    private let lock = NSLock()
    private var tracker: BargeInTracker
    private var _ready = false

    public init(settings: DirectSettings, mic: AudioRing, reference: AudioRing?, log: TimingLog = .shared) {
        self.settings = settings
        self.mic = mic
        self.reference = reference
        self.log = log
        tracker = BargeInTracker(bargeInMs: settings.bargeIn.bargeInMs, recheckMs: settings.bargeIn.echoGate.recheckMs)
    }

    /// Realtime に繋がって VAD が動いているか
    public var ready: Bool { lock.lock(); defer { lock.unlock() }; return _ready }

    private func withTracker<T>(_ body: (inout BargeInTracker) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body(&tracker)
    }

    private func setReady() { lock.lock(); _ready = true; lock.unlock() }

    /// 読み上げを終えた時: 話している途中の発話があり、今までの音で人の声と言えるなら、その話し始め。
    public func voiceStartNearEnd(now: UInt64 = PCM.now()) -> UInt64? {
        guard let start = withTracker({ $0.earliestOpenAudioStart }), now > start + 100_000_000 else { return nil }
        let b = settings.bargeIn
        guard b.echoGate.enabled else { return start }
        let ms = Int(min((now - start) / 1_000_000, UInt64(max(b.bargeInMs, 100))))
        let v = EchoGate.evaluateRings(mic: mic, reference: reference, itemAudioStart: start, now: now,
                                       bargeInMs: ms, config: b.echoGate)
        return v.isVoice ? start : nil
    }

    /// 取り消される (Task.cancel) か、割り込みを見つけるまで動く。
    public func run(since: UInt64, onFire: @escaping @Sendable (Fire) -> Void) async {
        let sw = Stopwatch()
        do {
            _ = try await SpeechServer(settings: settings).ensureRunning()
        } catch {
            log.event("speak.barge_watch", mode: .direct, fields: ["ok": false, "error": error.localizedDescription])
            return
        }
        if Task.isCancelled { return }
        let rt = RealtimeSession(url: settings.realtimeURL, requestTimeout: 3600)
        defer { rt.close() }
        do {
            try await rt.open(update: RealtimeSession.sessionUpdate(settings: settings, language: settings.language,
                                                                     keywords: []))
        } catch {
            log.event("speak.barge_watch", mode: .direct, fields: ["ok": false, "error": error.localizedDescription])
            return
        }
        let sub = mic.subscribe(since: since)
        defer { mic.unsubscribe(sub.id) }
        let sessionStart = sub.backlog.first?.start ?? max(PCM.now(), since)
        setReady()
        log.event("speak.barge_watch", mode: .direct, fields: ["ok": true, "ms": sw.ms])

        enum Signal: Sendable { case event(RealtimeEvent), tick, failure(String) }
        let (signals, sig) = AsyncStream<Signal>.makeStream()
        let sender = Task {
            do {
                for p in sub.backlog { try await rt.append(p.data) }
                for await p in sub.stream {
                    guard let piece = p.sliced(from: since) else { continue }
                    try await rt.append(piece.data)
                }
            } catch { sig.yield(.failure(error.localizedDescription)) }
        }
        let receiver = Task {
            while !Task.isCancelled {
                do { sig.yield(.event(try await rt.receive())) } catch {
                    sig.yield(.failure(error.localizedDescription))
                    return
                }
            }
        }
        let ticker = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
                sig.yield(.tick)
            }
        }
        defer { sender.cancel(); receiver.cancel(); ticker.cancel(); sig.finish() }
        let b = settings.bargeIn

        for await s in signals {
            if Task.isCancelled { return }
            switch s {
            case .failure(let m):
                if !Task.isCancelled {
                    log.event("speak.barge_watch_end", mode: .direct, fields: ["error": m])
                }
                return
            case .event(.speechStarted(let item, let startMs)):
                let at = sessionStart &+ UInt64(max(startMs, 0)) * 1_000_000
                withTracker { $0.started(item, audioStart: at) }
                log.event("speak.speech_started", mode: .direct, fields: ["audio_start_ms": startMs])
            case .event(.speechStopped(let item, _)):
                withTracker { $0.stopped(item) }
            case .event(.error(let m)):
                log.event("speak.barge_watch_end", mode: .direct, fields: ["error": m])
                return
            case .event:
                break
            case .tick:
                // 届いている音の終わりまで (参照信号は少し遅れて届くので、その分も待つ)
                var now = min(PCM.now(), mic.stats.lastDataAt ?? 0)
                if let r = reference?.stats.lastDataAt, r + 500_000_000 > PCM.now(), r < now { now = r }
                while let d = withTracker({ $0.nextDue(now: now) }) {
                    var verdict: EchoGate.Verdict?
                    if b.echoGate.enabled {
                        let v = EchoGate.evaluateRings(mic: mic, reference: reference, itemAudioStart: d.audioStart,
                                                       now: d.at, bargeInMs: b.bargeInMs, config: b.echoGate)
                        verdict = v
                        if !v.isVoice {
                            let n: Int = withTracker {
                                $0.rejected(d.item)
                                return $0.open[d.item]?.rejections ?? 0
                            }
                            if n == 1 {
                                var f = v.fields
                                f["behind_ms"] = Int((PCM.now() &- d.at) / 1_000_000)
                                log.event("speak.barge_rejected", mode: .direct, fields: f)
                            }
                            continue
                        }
                    }
                    let rej = withTracker { $0.open[d.item]?.rejections ?? 0 }
                    let hs = withTracker { $0.handoffStart(for: d.audioStart, gapNs: UInt64(max(b.handoffLookbackMs, 0)) * 1_000_000) }
                    onFire(Fire(audioStart: d.audioStart, handoffStart: hs, firedAt: PCM.now(), decidedAt: d.at, verdict: verdict,
                                rejections: rej))
                    return
                }
            }
        }
    }
}

// MARK: - 読み上げの再生 (本物 = ReplySpeaker、テスト = WAV を参照信号に流すだけ)

/// speak の割り込みで使う再生の口。
public protocol SpeakPlayback: AnyObject, Sendable {
    func enqueue(_ sentence: String)
    func finish() async -> Bool
    @discardableResult func stop() -> ReplySpeaker.Progress
    var progress: ReplySpeaker.Progress { get }
}

extension ReplySpeaker: SpeakPlayback {}

/// テスト用 (音を出さない): 決めた音 (24kHz mono Int16) を、鳴らしたことにして実時間で参照信号のリングに積む。
/// どこまで読んだかは、鳴らした長さの割合で文字を数える。
public final class WavReferencePlayback: SpeakPlayback, @unchecked Sendable {
    private let pcm: Data
    private let reference: AudioRing
    private let onFirstAudio: @Sendable () -> Void
    private let lock = NSLock()
    private var texts: [String] = []
    private var offset = 0
    private var stopped = false
    private var started = false
    private var waiter: CheckedContinuation<Bool, Never>?
    private var result: Bool?
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "claude-talk.wav-reference")

    public init(pcm: Data, reference: AudioRing, onFirstAudio: @escaping @Sendable () -> Void = {}) {
        self.pcm = pcm
        self.reference = reference
        self.onFirstAudio = onFirstAudio
    }

    public func enqueue(_ sentence: String) {
        lock.lock()
        texts.append(sentence)
        let go = !started
        started = true
        lock.unlock()
        if go { begin() }
    }

    private func begin() {
        let chunk = PCM.bytesPerSecond * 40 / 1000
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(40), leeway: .milliseconds(2))
        var nextStart = PCM.now()
        var first = true
        t.setEventHandler { [weak self] in
            guard let self else { return }
            while nextStart <= PCM.now() {
                self.lock.lock()
                if self.stopped || self.offset >= self.pcm.count {
                    self.lock.unlock()
                    self.resolve(!self.isStopped)
                    return
                }
                let n = min(chunk, self.pcm.count - self.offset)
                let data = self.pcm.subdata(in: self.offset..<(self.offset + n))
                self.offset += n
                self.lock.unlock()
                let piece = AudioPiece(start: nextStart, data: data)
                self.reference.append(piece)
                nextStart = piece.end
                if first { first = false; self.onFirstAudio() }
            }
        }
        timer = t
        t.resume()
    }

    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    private func resolve(_ ok: Bool) {
        lock.lock()
        if result == nil { result = ok }
        let r = result!
        let w = waiter
        waiter = nil
        let t = timer
        timer = nil
        lock.unlock()
        t?.cancel()
        w?.resume(returning: r)
    }

    public func finish() async -> Bool {
        await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            lock.lock()
            if let r = result { lock.unlock(); c.resume(returning: r); return }
            if !started { lock.unlock(); c.resume(returning: true); return }
            waiter = c
            lock.unlock()
        }
    }

    @discardableResult
    public func stop() -> ReplySpeaker.Progress {
        lock.lock()
        stopped = true
        lock.unlock()
        let p = progress
        resolve(false)
        return p
    }

    public var progress: ReplySpeaker.Progress {
        lock.lock(); defer { lock.unlock() }
        let all = texts.joined()
        let frac = pcm.isEmpty ? 1 : Double(offset) / Double(pcm.count)
        let heard = offset == 0 ? "" : String(all.prefix(Int((Double(all.count) * frac).rounded(.up))))
        let started = heard.isEmpty ? 0 : max(1, texts.count)
        return ReplySpeaker.Progress(sentencesStarted: started, sentencesQueued: texts.count, heardText: heard,
                                     playedSeconds: Double(offset / 2) / Double(PCM.sampleRate))
    }
}

/// ロック付きの入れ物 (並行のタスクから 1 つの値を読み書きする)。
final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T?
    init() {}
    var value: T? {
        get { lock.lock(); defer { lock.unlock() }; return v }
        set { lock.lock(); v = newValue; lock.unlock() }
    }
}

typealias ErrorBox = LockedBox<String>
typealias FireBox = LockedBox<BargeInWatch.Fire>
