//
//  DirectEngine.swift
//  ClaudeTalkCore
//
//  direct モードの本体: MCP サーバー自身がマイクを録り、speech.cpp の Realtime (server_vad + 語彙) に流して
//  書き起こしを返す (listen)。読み上げも MCP サーバーの中で行う (speak)。音声アプリは使わない。
//
//  マイクは声の会話の間だけ開ける: speak / listen で開け、最後の呼び出しから micIdleCloseSeconds で閉じる。
//  開けている間はリングに音を残すので、合図 (speak) の直後に話し始めても listen が頭から拾える (プリロール)。
//

import Foundation

public actor DirectEngine {
    public static let shared = DirectEngine()

    private let log = TimingLog.shared
    private let ring = AudioRing(retainSeconds: 15)
    private var input: AudioInput?
    private let micLock = FileLock(url: TalkPaths.micLock)
    private var micVerified = false
    private var speakEndAt: UInt64?
    private var idleToken = 0
    private var busy = 0
    private var speaker: Speaker?
    private let irodori = IrodoriSpeaker()
    private let makeInput: @Sendable () throws -> AudioInput

    public init(makeInput: (@Sendable () throws -> AudioInput)? = nil) {
        self.makeInput = makeInput ?? {
            if let test = try WavFileInput.fromEnvironment() { return test }
            return MicInput()
        }
    }

    // MARK: - 起動時

    /// direct モードで起動した時に呼ぶ: speech serve を先に温めておく (初回 listen の待ちを減らす)。
    /// 読み上げが irodori なら、その serve も並行して起こす。
    public func prewarm() async {
        let (settings, _) = DirectSettings.load()
        let log = self.log
        if settings.ttsEngine == .irodori {
            Task.detached {
                let sw = Stopwatch()
                do {
                    let started = try await TTSServer(settings: settings)
                        .ensureRunning(timeout: settings.serverStartTimeoutSeconds)
                    log.event("tts.prewarm", mode: .direct, fields: ["ms": sw.ms, "started": started])
                } catch {
                    log.event("tts.prewarm", mode: .direct, fields: ["ms": sw.ms, "error": "\(error.localizedDescription)"])
                }
            }
        }
        let sw = Stopwatch()
        do {
            let started = try await SpeechServer(settings: settings).ensureRunning()
            log.event("server.prewarm", mode: .direct, fields: ["ms": sw.ms, "started": started])
        } catch {
            log.event("server.prewarm", mode: .direct, fields: ["ms": sw.ms, "error": "\(error.localizedDescription)"])
        }
    }

    // MARK: - speak

    /// 読み上げ。settings.tts が irodori なら speech serve (Irodori) で、届いた音をそばから鳴らし、鳴り終わってから返る。
    /// Irodori の serve が立たない・まだ何も鳴らないうちに失敗した時は avspeech に落とす (timing.jsonl に speak.fallback)。
    /// voice に AVSpeech の identifier (com.apple.…) を渡した時は、その回だけ avspeech。
    public func speak(text: String, voice: String?, rate: Double?, locale: String) async throws -> Bool {
        let (settings, warning) = DirectSettings.load()
        let sw = Stopwatch()
        var kind = settings.ttsEngine
        if let voice, voice.hasPrefix("com.apple.") { kind = .avspeech }
        log.event("speak.recv", mode: .direct, fields: ["chars": text.count, "tts": kind.rawValue]
                  .merging(warning.map { ["warning": $0] } ?? [:]) { a, _ in a })
        busy += 1
        defer {
            busy -= 1
            scheduleIdleClose(after: settings.micIdleCloseSeconds)
        }
        // 次の listen のプリロールのために、読み上げの間にマイクを開けておく (取れなければ listen で開ける)。
        if input == nil, micLock.tryLock() {
            try? startInput()
        }
        speakEndAt = nil
        var finished = false
        var used = kind
        if kind == .irodori {
            do {
                finished = try await speakIrodori(text: text, settings: settings, sw: sw)
            } catch is CancellationError {
                throw CancellationError()
            } catch let f as IrodoriFailure where f.audioStarted {
                // 途中まで鳴った後の失敗は、avspeech で読み直さない (同じ文を 2 度読まない)。
                speakEndAt = PCM.now()
                input?.trigger("speak_done")
                log.event("speak.done", mode: .direct, fields: ["ms": sw.ms, "finished": false, "tts": "irodori",
                                                                "error": f.localizedDescription])
                throw f
            } catch {
                log.event("speak.fallback", mode: .direct, fields: ["ms": sw.ms, "from": "irodori", "to": "avspeech",
                                                                    "error": error.localizedDescription])
                used = .avspeech
            }
        }
        if used == .avspeech {
            finished = await speakAV(text: text, voice: voice ?? settings.voice, rate: rate ?? settings.rate,
                                     locale: locale, sw: sw)
        }
        speakEndAt = PCM.now()
        input?.trigger("speak_done")
        log.event("speak.done", mode: .direct, fields: ["ms": sw.ms, "finished": finished, "tts": used.rawValue])
        try Task.checkCancellation()
        return finished
    }

    private func speakAV(text: String, voice: String?, rate: Double?, locale: String, sw: Stopwatch) async -> Bool {
        if speaker == nil { speaker = await Speaker() }
        let log = self.log
        return await speaker!.speak(text: text, voice: voice, rate: rate, locale: locale) {
            log.event("speak.audio_start", mode: .direct, fields: ["ms": sw.ms, "tts": "avspeech"])
        }
    }

    private func speakIrodori(text: String, settings: DirectSettings, sw: Stopwatch) async throws -> Bool {
        let swServer = Stopwatch()
        let started = try await TTSServer(settings: settings).ensureRunning(timeout: settings.ttsStartTimeoutSeconds)
        log.event("speak.tts_ready", mode: .direct, fields: ["ms": swServer.ms, "started": started])
        let prepared = Readings.prepare(text, settings: settings)
        if prepared != text {
            log.event("speak.readings", mode: .direct, fields: ["chars_before": text.count, "chars_after": prepared.count])
        }
        let log = self.log
        return try await irodori.speak(text: prepared, settings: settings, onTiming: { stage, t in
            switch stage {
            case "first_audio":
                log.event("speak.audio_start", mode: .direct, fields: [
                    "ms": sw.ms, "tts": "irodori", "first_chunk_ms": t.firstChunkMs ?? -1,
                    "first_voiced_ms": t.firstVoicedMs ?? -1, "header_ms": t.headerMs ?? -1, "request_ms": t.requestMs ?? -1,
                    "player_ready_ms": t.playerReadyMs ?? -1])
            default:
                log.event("speak.stream_done", mode: .direct, fields: ["ms": sw.ms, "audio_s": (t.audioSeconds * 100).rounded() / 100])
            }
        })
    }

    // MARK: - listen

    public func listen(timeout: Double, locale: String) async throws -> String {
        let (settings, warning) = DirectSettings.load()
        let keywords = Vocabulary.load()
        let turn = log.nextTurn()
        let sw = Stopwatch()
        log.event("listen.recv", mode: .direct, fields: ["timeout": timeout, "keywords": keywords.count,
                                                         "silence_ms": settings.silenceMs]
                  .merging(warning.map { ["warning": $0] } ?? [:]) { a, _ in a })
        busy += 1
        defer {
            busy -= 1
            scheduleIdleClose(after: settings.micIdleCloseSeconds)
        }
        do {
            let text = try await listenBody(settings: settings, keywords: keywords, timeout: timeout,
                                            locale: locale, turn: turn, sw: sw)
            log.event("listen.return", mode: .direct, fields: ["ms": sw.ms, "chars": text.count, "ok": true])
            return text
        } catch {
            log.event("listen.return", mode: .direct, fields: ["ms": sw.ms, "ok": false,
                                                               "error": error.localizedDescription])
            throw error
        }
    }

    private func listenBody(settings: DirectSettings, keywords: [String], timeout: Double, locale: String,
                            turn: Int, sw: Stopwatch) async throws -> String {
        // 1) マイク (先に開けて、サーバーを待つ間の音もリングに残す)
        var openedNow = false
        if input == nil {
            guard await micLock.lock(timeout: settings.micLockWaitSeconds) else { throw TalkError.micBusy }
            try startInput()
            openedNow = true
        }
        let listenAt = PCM.now()
        input?.trigger("listen")

        // 2) speech serve (Haas + Silero)
        let swServer = Stopwatch()
        let started = try await SpeechServer(settings: settings).ensureRunning()
        log.event("listen.server_ready", mode: .direct, fields: ["ms": swServer.ms, "started": started])

        // 3) プリロール: 直前の speak の終わりから (無ければ listen の少し前から)
        let maxBack = UInt64(settings.prerollMaxSeconds * 1e9)
        var since = listenAt > UInt64(settings.prerollLeadSeconds * 1e9) ? listenAt - UInt64(settings.prerollLeadSeconds * 1e9) : 0
        if let end = speakEndAt, end <= listenAt, listenAt - end <= maxBack { since = min(since, end) }
        speakEndAt = nil
        log.event("listen.mic_ready", mode: .direct, fields: [
            "opened_now": openedNow, "input": input?.name ?? "", "preroll_ms": Int((PCM.now() - since) / 1_000_000)])

        // 4) Realtime
        let lang = Self.isoLanguage(locale, fallback: settings.language)
        let rt = RealtimeSession(url: settings.realtimeURL)
        defer { rt.close() }
        let swWs = Stopwatch()
        try await rt.open(update: RealtimeSession.sessionUpdate(settings: settings, language: lang, keywords: keywords))
        log.event("listen.ws_ready", mode: .direct, fields: ["ms": swWs.ms])

        let sub = ring.subscribe(since: since)
        defer { ring.unsubscribe(sub.id) }
        let sessionStart = sub.backlog.first?.start ?? PCM.now()

        enum Signal: Sendable { case event(RealtimeEvent), tick, failure(String) }
        let (signals, sig) = AsyncStream<Signal>.makeStream()

        // 音を送る
        let sender = Task {
            do {
                for p in sub.backlog { try await rt.append(p.data) }
                for await p in sub.stream { try await rt.append(p.data) }
            } catch {
                sig.yield(.failure("\(error.localizedDescription)"))
            }
        }
        // イベントを受ける
        let receiver = Task {
            while !Task.isCancelled {
                do { sig.yield(.event(try await rt.receive())) } catch {
                    sig.yield(.failure("\(error.localizedDescription)"))
                    return
                }
            }
        }
        // 時計 (締め切りと取り消しを見る)
        let ticker = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                sig.yield(.tick)
            }
        }
        defer {
            sender.cancel(); receiver.cancel(); ticker.cancel()
            sig.finish()
        }

        // 5) 無音のマイクの検出 (開けたばかりの時だけ。listen は止めずに並行で見る)
        let needCheck = !micVerified
        let checkStart = PCM.now()

        var tracker = TurnTracker()
        let waitDeadline = Date().addingTimeInterval(timeout)
        var speechDeadline: Date?
        var committedForLimit: Date?
        var stoppedAt: Date?
        var speechEndDate: Date?

        func wallDate(uptime: UInt64) -> Date {
            let now = PCM.now()
            return Date().addingTimeInterval(-Double(Int64(bitPattern: now &- uptime)) / 1e9)
        }

        for await s in signals {
            if Task.isCancelled { throw CancellationError() }
            switch s {
            case .failure(let m):
                throw TalkError.realtime(m)
            case .tick:
                if needCheck, !micVerified {
                    try checkMic(settings: settings, since: checkStart)
                }
                let now = Date()
                if let limit = committedForLimit {
                    if now.timeIntervalSince(limit) > 5 { return tracker.partialText }
                } else if let dl = speechDeadline, now > dl {
                    // 話が長すぎる: いったん区切って書き起こし、返す。
                    try? await rt.commit()
                    committedForLimit = now
                    log.event("asr.max_speech", mode: .direct, fields: ["seconds": settings.maxSpeechSeconds])
                } else if !tracker.heardSpeech, !tracker.speaking, now > waitDeadline {
                    log.event("asr.timeout", mode: .direct, fields: ["timeout": timeout,
                                                                     "discarded_empty": tracker.discardedEmpty])
                    return ""
                }
            case .event(let ev):
                switch ev {
                case .speechStarted(_, let startMs):
                    if speechDeadline == nil { speechDeadline = Date().addingTimeInterval(settings.maxSpeechSeconds) }
                    log.event("asr.speech_started", mode: .direct, fields: ["audio_start_ms": startMs,
                                                                            "ms": sw.ms])
                case .speechStopped(_, let endMs):
                    stoppedAt = Date()
                    let end = wallDate(uptime: sessionStart &+ UInt64(max(endMs, 0)) * 1_000_000)
                    speechEndDate = end
                    log.event("asr.speech_stopped", mode: .direct, fields: [
                        "audio_end_ms": endMs, "ms": sw.ms,
                        "speech_end_at": Int64((end.timeIntervalSince1970 * 1000).rounded())])
                case .completed(_, let transcript):
                    var f: [String: Any] = ["chars": transcript.count, "ms": sw.ms]
                    if let st = stoppedAt { f["after_stopped_ms"] = Int(Date().timeIntervalSince(st) * 1000) }
                    if let e = speechEndDate { f["after_speech_end_ms"] = Int(Date().timeIntervalSince(e) * 1000) }
                    log.event("asr.completed", mode: .direct, fields: f)
                case .failed(_, let m):
                    log.event("asr.failed", mode: .direct, fields: ["error": m])
                case .error(let m):
                    throw TalkError.realtime(m)
                default:
                    break
                }
                if case .finish(let text) = tracker.handle(ev) { return text }
                if case .completed = ev, committedForLimit != nil, !tracker.speaking {
                    return tracker.partialText
                }
            }
        }
        if Task.isCancelled { throw CancellationError() }
        throw TalkError.realtime("セッションが途中で終わりました")
    }

    /// 開けてから silentMicCheckSeconds の音が全部ほぼ 0 なら、許可が無い・入力が違うとみなす。
    private func checkMic(settings: DirectSettings, since: UInt64) throws {
        let st = ring.stats
        let elapsed = Double(PCM.now() - since) / 1e9
        guard let first = st.firstDataAt else {
            if elapsed > settings.micNoDataTimeoutSeconds {
                let name = input?.name ?? ""
                closeMic(reason: "nodata")
                throw TalkError.micSilent("マイクから音のデータが届きません (\(name))。入力デバイスを確かめてください")
            }
            return
        }
        guard let last = st.lastDataAt, Double(last - first) / 1e9 >= settings.silentMicCheckSeconds else { return }
        if st.peak <= 2 {
            let name = input?.name ?? ""
            closeMic(reason: "silent")
            log.event("mic.silent", mode: .direct, fields: ["peak": st.peak, "input": name])
            throw TalkError.micSilent("マイクの音が完全に無音です (\(name))。Claude Code を動かしているアプリ (iTerm2 など) にマイクの許可があるか、システム設定 > サウンド > 入力 を確かめてください")
        }
        micVerified = true
        log.event("mic.verified", mode: .direct, fields: ["peak": st.peak])
    }

    // MARK: - マイクの開け閉め

    private func startInput() throws {
        ring.reset()
        let inp = try makeInput()
        do {
            try inp.start(into: ring)
        } catch {
            micLock.unlock()
            throw error
        }
        input = inp
        micVerified = false
        log.event("mic.open", mode: .direct, fields: ["input": inp.name])
    }

    public func closeMic(reason: String) {
        guard let inp = input else { return }
        inp.stop()
        input = nil
        micVerified = false
        micLock.unlock()
        log.event("mic.close", mode: .direct, fields: ["reason": reason])
    }

    public var isMicOpen: Bool { input != nil }

    private func scheduleIdleClose(after seconds: Double) {
        idleToken += 1
        let token = idleToken
        Task {
            try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0.1) * 1e9))
            await self.idleCloseIfStill(token)
        }
    }

    private func idleCloseIfStill(_ token: Int) {
        guard token == idleToken, busy == 0 else { return }
        closeMic(reason: "idle")
    }

    /// ja-JP → ja。
    static func isoLanguage(_ locale: String, fallback: String) -> String {
        let tag = locale.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init)
        return (tag?.isEmpty == false ? tag : nil) ?? fallback
    }
}
