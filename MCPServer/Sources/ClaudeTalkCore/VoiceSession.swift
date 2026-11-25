//
//  VoiceSession.swift
//  ClaudeTalkCore
//
//  claude-talk-voice の本体 (案 2。段 a = ヘッドホン前提、段 b = スピーカーでも使う層を重ねた)。
//    マイク → speech serve の Realtime (Silero VAD + Haas、常につないだまま)
//      → 話し終わったら書き起こしを claude (stream-json) に user メッセージで送る
//      → text_delta を文に区切って speech serve (既定 Qwen3-TTS 0.6B serena) で次々に読み上げる
//      → 読み上げ中・考え中にユーザーが bargeInMs 以上話したら、読み上げを止めて interrupt を送り、聞く
//  合図 (「どうぞ」等) は付けない。
//
//  スピーカーで使うための層 (段 b、voice/settings.json で個別に切れる):
//    1. 録音と読み上げを 1 つの AVAudioEngine で (sharedEngine) + VPIO (voiceProcessing): エコー除去・ノイズ抑制
//    2. 割り込みの判定 (echoGate): VAD の話し始めの後、マイクの音が「読み上げの参照信号から予想されるエコー」より
//       十分大きい時だけ止める。足りなければ発話が続く間 100ms ごとに見直す
//    3. 書き起こしが今・直前の読み上げ文と似ていたら捨てる (echoFilter)。割り込みで止めた後に似ていたら
//       voice.false_barge_in (誤って止めた) としてログに残す
//
//  timing.jsonl (mode=voice) のイベント:
//    voice.start / claude.spawn / claude.init / asr.open / asr.speech_started / asr.speech_stopped / voice.asr_completed
//    voice.sent / claude.started / claude.first_delta / voice.first_sentence / tts.sentence / tts.first_audio
//    claude.tool_use / claude.permission / claude.result / voice.reply_done / voice.barge_in / claude.interrupt_ack
//    voice.ignored (相づち・空・残り音) / voice.stop
//    audio.engine_start / audio.config_change / voice.barge_rejected (エコーとみなして止めなかった最初の判定)
//    voice.gate_item (返事の途中の発話ごとの判定のまとめ) / voice.false_barge_in
//  1 往復の番号 (turn) は claude に送るたびに 1 増える。"ms" は経過時間、"after_speech_end_ms" は話し終えてから。
//

import Foundation

