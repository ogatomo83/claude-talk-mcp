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
//  読み上げ中の割り込み (settings の bargeIn、既定 on、T-0035): マイクを VoiceAudioEngine (VPIO) で開け、読み上げも同じ
//  engine で鳴らす。読み上げの間も VAD + EchoGate で見張り、人の声なら止めて speak を返す (SpeakOutcome.interrupted)。
//  その発話は次の listen が話し始めから受け取る (handoff)。bargeIn.enabled=false なら今までの動き。
//
//  Caps Lock がオンの間だけマイクを入れる (settings の capsLock、既定 on、T-0038。CapsLock.swift):
//  オフの間の音は聞き取りにも割り込みの見張りにも送らない (0 にする)。オフの間の listen はオンになるまで待ち
//  (timeout はオンの間だけ数える)、capsLock.offMaxWaitSeconds たってもオフなら caps_lock_off を返す。
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
    /// 直前の読み上げ (文と鳴り終わった時刻)。listen の始点の下限と、似た書き起こしを捨てる判定に使う。listen では消さない。
    private var lastSpeak: (text: String, endAt: UInt64)?
    private var idleToken = 0
    private var busy = 0
    private var speaker: Speaker?
    private let irodori = IrodoriSpeaker()
    private let makeInput: @Sendable () throws -> AudioInput
    private let customMakeInput: (@Sendable () throws -> AudioInput)?
    /// 今のマイクが割り込み用の共有 engine (VoiceAudioEngine) か
    private var inputShared = false
    /// テスト用: 読み上げの代わりにこの音 (24kHz mono Int16) を参照信号に流す (音は出さない)
    private let testSpeakReference: Data?
    private let testReferenceRing = AudioRing(retainSeconds: 15)
    /// 割り込んだ (または読み上げの終わり際に話し始めた) 発話を、次の listen に話し始めから渡す。
    private var handoff: (since: UInt64, at: UInt64, heard: String)?
    /// Caps Lock の状態 (マイクを開けている間だけ読む)
    private var capsGate: CapsLockGate?
    private let capsReader: CapsLockReader?

    public init(makeInput: (@Sendable () throws -> AudioInput)? = nil, testSpeakReference: Data? = nil,
                capsReader: CapsLockReader? = nil) {
        customMakeInput = makeInput
        self.testSpeakReference = testSpeakReference
        self.capsReader = capsReader
        self.makeInput = makeInput ?? {
            if let test = try WavFileInput.fromEnvironment() { return test }
            return MicInput()
        }
    }

    // MARK: - 起動時

    /// direct モードで起動した時に呼ぶ: speech serve を先に温めておく (初回 listen の待ちを減らす)。
    /// 読み上げが speech serve (qwen / irodori) なら、その serve も並行して起こす。
    public func prewarm() async {
        let (settings, _) = DirectSettings.load()
        let log = self.log
        if settings.ttsEngine != .avspeech {
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

    /// 読み上げ。settings.tts が qwen (既定) / irodori なら speech serve で、届いた音をそばから鳴らし、鳴り終わってから返る。
    /// serve が立たない・まだ何も鳴らないうちに失敗した時は avspeech に落とす (timing.jsonl に speak.fallback)。
    /// voice に AVSpeech の identifier (com.apple.…) を渡した時は、その回だけ avspeech。
    /// 戻り値: 最後まで鳴らしたら true。
    public func speak(text: String, voice: String?, rate: Double?, locale: String) async throws -> Bool {
        try await speakOutcome(text: text, voice: voice, rate: rate, locale: locale).finished
    }

    /// speak の本体。bargeIn が有効なら、読み上げ中にユーザーが話した時に止めて interrupted を返す。
    public func speakOutcome(text: String, voice: String?, rate: Double?, locale: String) async throws -> SpeakOutcome {
        let (settings, warning) = DirectSettings.load()
        let sw = Stopwatch()
        var kind = settings.ttsEngine
        if let voice, voice.hasPrefix("com.apple.") { kind = .avspeech }
        let wantBarge = settings.bargeIn.enabled && kind != .avspeech
        log.event("speak.recv", mode: .direct, fields: ["chars": text.count, "tts": kind.rawValue, "barge_in": wantBarge]
                  .merging(warning.map { ["warning": $0] } ?? [:]) { a, _ in a })
        busy += 1
        defer {
            busy -= 1
            scheduleIdleClose(after: settings.micIdleCloseSeconds)
        }
        handoff = nil
        // 割り込みの有無を切り替えた時は、マイクを開け直す (共有 engine ⇔ 別の engine)。
        if input != nil, inputShared != wantBarge, busy == 1 {
            closeMic(reason: "barge_in_\(wantBarge ? "on" : "off")")
        }
        // 次の listen のプリロールのために、読み上げの間にマイクを開けておく (取れなければ listen で開ける)。
        if input == nil, micLock.tryLock() {
            try? startInput(shared: wantBarge, settings: settings)
        }
        let gate = ensureCapsGate(settings.capsLock)
        speakEndAt = nil
        input?.trigger("speak_start")
        var outcome = SpeakOutcome(finished: false, heardText: text, totalChars: text.count)
        var used = kind
        if kind != .avspeech {
            do {
                if wantBarge, inputShared, let ref = speakReferenceRing {
                    outcome = try await speakBarge(text: text, kind: kind, settings: settings, reference: ref,
                                                   gate: gate, sw: sw)
                } else {
                    outcome.finished = try await speakServe(text: text, kind: kind, settings: settings, sw: sw)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let f as IrodoriFailure where f.audioStarted {
                // 途中まで鳴った後の失敗は、avspeech で読み直さない (同じ文を 2 度読まない)。
                speakEndAt = PCM.now()
                lastSpeak = (text, speakEndAt!)
                input?.trigger("speak_done")
                log.event("speak.done", mode: .direct, fields: ["ms": sw.ms, "finished": false, "tts": kind.rawValue,
                                                                "error": f.localizedDescription])
                throw f
            } catch {
                log.event("speak.fallback", mode: .direct, fields: ["ms": sw.ms, "from": kind.rawValue, "to": "avspeech",
                                                                    "error": error.localizedDescription])
                used = .avspeech
            }
        }
        if used == .avspeech {
            outcome = SpeakOutcome(finished: await speakAV(text: text, voice: voice ?? settings.voice, rate: rate ?? settings.rate,
                                                           locale: locale, sw: sw),
                                   heardText: text, totalChars: text.count)
        }
        speakEndAt = PCM.now()
        lastSpeak = (outcome.interrupted ? outcome.heardText : text, speakEndAt!)
        if let h = handoff { handoff = (h.since, speakEndAt!, lastSpeak!.text) }
        input?.trigger("speak_done")
        log.event("speak.done", mode: .direct, fields: ["ms": sw.ms, "finished": outcome.finished, "tts": used.rawValue,
                                                        "interrupted": outcome.interrupted,
                                                        "heard_chars": outcome.heardText.count,
                                                        "near_end": outcome.userStartedNearEnd])
        try Task.checkCancellation()
        return outcome
    }

    /// 割り込みの参照信号 (鳴らした音) のリング。共有 engine か、テストの参照信号。
    private var speakReferenceRing: AudioRing? {
        if testSpeakReference != nil { return testReferenceRing }
        return (input as? VoiceAudioEngine)?.reference
    }

    /// 読み上げ中の割り込みあり: 共有 engine で文ごとに鳴らし、並行して VAD + EchoGate で見張る。
    private func speakBarge(text: String, kind: TTSEngineKind, settings: DirectSettings, reference: AudioRing,
                            gate: CapsLockGate?, sw: Stopwatch) async throws -> SpeakOutcome {
        let log = self.log
        let firstAudio = FlagBox()
        let lastError = ErrorBox()
        let player: SpeakPlayback
        if let pcm = testSpeakReference {
            player = WavReferencePlayback(pcm: pcm, reference: reference) {
                firstAudio.value = true
                log.event("speak.audio_start", mode: .direct, fields: ["ms": sw.ms, "tts": "test_reference"])
            }
        } else {
            let swServer = Stopwatch()
            let started = try await TTSServer(settings: settings).ensureRunning(timeout: settings.ttsStartTimeoutSeconds)
            log.event("speak.tts_ready", mode: .direct, fields: ["ms": swServer.ms, "started": started])
            player = ReplySpeaker(settings: settings, turn: 0, host: input as? VoiceAudioEngine) { stage in
                switch stage {
                case .firstAudio:
                    firstAudio.value = true
                    log.event("speak.audio_start", mode: .direct, fields: ["ms": sw.ms, "tts": kind.rawValue,
                                                                           "speed": settings.ttsSpeedValue, "barge_in": true])
                case .sentence:
                    break
                case .error(let m):
                    lastError.value = m
                    log.event("speak.tts_error", mode: .direct, fields: ["error": m])
                }
            }
        }
        var splitter = SentenceSplitter()
        var sentences = splitter.feed(text) + splitter.flush()
        if sentences.isEmpty { sentences = [text] }
        let speakStart = PCM.now()
        let watch = BargeInWatch(settings: settings, mic: ring, reference: reference, log: log, capsGate: gate)
        let fired = FireBox()
        let watchTask = Task.detached {
            await watch.run(since: speakStart) { fire in
                fired.value = fire
                player.stop()
            }
        }
        defer { watchTask.cancel() }
        for s in sentences { player.enqueue(s) }
        // 最初の音が来なければ打ち切る (その回は avspeech に落とせる)。
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: UInt64(max(settings.ttsFirstAudioTimeoutSeconds, 0.5) * 1e9))
            if !Task.isCancelled, !firstAudio.value {
                lastError.value = "最初の音が \(settings.ttsFirstAudioTimeoutSeconds) 秒で届きません"
                player.stop()
            }
        }
        let played = await withTaskCancellationHandler {
            await player.finish()
        } onCancel: {
            player.stop()
        }
        watchdog.cancel()
        if Task.isCancelled { throw CancellationError() }
        if !firstAudio.value {
            throw IrodoriFailure(message: lastError.value ?? "音が 1 つも届きません", audioStarted: false)
        }
        let progress = player.progress
        var outcome = SpeakOutcome(finished: played, heardText: progress.heardText, totalChars: text.count,
                                   playedSeconds: progress.playedSeconds)
        if let f = fired.value {
            outcome.finished = false
            outcome.interrupted = true
            handoff = (f.handoffStart, PCM.now(), progress.heardText)
            var fields: [String: Any] = ["ms": sw.ms, "heard_chars": progress.heardText.count, "total_chars": text.count,
                                         "played_s": (progress.playedSeconds * 100).rounded() / 100,
                                         "after_speech_start_ms": Int((f.firedAt &- f.audioStart) / 1_000_000),
                                         "decided_after_start_ms": Int((f.decidedAt &- f.audioStart) / 1_000_000),
                                         "rejections": f.rejections,
                                         "handoff_back_ms": Int((f.audioStart &- f.handoffStart) / 1_000_000)]
            if let v = f.verdict { fields["gate"] = v.fields }
            log.event("speak.barge_in", mode: .direct, fields: fields)
        } else {
            outcome.heardText = played ? text : progress.heardText
            if played, let start = watch.voiceStartNearEnd() {
                // 読み終える直前に話し始めていた: 次の listen は話し始めから (読み上げの終わり + tail guard で切らない)
                outcome.userStartedNearEnd = true
                handoff = (start, PCM.now(), text)
                log.event("speak.voice_near_end", mode: .direct,
                          fields: ["before_end_ms": Int((PCM.now() &- start) / 1_000_000)])
            }
            if !watch.ready { log.event("speak.barge_unavailable", mode: .direct, fields: ["ms": sw.ms]) }
        }
        return outcome
    }

    private func speakAV(text: String, voice: String?, rate: Double?, locale: String, sw: Stopwatch) async -> Bool {
        if speaker == nil { speaker = await Speaker() }
        let log = self.log
        return await speaker!.speak(text: text, voice: voice, rate: rate, locale: locale) {
            log.event("speak.audio_start", mode: .direct, fields: ["ms": sw.ms, "tts": "avspeech"])
        }
    }

    private func speakServe(text: String, kind: TTSEngineKind, settings: DirectSettings, sw: Stopwatch) async throws -> Bool {
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
                    "ms": sw.ms, "tts": kind.rawValue, "speed": settings.ttsSpeedValue, "first_chunk_ms": t.firstChunkMs ?? -1,
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
        var recv: [String: Any] = ["timeout": timeout, "keywords": keywords.count, "silence_ms": settings.silenceMs,
                                   "caps_lock": settings.capsLock.enabled]
        if let w = warning { recv["warning"] = w }
        log.event("listen.recv", mode: .direct, fields: recv)
        busy += 1
        defer {
            busy -= 1
            scheduleIdleClose(after: settings.micIdleCloseSeconds)
        }
        do {
            let text = try await listenGated(settings: settings, keywords: keywords, timeout: timeout,
                                             locale: locale, turn: turn, sw: sw)
            log.event("listen.return", mode: .direct, fields: ["ms": sw.ms, "chars": text.count, "ok": true,
                                                               "caps_lock_off": text.hasPrefix(CapsLockListen.marker)])
            return text
        } catch {
            log.event("listen.return", mode: .direct, fields: ["ms": sw.ms, "ok": false,
                                                               "error": error.localizedDescription])
            throw error
        }
    }

    enum BodyResult { case text(String), capsOff(onSeconds: Double) }

    /// Caps Lock の門つきの listen。無効なら今まで通り。有効なら、オフの間はオンになるまで待ち (Realtime は開けない)、
    /// オンの間に聞く。聞いている途中でオフになり、まだ話していなければ待つ所に戻る (timeout はオンの間だけ数える)。
    private func listenGated(settings: DirectSettings, keywords: [String], timeout: Double, locale: String,
                             turn: Int, sw: Stopwatch) async throws -> String {
        // マイク (先に開けて、サーバーを待つ間・オフで待つ間の音もリングに残す)
        var openedNow = false
        if input == nil {
            guard await micLock.lock(timeout: settings.micLockWaitSeconds) else { throw TalkError.micBusy }
            try startInput(shared: settings.bargeIn.enabled, settings: settings)
            openedNow = true
        }
        let gate = ensureCapsGate(settings.capsLock)
        guard let gate else {
            if case .text(let t) = try await listenBody(settings: settings, keywords: keywords, timeout: timeout,
                                                        locale: locale, turn: turn, sw: sw, gate: nil,
                                                        openedNow: openedNow) { return t }
            return ""
        }
        var budget = timeout
        var waitedTotal = 0.0
        while true {
            if !gate.isOn {
                let w = Stopwatch()
                log.event("listen.caps_wait", mode: .direct, fields: ["ms": sw.ms])
                let maxWait = max(settings.capsLock.offMaxWaitSeconds, 1)
                while !gate.isOn {
                    try await Task.sleep(nanoseconds: max(settings.capsLock.pollNs, 20_000_000))
                    if Double(w.ms) / 1000 >= maxWait {
                        waitedTotal += Double(w.ms) / 1000
                        log.event("listen.caps_off_return", mode: .direct, fields: ["waited_ms": Int(waitedTotal * 1000)])
                        return CapsLockListen.text(waitedSeconds: waitedTotal)
                    }
                }
                waitedTotal += Double(w.ms) / 1000
                log.event("listen.caps_on", mode: .direct, fields: ["waited_ms": w.ms])
            }
            switch try await listenBody(settings: settings, keywords: keywords, timeout: budget, locale: locale,
                                        turn: turn, sw: sw, gate: gate, openedNow: openedNow) {
            case .text(let t):
                return t
            case .capsOff(let used):
                openedNow = false
                budget -= used
                log.event("listen.caps_off", mode: .direct, fields: ["on_s": (used * 10).rounded() / 10,
                                                                     "budget_s": (budget * 10).rounded() / 10])
                if budget <= 0 { return "" }
            }
        }
    }

    private func listenBody(settings: DirectSettings, keywords: [String], timeout: Double, locale: String,
                            turn: Int, sw: Stopwatch, gate: CapsLockGate?, openedNow: Bool) async throws -> BodyResult {
        // 1) マイクは listenGated で開けてある (取り消しなどで閉じていたら開け直す)
        if input == nil {
            guard await micLock.lock(timeout: settings.micLockWaitSeconds) else { throw TalkError.micBusy }
            try startInput(shared: settings.bargeIn.enabled, settings: settings)
        }
        let bodyStart = Date()
        let listenAt = PCM.now()
        input?.trigger("listen")

        // 2) speech serve (Haas + Silero)
        let swServer = Stopwatch()
        let started = try await SpeechServer(settings: settings).ensureRunning()
        log.event("listen.server_ready", mode: .direct, fields: ["ms": swServer.ms, "started": started])

        // 3) プリロール: 直前の speak の終わりから (無ければ listen の少し前から)。
        //    読み上げ中に割り込んだ発話があれば、その話し始めから (handoff)。
        let plan = Self.prerollPlan(listenAt: listenAt, speakEndAt: speakEndAt, lastSpeakEnd: lastSpeak?.endAt,
                                    handoff: handoff.map { ($0.since, $0.at) }, settings: settings)
        let usedHandoff = plan.handoff ? handoff : nil
        handoff = nil
        speakEndAt = nil
        var since = plan.since
        // Caps Lock: オンになる前の音は使わない (オンを見つける直前の読みの leadMs 前から)
        var capsTrimmedMs = 0
        if let g = gate, let on = g.snapshot.onStart(since: since), on > since {
            capsTrimmedMs = Int((on - since) / 1_000_000)
            since = on
        }
        let nowMic = PCM.now()
        log.event("listen.mic_ready", mode: .direct, fields: [
            "opened_now": openedNow, "input": input?.name ?? "",
            "preroll_ms": nowMic >= since ? Int((nowMic - since) / 1_000_000) : -Int((since - nowMic) / 1_000_000),
            "tail_guard_ms": plan.guardedMs, "handoff": plan.handoff, "caps_trimmed_ms": capsTrimmedMs])

        // 4) Realtime
        let lang = Self.isoLanguage(locale, fallback: settings.language)
        let rt = RealtimeSession(url: settings.realtimeURL)
        defer { rt.close() }
        let swWs = Stopwatch()
        try await rt.open(update: RealtimeSession.sessionUpdate(settings: settings, language: lang, keywords: keywords))
        log.event("listen.ws_ready", mode: .direct, fields: ["ms": swWs.ms])

        let sub = ring.subscribe(since: since)
        defer { ring.unsubscribe(sub.id) }
        let sessionStart = sub.backlog.first?.start ?? max(PCM.now(), since)
        let echoRef = lastSpeak

        enum Signal: Sendable { case event(RealtimeEvent), tick, failure(String) }
        let (signals, sig) = AsyncStream<Signal>.makeStream()

        // 音を送る
        let sender = Task {
            do {
                for p in sub.backlog { try await rt.append(await gate?.masked(p).data ?? p.data) }
                for await p in sub.stream {
                    guard let piece = p.sliced(from: since) else { continue }
                    try await rt.append(await gate?.masked(piece).data ?? piece.data)
                }
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
        var itemStartMs: [String: Int] = [:]
        var discardedEcho = 0

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
                // Caps Lock がオフになり、まだ話していない: Realtime を閉じて待つ所に戻る。
                // 話し始めの知らせ (speech_started) は 0.4〜0.6 秒遅れるので、オフから silenceMs + 1 秒は待つ
                if let g = gate, !g.isOn, !tracker.heardSpeech, !tracker.speaking, committedForLimit == nil,
                   g.secondsInState() >= Double(settings.silenceMs) / 1000 + 1.0 {
                    return .capsOff(onSeconds: max(0, now.timeIntervalSince(bodyStart) - g.secondsInState()))
                }
                if let limit = committedForLimit {
                    if now.timeIntervalSince(limit) > 5 { return .text(tracker.partialText) }
                } else if let dl = speechDeadline, now > dl {
                    // 話が長すぎる: いったん区切って書き起こし、返す。
                    try? await rt.commit()
                    committedForLimit = now
                    log.event("asr.max_speech", mode: .direct, fields: ["seconds": settings.maxSpeechSeconds])
                } else if !tracker.heardSpeech, !tracker.speaking, now > waitDeadline {
                    log.event("asr.timeout", mode: .direct, fields: ["timeout": timeout,
                                                                     "discarded_empty": tracker.discardedEmpty,
                                                                     "discarded_echo": discardedEcho])
                    return .text("")
                }
            case .event(let ev):
                switch ev {
                case .speechStarted(let item, let startMs):
                    itemStartMs[item] = startMs
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
                var tracked = ev
                if case .completed(let item, let transcript) = ev, let ref = echoRef,
                   let v = echoVerdict(transcript: transcript, item: item, itemStartMs: itemStartMs,
                                       sessionStart: sessionStart, speak: ref, settings: settings) {
                    // 直前の読み上げを拾ったもの: 空として扱い、聞き続ける (聞き直す)。
                    discardedEcho += 1
                    tracked = .completed(item: item, transcript: "")
                    speechDeadline = nil
                    log.event("asr.discarded_echo", mode: .direct, fields: [
                        "text": transcript, "score": v.verdict.score, "reason": v.verdict.reason,
                        "after_speak_end_ms": v.afterSpeakEndMs, "count": discardedEcho])
                }
                if case .finish(let text) = tracker.handle(tracked) {
                    return .text(stripHandoffEcho(text, handoff: usedHandoff, settings: settings))
                }
                if case .completed = ev, committedForLimit != nil, !tracker.speaking {
                    return .text(stripHandoffEcho(tracker.partialText, handoff: usedHandoff, settings: settings))
                }
            }
        }
        if Task.isCancelled { throw CancellationError() }
        throw TalkError.realtime("セッションが途中で終わりました")
    }

    /// listen の音の始点。`handoff` (読み上げ中に割り込んだ発話の話し始め) があればそこから (tail guard を掛けない)。
    /// 無ければ今まで通り: 直前の speak の終わり (prerollMaxSeconds 以内) か listen の prerollLeadSeconds 前の早い方。
    /// ただし読み上げの終わり + speakTailGuardMs より前にはしない。
    static func prerollPlan(listenAt: UInt64, speakEndAt: UInt64?, lastSpeakEnd: UInt64?,
                            handoff: (since: UInt64, at: UInt64)?, settings: DirectSettings)
        -> (since: UInt64, guardedMs: Int, handoff: Bool) {
        if let h = handoff, listenAt >= h.at,
           Double(listenAt - h.at) / 1e9 <= settings.bargeIn.handoffMaxSeconds {
            let lead = UInt64(max(settings.bargeIn.handoffLeadMs, 0)) * 1_000_000
            return (h.since > lead ? h.since - lead : 0, 0, true)
        }
        let maxBack = UInt64(settings.prerollMaxSeconds * 1e9)
        let leadNs = UInt64(settings.prerollLeadSeconds * 1e9)
        var since = listenAt > leadNs ? listenAt - leadNs : 0
        if let end = speakEndAt, end <= listenAt, listenAt - end <= maxBack { since = min(since, end) }
        // 読み上げの終わり + speakTailGuardMs より前の音は使わない (読み上げの最後を拾わない)。
        // listen がそれより早く来た時は、始点が少し先になる (届いた音もその時刻までは送らない)。
        var guardedMs = 0
        if let end = lastSpeakEnd, settings.speakTailGuardMs > 0 {
            let floor = end &+ UInt64(settings.speakTailGuardMs) * 1_000_000
            if since < floor {
                guardedMs = Int((floor - since) / 1_000_000)
                since = floor
            }
        }
        return (since, guardedMs, false)
    }

    /// 割り込んだ発話の書き起こしの頭が、読み上げの残り (聞こえた所までの文に似ている) なら外す。
    private func stripHandoffEcho(_ text: String, handoff: (since: UInt64, at: UInt64, heard: String)?,
                                  settings: DirectSettings) -> String {
        guard let h = handoff, settings.bargeIn.echoFilter, !text.isEmpty else { return text }
        let (rest, removed) = EchoFilter.stripEchoPrefix(transcript: text, spoken: h.heard, threshold: settings.echoSimilarity)
        guard !removed.isEmpty, !rest.isEmpty else { return text }
        log.event("listen.echo_prefix_removed", mode: .direct, fields: ["removed": removed, "kept": rest])
        return rest
    }

    /// 書き起こしが直前の読み上げを拾ったものなら判定を返す (捨てる)。発話の始まりが読み上げの終わりから
    /// echoWindowMs を超えていれば、ユーザーが言い返したものとみなして捨てない。
    private func echoVerdict(transcript: String, item: String, itemStartMs: [String: Int], sessionStart: UInt64,
                             speak: (text: String, endAt: UInt64), settings: DirectSettings)
        -> (verdict: EchoFilter.Verdict, afterSpeakEndMs: Int)? {
        guard settings.echoWindowMs > 0, settings.echoSimilarity > 0 else { return nil }
        let startMs = max(itemStartMs[item] ?? 0, 0)
        let startAt = sessionStart &+ UInt64(startMs) * 1_000_000
        let after = startAt >= speak.endAt ? Int((startAt - speak.endAt) / 1_000_000)
                                           : -Int((speak.endAt - startAt) / 1_000_000)
        guard after <= settings.echoWindowMs else { return nil }
        let v = EchoFilter.judge(transcript: transcript, spoken: speak.text, threshold: settings.echoSimilarity)
        return v.isEcho ? (v, after) : nil
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

    /// shared なら録音と読み上げを 1 つの engine (VoiceAudioEngine、VPIO) で。テストの入力はその中に包む
    /// (テストの参照信号を使う時は包まない: 出力の engine も使わない)。
    private func startInput(shared: Bool, settings: DirectSettings) throws {
        ring.reset()
        testReferenceRing.reset()
        let inp: AudioInput
        do {
            if shared, testSpeakReference == nil {
                let scripted = customMakeInput == nil ? try ScriptedWavInput.fromEnvironment() : nil
                let test: AudioInput? = try customMakeInput?() ?? scripted ?? WavFileInput.fromEnvironment()
                let engine = VoiceAudioEngine(options: settings.bargeIn.audioOptions, testInput: test)
                // テスト: 鳴らした音 (参照信号) を小さくして遅らせ、マイクの音に足す (CLAUDE_TALK_VOICE_TEST_ECHO = dB@ms)
                if let scripted, let e = ScriptedWavInput.parseEcho(ProcessInfo.processInfo.environment["CLAUDE_TALK_VOICE_TEST_ECHO"]) {
                    scripted.echo = (engine.reference, e.gainDb, e.delayMs)
                }
                let log = self.log
                engine.onEvent = { name, fields in log.event(name, mode: .direct, fields: fields) }
                inp = engine
            } else {
                inp = try makeInput()
            }
            try inp.start(into: ring)
        } catch {
            micLock.unlock()
            throw error
        }
        inputShared = shared
        input = inp
        micVerified = false
        log.event("mic.open", mode: .direct, fields: ["input": inp.name])
    }

    public func closeMic(reason: String) {
        guard let inp = input else { return }
        capsGate?.stop()
        capsGate = nil
        inp.stop()
        input = nil
        micVerified = false
        micLock.unlock()
        log.event("mic.close", mode: .direct, fields: ["reason": reason])
    }

    public var isMicOpen: Bool { input != nil }

    /// Caps Lock の門 (マイクを開けている間だけ読む)。無効なら nil。設定が変わったら作り直す。
    private func ensureCapsGate(_ s: CapsLockSettings) -> CapsLockGate? {
        guard s.enabled, input != nil else {
            capsGate?.stop()
            capsGate = nil
            return nil
        }
        if let g = capsGate, g.settings == s { return g }
        capsGate?.stop()
        let g = CapsLockGate(settings: s, reader: capsReader)
        let log = self.log
        let real = capsReader == nil
        g.onChange = { on in
            var f: [String: Any] = ["on": on, "source": s.source]
            // 本物の時は両方の読み方を残す (食い違わないかを後で見る)
            if real { f["flags"] = FlagsCapsLockReader().isOn(); f["hid"] = HIDCapsLockReader().isOn() }
            log.event("caps_lock.change", mode: .direct, fields: f)
        }
        g.start()
        capsGate = g
        return g
    }

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