public actor VoiceSession {
    public typealias Printer = @Sendable (String) -> Void

    private let voice: VoiceSettings
    private let direct: DirectSettings
    private let resume: String?
    private let input: AudioInput
    /// 録音と読み上げの共有 engine (sharedEngine の時。input と同じもの)
    private let audio: VoiceAudioEngine?
    private let print: Printer
    private let log = TimingLog.shared
    private let ring = AudioRing(retainSeconds: 15)
    private let micLock = FileLock(url: TalkPaths.micLock)
    private let started = Stopwatch()
    private var claude: ClaudeProcess?
    private var tasks: [Task<Void, Never>] = []
    private var stopped = false
    private var finished: CheckedContinuation<Void, Never>?
    public private(set) var sessionId: String?

    // 1 往復
    private var turn = 0
    private var pendingUser: [String] = []
    private var openItems: Set<String> = []
    private var itemStartedAt: [String: Date] = [:]
    /// 返事の途中で話し始めた発話 (bargeInMs に届く前に終わったものは相づちとして捨てる)。
    private var itemDuringReply: Set<String> = []
    private var itemBargedIn: Set<String> = []
    private var speechEnd: (at: Date, src: String)?
    private var sentAt: Date?
    private var turnSpeechEnd: (at: Date, src: String)?
    private var interruptedNote: String?

    // claude
    private var currentUuid: String?
    private var activeUuid: String?
    private var outstanding: Set<String> = []
    private var firstDeltaLogged = false
    private var firstSentenceLogged = false
    private var splitter: SentenceSplitter
    private var speaker: ReplySpeaker?
    private var lastHeard: (text: String, endAt: Date)?
    private var interruptSentAt: [String: Date] = [:]
    private var interruptCount = 0
    private var asrSessionStart: UInt64 = 0
    private var lastActivity = Date()
    /// 発話の始まり (マイクの音の時刻、PCM.now() と同じ時計)
    private var itemAudioStart: [String: UInt64] = [:]
    /// 割り込みの判定で「エコー」とした回数 / 最後の判定
    private var itemRejections: [String: Int] = [:]
    private var itemLastVerdict: [String: EchoGate.Verdict] = [:]

    public init(voice: VoiceSettings, direct: DirectSettings, resume: String?, input: AudioInput,
                print: @escaping Printer) {
        self.voice = voice
        self.direct = direct
        self.resume = resume
        self.input = input
        self.audio = input as? VoiceAudioEngine
        self.print = print
        splitter = SentenceSplitter(firstChunkMinChars: voice.firstChunkMinChars)
    }

    private func ev(_ name: String, _ fields: [String: Any] = [:]) {
        var f = fields
        f["turn"] = turn
        log.event(name, modeName: "voice", fields: f)
    }

    private func sinceMs(_ d: Date?) -> Int? { d.map { Int(Date().timeIntervalSince($0) * 1000) } }

    // MARK: - 起動・終了

    /// 起動して、止められる (shutdown) か claude が終わるまで待つ。
    public func run() async throws {
        ev("voice.start", ["input": input.name, "cwd": voice.cwdPath, "model": voice.model ?? "",
                           "tools": voice.tools, "resume": resume ?? "",
                           "shared_engine": audio != nil, "voice_processing": audio != nil && voice.voiceProcessing,
                           "echo_gate": voice.echoGate.enabled, "echo_filter": voice.echoFilter,
                           "barge_in_ms": voice.bargeInMs])
        if let audio {
            let log = self.log
            audio.onEvent = { name, fields in log.event(name, modeName: "voice", fields: fields) }
        }
        // 1) マイクの取り合いを防ぐ (MCP の direct モードと同じロック)
        guard await micLock.lock(timeout: direct.micLockWaitSeconds) else { throw TalkError.micBusy }
        do {
            try input.start(into: ring)
        } catch {
            micLock.unlock()
            throw error
        }
        ev("mic.open", ["input": input.name])

        // 2) speech serve (書き起こし) と読み上げの serve (既定 Qwen 8768) を並行で起こす
        let direct = self.direct
        async let asrReady: Bool = SpeechServer(settings: direct).ensureRunning()
        async let ttsReady: Bool = TTSServer(settings: direct).ensureRunning(timeout: direct.serverStartTimeoutSeconds)
        // 3) claude
        try spawnClaude()
        let a = try await asrReady
        let t = try await ttsReady
        ev("server.ready", ["ms": started.ms, "asr_started": a, "tts_started": t])

        // 4) 書き起こしの常時接続
        tasks.append(Task.detached { [weak self] in await self?.asrLoop() })
        if let scripted = scriptedInput {
            tasks.append(Task.detached { [weak self] in await self?.testIdleWatch(scripted) })
        }
        print("[聞いています。止めるには Ctrl-C]")
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            if stopped { c.resume() } else { finished = c }
        }
    }

    public func shutdown(reason: String) {
        guard !stopped else { return }
        stopped = true
        speaker?.stop()
        speaker = nil
        for t in tasks { t.cancel() }
        input.stop()
        micLock.unlock()
        let c = claude
        claude = nil
        c?.terminate()
        ev("voice.stop", ["reason": reason, "ms": started.ms, "session_id": sessionId ?? ""])
        if let sid = sessionId { print("[終了 (\(reason))。続きから: claude-talk-voice --resume \(sid)]") }
        finished?.resume()
        finished = nil
    }

    private func spawnClaude() throws {
        TalkPaths.ensureDir(URL(fileURLWithPath: voice.cwdPath, isDirectory: true))
        let sid = resume == nil ? UUID().uuidString.lowercased() : nil
        let args = voice.claudeArguments(sessionId: sid, resume: resume)
        let sw = Stopwatch()
        let p = try ClaudeProcess(executable: voice.claudeBin, arguments: args, cwd: voice.cwdPath,
                                  stderrLog: TalkPaths.voiceClaudeStderr)
        claude = p
        sessionId = sid ?? resume
        // 先に initialize を送る: SessionStart の hook などを最初の発話より前に済ませる (API は呼ばない)。
        p.send(["type": "control_request", "request_id": "voice-init",
                "request": ["subtype": "initialize"]])
        ev("claude.spawn", ["ms": sw.ms, "pid": Int(p.pid), "session_id": sessionId ?? ""])
        tasks.append(Task.detached { [weak self] in
            for await e in p.events { await self?.handleClaude(e) }
            await self?.claudeExited(status: p.exitStatus)
        })
    }

    private func claudeExited(status: Int32?) {
        guard !stopped else { return }
        ev("claude.exit", ["status": Int(status ?? -1)])
        print("[claude が終了しました (status \(status ?? -1))。\(TalkPaths.voiceClaudeStderr.path) を見てください]")
        shutdown(reason: "claude_exit")
    }

    /// テストの WAV を流し終え、返事も終わって 3 秒たったら終わる。
    private func testIdleWatch(_ s: ScriptedWavInput) async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if s.allPlayed, isIdle, Date().timeIntervalSince(lastActivity) > 3 {
                shutdown(reason: "test_script_done")
                return
            }
        }
    }

    private var isIdle: Bool { outstanding.isEmpty && speaker == nil && openItems.isEmpty && pendingUser.isEmpty }

    // MARK: - 書き起こし (常時接続)

    private func asrLoop() async {
        let keywords = Vocabulary.load()
        var attempt = 0
        while !Task.isCancelled {
            attempt += 1
            let rt = RealtimeSession(url: direct.realtimeURL, requestTimeout: 24 * 3600)
            do {
                try await rt.open(update: RealtimeSession.sessionUpdate(settings: direct, language: direct.language,
                                                                         keywords: keywords))
                let since = PCM.now()
                let sub = ring.subscribe(since: since)
                setAsrStart(since)
                ev("asr.open", ["attempt": attempt, "keywords": keywords.count, "ms": started.ms])
                if attempt == 1 { input.trigger("ready") }
                let sender = Task {
                    for p in sub.backlog { try? await rt.append(p.data) }
                    for await p in sub.stream {
                        guard let piece = p.sliced(from: since) else { continue }
                        do { try await rt.append(piece.data) } catch { break }
                    }
                }
                defer { sender.cancel(); ring.unsubscribe(sub.id); rt.close() }
                while !Task.isCancelled {
                    let e = try await rt.receive()
                    if case .error(let m) = e { throw TalkError.realtime(m) }
                    handleASR(e)
                }
            } catch {
                if Task.isCancelled || stopped { return }
                ev("asr.reconnect", ["error": error.localizedDescription, "attempt": attempt])
                rt.close()
                openItems.removeAll()
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private func setAsrStart(_ t: UInt64) { asrSessionStart = t }

    private func wallDate(audioMs: Int) -> Date {
        let up = asrSessionStart &+ UInt64(max(audioMs, 0)) * 1_000_000
        let now = PCM.now()
        return Date().addingTimeInterval(-Double(Int64(bitPattern: now &- up)) / 1e9)
    }

    /// テスト用の WAV 入力 (共有 engine に包まれていても見る)
    private var scriptedInput: ScriptedWavInput? {
        (input as? ScriptedWavInput) ?? (audio?.wrappedTestInput as? ScriptedWavInput)
    }

    private var replying: Bool { !outstanding.isEmpty || speaker != nil }

    private func handleASR(_ e: RealtimeEvent) {
        switch e {
        case .speechStarted(let item, let startMs):
            lastActivity = Date()
            openItems.insert(item)
            itemStartedAt[item] = Date()
            if startMs >= 0 { itemAudioStart[item] = asrSessionStart &+ UInt64(startMs) * 1_000_000 }
            let during = replying
            if during { itemDuringReply.insert(item) }
            ev("asr.speech_started", ["audio_start_ms": startMs, "during_reply": during])
            if during {
                let wait = UInt64(max(voice.bargeInMs, 0)) * 1_000_000
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: wait)
                    await self?.bargeInIfStillSpeaking(item)
                }
            }
        case .speechStopped(let item, let endMs):
            lastActivity = Date()
            let raw = wallDate(audioMs: endMs)
            // speech serve の audio_end_ms は話し終わりより prefix_padding 程度後ろ (timing-report と同じ推定)。
            var end = (at: raw.addingTimeInterval(-Double(direct.prefixPaddingMs) / 1000), src: "vad")
            if let s = scriptedInput, let w = s.lastSpeechEnd { end = (w, "wav") }
            if !itemDuringReply.contains(item) || itemBargedIn.contains(item) { speechEnd = end }
            ev("asr.speech_stopped", ["audio_end_ms": endMs,
                                       "speech_end_at": Int64((raw.timeIntervalSince1970 * 1000).rounded()),
                                       "est_speech_end_at": Int64((end.at.timeIntervalSince1970 * 1000).rounded()),
                                       "src": end.src])
        case .completed(let item, let transcript):
            lastActivity = Date()
            openItems.remove(item)
            completed(item: item, text: transcript.trimmingCharacters(in: .whitespacesAndNewlines))
        case .failed(let item, let m):
            openItems.remove(item)
            ev("asr.failed", ["error": m])
            maybeSend()
        default:
            break
        }
    }

    private func completed(item: String, text: String) {
        let afterEnd = sinceMs(speechEnd?.at)
        let barged = itemBargedIn.contains(item)
        if itemDuringReply.contains(item), voice.echoGate.enabled {
            var f: [String: Any] = ["barged_in": barged, "rejections": itemRejections[item] ?? 0, "text": text]
            if let v = itemLastVerdict[item] { f["last"] = v.fields }
            ev("voice.gate_item", f)
        }
        defer {
            itemDuringReply.remove(item)
            itemBargedIn.remove(item)
            itemStartedAt[item] = nil
            itemAudioStart[item] = nil
            itemRejections[item] = nil
            itemLastVerdict[item] = nil
        }
        if text.isEmpty {
            ev("voice.ignored", ["reason": "empty"])
            maybeSend()
            return
        }
        if itemDuringReply.contains(item), !itemBargedIn.contains(item) {
            // 返事の途中の短い発話 (相づち)。止めずに捨てる。
            ev("voice.ignored", ["reason": "backchannel", "text": text])
            print("  (相づちとして流しました: \(text))")
            maybeSend()
            return
        }
        if voice.echoFilter {
            // 今鳴っている返事の聞こえた所までと、直前の返事 (echoWindowMs 以内) の両方と比べる。
            var spoken: [String] = []
            if let sp = speaker { let h = sp.progress.heardText; if !h.isEmpty { spoken.append(h) } }
            if let h = lastHeard, Date().timeIntervalSince(h.endAt) * 1000 <= Double(direct.echoWindowMs) || speaker?.isSounding == true {
                spoken.append(h.text)
            }
            for sp in spoken {
                let v = EchoFilter.judge(transcript: text, spoken: sp, threshold: direct.echoSimilarity)
                guard v.isEcho else { continue }
                ev("voice.ignored", ["reason": "echo", "text": text, "score": v.score, "barged_in": barged])
                if barged {
                    // 割り込みで止めたのに、書き起こしは読み上げの残りだった (誤って止めた)。
                    ev("voice.false_barge_in", ["text": text, "score": v.score, "echo_reason": v.reason])
                    print("  (読み上げの残りの音で止まりました: \(text))")
                }
                maybeSend()
                return
            }
        }
        var text = text
        if voice.echoFilter, itemDuringReply.contains(item), let h = lastHeard ?? speaker.map({ ($0.progress.heardText, Date()) }) {
            // 読み上げのエコーで始まり、ユーザーの声が続いた発話: 頭のエコーの部分を外す
            let (rest, removed) = EchoFilter.stripEchoPrefix(transcript: text, spoken: h.text, threshold: direct.echoSimilarity)
            if !removed.isEmpty, !rest.isEmpty {
                ev("voice.echo_prefix_removed", ["removed": removed, "kept": rest])
                text = rest
            }
        }
        ev("voice.asr_completed", ["chars": text.count, "after_speech_end_ms": afterEnd ?? -1])
        pendingUser.append(text)
        if turnSpeechEnd == nil || speechEnd != nil { turnSpeechEnd = speechEnd }
        maybeSend()
    }

    /// 話している途中の発話が無く、聞いた文があれば claude に送る。
    private func maybeSend() {
        guard openItems.isEmpty, !pendingUser.isEmpty, let claude else { return }
        var text = pendingUser.joined(separator: " ")
        pendingUser.removeAll()
        if let note = interruptedNote {
            text = note + "\n" + text
            interruptedNote = nil
        }
        turn += 1
        log.setTurn(turn)
        let uuid = UUID().uuidString.lowercased()
        currentUuid = uuid
        outstanding.insert(uuid)
        firstDeltaLogged = false
        firstSentenceLogged = false
        splitter.reset()
        claude.send(ClaudeEvent.userMessage(text: text, uuid: uuid))
        sentAt = Date()
        let end = turnSpeechEnd
        turnSpeechEnd = nil
        speechEnd = nil
        ev("voice.sent", ["chars": text.count, "after_speech_end_ms": sinceMs(end?.at) ?? -1,
                          "speech_end_src": end?.src ?? "", "uuid": uuid])
        print("あなた: \(text)")
        appendTranscript("user", text)
        sentEnd = end
        input.trigger("sent")
        lastActivity = Date()
    }

    private var sentEnd: (at: Date, src: String)?

    // MARK: - 割り込み

    /// 割り込みの判定 (層 2): 直近 bargeInMs のマイクの音が人の声か、読み上げのエコーか。
    private func gateVerdict(_ item: String) -> EchoGate.Verdict {
        EchoGate.evaluateRings(mic: ring, reference: audio?.reference, itemAudioStart: itemAudioStart[item],
                               now: PCM.now(), bargeInMs: voice.bargeInMs, config: voice.echoGate)
    }

    private func bargeInIfStillSpeaking(_ item: String) {
        guard !stopped, openItems.contains(item), itemDuringReply.contains(item), replying,
              !itemBargedIn.contains(item) else { return }
        var verdict: EchoGate.Verdict?
        if voice.echoGate.enabled {
            let v = gateVerdict(item)
            verdict = v
            itemLastVerdict[item] = v
            if !v.isVoice {
                let n = (itemRejections[item] ?? 0) + 1
                itemRejections[item] = n
                let elapsed = sinceMs(itemStartedAt[item]) ?? 0
                if n == 1 {
                    var f = v.fields
                    f["after_speech_started_ms"] = elapsed
                    ev("voice.barge_rejected", f)
                }
                let limit = voice.echoGate.recheckMs
                if limit < 0 || elapsed < voice.bargeInMs + limit {
                    Task { [weak self] in
                        try? await Task.sleep(nanoseconds: 100_000_000)
                        await self?.bargeInIfStillSpeaking(item)
                    }
                }
                return
            }
        }
        itemBargedIn.insert(item)
        let progress = speaker?.stop()
        speaker = nil
        var interrupted = false
        if !outstanding.isEmpty, let claude {
            interruptCount += 1
            let id = "voice-int-\(interruptCount)"
            interruptSentAt[id] = Date()
            claude.send(ClaudeEvent.interruptRequest(id: id))
            interrupted = true
        }
        // この後の text_delta は捨てる (割り込んだ返事の残り)。
        currentUuid = nil
        let heard = progress?.heardText ?? ""
        if !heard.isEmpty { lastHeard = (heard, Date()) }
        if voice.tellInterrupted, !heard.isEmpty {
            let tail = heard.count > 60 ? "…" + String(heard.suffix(60)) : heard
            interruptedNote = "(割り込み: あなたの前の返事は「\(tail)」まで読み上げたところで止めました)"
        }
        var bf: [String: Any] = ["after_speech_started_ms": sinceMs(itemStartedAt[item]) ?? -1,
                                 "claude_generating": interrupted, "heard_chars": heard.count,
                                 "sentences_started": progress?.sentencesStarted ?? 0,
                                 "played_s": ((progress?.playedSeconds ?? 0) * 100).rounded() / 100,
                                 "rejections": itemRejections[item] ?? 0]
        if let v = verdict { bf["gate"] = v.fields }
        ev("voice.barge_in", bf)
        print("  [割り込み: 読み上げを止めました\(interrupted ? "、返事の生成も止めました" : "")]")
    }

    // MARK: - claude

    private func handleClaude(_ e: ClaudeEvent) {
        guard !stopped else { return }
        switch e {
        case .initialized(let sid, let model, let tools):
            if sessionId == nil || sessionId != sid { sessionId = sid }
            ev("claude.init", ["ms": started.ms, "session_id": sid, "model": model, "tools": tools.joined(separator: ",")])
        case .commandStarted(let uuid):
            activeUuid = uuid
            ev("claude.started", ["after_sent_ms": sinceMs(sentAt) ?? -1, "current": uuid == currentUuid])
        case .commandEnded(let uuid, let state):
            outstanding.remove(uuid)
            if state != "completed" { ev("claude.command_end", ["state": state]) }
        case .textDelta(let t):
            guard let cur = currentUuid, activeUuid == cur else { return }
            if !firstDeltaLogged {
                firstDeltaLogged = true
                ev("claude.first_delta", ["after_sent_ms": sinceMs(sentAt) ?? -1,
                                          "after_speech_end_ms": sinceMs(sentEnd?.at) ?? -1])
            }
            enqueue(splitter.feed(t))
        case .toolUseStart(let name):
            guard let cur = currentUuid, activeUuid == cur else { return }
            enqueue(splitter.flush())
            ev("claude.tool_use", ["tool": name])
            print("  [ツール: \(name)]")
        case .assistant(let text, _):
            guard let cur = currentUuid, activeUuid == cur, !text.isEmpty else { return }
            print("Claude: \(text)")
            appendTranscript("claude", text)
        case .result(let subtype, let isError, let dur, let api, _, let sid):
            let isCurrent = currentUuid != nil && activeUuid == currentUuid
            if let a = activeUuid { outstanding.remove(a) }
            ev("claude.result", ["subtype": subtype, "is_error": isError, "duration_ms": dur ?? -1, "api_ms": api ?? -1,
                                 "current": isCurrent, "session_id": sid])
            if !sid.isEmpty { sessionId = sid }
            guard isCurrent else { return }
            enqueue(splitter.flush())
            if let sp = speaker {
                let t = turn
                Task { [weak self] in
                    let ok = await sp.finish()
                    await self?.replyDone(turn: t, speaker: sp, finished: ok)
                }
            }
            lastActivity = Date()
        case .canUseTool(let id, let tool, let input):
            let allow = voice.permits(tool: tool)
            claude?.send(ClaudeEvent.permissionResponse(
                requestId: id, allow: allow, input: input,
                message: "声の会話 (claude-talk-voice) ではこのツールは使えません。使わずに答えてください。"))
            ev("claude.permission", ["tool": tool, "allow": allow, "input": String(input.prefix(200))])
            print("  [権限の確認: \(tool) → \(allow ? "許可" : "拒否")]")
        case .otherControlRequest(let id, let sub):
            claude?.send(ClaudeEvent.errorResponse(requestId: id, message: "claude-talk-voice は \(sub) に対応していません"))
            ev("claude.control_request", ["subtype": sub])
        case .controlResponse(let id, let sub, let err):
            if id == "voice-init" {
                ev("claude.initialize_ack", ["ms": started.ms, "subtype": sub, "error": err ?? ""])
            } else if let at = interruptSentAt.removeValue(forKey: id) {
                ev("claude.interrupt_ack", ["ms": Int(Date().timeIntervalSince(at) * 1000), "subtype": sub,
                                            "error": err ?? ""])
            }
        default:
            break
        }
    }

    private func enqueue(_ sentences: [String]) {
        guard !sentences.isEmpty else { return }
        if !firstSentenceLogged {
            firstSentenceLogged = true
            ev("voice.first_sentence", ["chars": sentences[0].count, "after_sent_ms": sinceMs(sentAt) ?? -1,
                                        "after_speech_end_ms": sinceMs(sentEnd?.at) ?? -1])
        }
        if speaker == nil {
            let t = turn
            let sentAt = self.sentAt
            let sentEnd = self.sentEnd
            speaker = ReplySpeaker(settings: direct, turn: t, host: audio) { [weak self] stage in
                Task { await self?.handleTTS(stage, turn: t, sentAt: sentAt, speechEnd: sentEnd) }
            }
        }
        for s in sentences { speaker?.enqueue(s) }
    }

    private func handleTTS(_ stage: ReplySpeaker.Stage, turn t: Int, sentAt: Date?, speechEnd: (at: Date, src: String)?) {
        switch stage {
        case .firstAudio(let lead):
            ev("tts.first_audio", ["after_speech_end_ms": (sinceMs(speechEnd?.at) ?? -1) + Int(lead * 1000),
                                   "after_sent_ms": (sinceMs(sentAt) ?? -1) + Int(lead * 1000),
                                   "lead_ms": Int(lead * 1000), "speech_end_src": speechEnd?.src ?? "",
                                   "for_turn": t])
            if t == turn { input.trigger("tts_audio") }
        case .sentence(let i, let chars, let ms, let starved):
            ev("tts.sentence", ["index": i, "chars": chars, "first_chunk_ms": ms, "starved": starved, "for_turn": t])
        case .error(let m):
            ev("tts.error", ["error": m, "for_turn": t])
            print("  [読み上げの失敗: \(m)]")
        }
    }

    private func replyDone(turn t: Int, speaker sp: ReplySpeaker, finished ok: Bool) {
        let heard = sp.progress.heardText
        if !heard.isEmpty { lastHeard = (heard, Date()) }
        if speaker === sp { speaker = nil }
        ev("voice.reply_done", ["finished": ok, "for_turn": t, "played_s": (sp.progress.playedSeconds * 100).rounded() / 100])
        lastActivity = Date()
        if ok { input.trigger("reply_done") }
    }

    // MARK: - 書き起こしのログ

    private func appendTranscript(_ who: String, _ text: String) {
        let url = TalkPaths.voiceTranscript
        TalkPaths.ensureDir(url.deletingLastPathComponent())
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        let line = "\(f.string(from: Date())) [\(sessionId ?? "-")] \(who): \(text.replacingOccurrences(of: "\n", with: " "))\n"
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        if let h = FileHandle(forWritingAtPath: url.path) {
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: Data(line.utf8))
            try? h.close()
        }
    }
}
