//
//  EvalSpeakBarge.swift
//  claude-talk-voice
//
//  開発用 (T-0035): MCP の direct モードの speak の割り込みを、音を出さずに通しで数える。
//
//    CLAUDE_TALK_HOME=<試験用の home> claude-talk-voice --eval-speak-barge SPEC.json
//
//  1 件ごとに DirectEngine を作り、
//    - 読み上げの代わりに ref (録音した時に鳴らした音) を参照信号のリングに実時間で流す (WavReferencePlayback、出力の機器を使わない)
//    - マイクの代わりに「エコーの録音 + 人の発話 (大きさ L を位置 P に)」を speak の始まりから実時間で流す (WavFileInput)
//    - speak (本物の speech serve の Realtime VAD + EchoGate) → 止まったら listen (本物の Haas) で書き起こす
//  止まった時刻が人の発話の中なら「止まった」、前なら「誤って止まった」。listen の書き起こしを、その発話だけを聞かせた時の
//  書き起こしと比べる (頭が欠けていないか)。
//
//  SPEC.json: { "ref": "...", "echoes": {"名前": "WAV"}, "users": ["WAV"], "short": ["相づちの WAV"],
//               "levelsDb": [-30, -38, -46], "positionsMs": [2500, 5500, 8000], "shortLevelsDb": [-38],
//               "shortPositionsMs": [2500, 5500], "workDir": "...", "text": "読み上げたことにする文", "limit": 0 }
//

import ClaudeTalkCore
import Foundation

struct SpeakBargeSpec: Decodable {
    var ref: String
    var echoes: [String: String]
    var users: [String]
    var short: [String]?
    var levelsDb: [Double]
    var positionsMs: [Int]
    var shortLevelsDb: [Double]?
    var shortPositionsMs: [Int]?
    var workDir: String
    var text: String?
    var limit: Int?
    /// true なら基準の書き起こしだけ出して終わる
    var refsOnly: Bool?
}

/// 試験用のマイク: speak_start の合図で「エコーの録音 + 人の発話」を実時間で流す。speak_done の合図より後はエコーを
/// 消す (読み上げを止めたらスピーカーの音も止まる)。人の発話はそのまま続く。それ以外は小さな雑音。
final class EvalMicInput: AudioInput, @unchecked Sendable {
    let name = "eval-mic"
    private let echo: [Int16]
    private let user: [Int16]
    private let lock = NSLock()
    private var startAt: UInt64?
    private var echoEndAt: UInt64?
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "claude-talk.eval-mic")

    init(echo: [Int16], user: [Int16]) {
        self.echo = echo
        self.user = user
    }

    func trigger(_ event: String) {
        lock.lock(); defer { lock.unlock() }
        if event == "speak_start" || event == "listen", startAt == nil { startAt = PCM.now() + (event == "listen" ? 300_000_000 : 0) }
        if event == "speak_done", echoEndAt == nil { echoEndAt = PCM.now() }
    }

    func start(into ring: AudioRing) throws {
        let chunk = PCM.bytesPerSecond * 40 / 1000 / 2
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(40), leeway: .milliseconds(2))
        var next = PCM.now()
        t.setEventHandler { [weak self] in
            guard let self else { return }
            while next <= PCM.now() {
                self.lock.lock()
                let st = self.startAt, ee = self.echoEndAt
                self.lock.unlock()
                var out = [Int16](repeating: 0, count: chunk)
                for i in 0..<chunk {
                    var v = Int(Int16.random(in: -40...40))
                    let at = next &+ PCM.nanoseconds(bytes: i * 2)
                    if let st, at >= st {
                        let k = Int((at - st) * UInt64(PCM.sampleRate) / 1_000_000_000)
                        if k < self.user.count { v += Int(self.user[k]) }
                        if k < self.echo.count, ee == nil || at < ee! { v += Int(self.echo[k]) }
                    }
                    out[i] = Int16(max(-32768, min(32767, v)))
                }
                let piece = AudioPiece(start: next, data: out.withUnsafeBytes { Data($0) })
                ring.append(piece)
                next = piece.end
            }
        }
        timer = t
        t.resume()
    }

    func stop() { timer?.cancel(); timer = nil }
}

enum SpeakBargeEval {
    static func pcm(_ s: [Int16]) -> Data { s.withUnsafeBytes { Data($0) } }

    static func normalize(_ s: String) -> [Character] { EchoFilter.normalize(s) }

    static func cer(_ hyp: String, _ ref: String) -> Double {
        let h = normalize(hyp), r = normalize(ref)
        guard !r.isEmpty else { return h.isEmpty ? 0 : 1 }
        var prev = Array(0...h.count)
        for i in 1...r.count {
            var cur = [i] + [Int](repeating: 0, count: h.count)
            for j in 1...max(h.count, 1) where j <= h.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (r[i - 1] == h[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return Double(prev[h.count]) / Double(r.count)
    }

    /// 頭の 2 文字 (正規化後) が同じか
    static func headOK(_ hyp: String, _ ref: String) -> Bool {
        let h = normalize(hyp), r = normalize(ref)
        guard r.count >= 2 else { return true }
        return h.count >= 2 && Array(h.prefix(2)) == Array(r.prefix(2))
    }

    /// 発話に間があると listen は最初の区切りで返る。続きを 2 回まで聞いてつなぐ (全体の書き起こしを比べるため)。
    static func listenMore(_ e: DirectEngine) async -> String {
        var out = ""
        for _ in 0..<2 {
            let t = (try? await e.listen(timeout: 1.5, locale: "ja-JP")) ?? ""
            if t.isEmpty { break }
            out += t
        }
        return out
    }

    static func run(specPath: String) async throws {
        let spec = try JSONDecoder().decode(SpeakBargeSpec.self, from: Data(contentsOf: EchoGateEval.path(specPath)))
        let work = EchoGateEval.path(spec.workDir)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let ref = try EchoGateEval.load(spec.ref)
        let refData = pcm(ref)
        let text = spec.text ?? "今日は日本の四季について順番にお話しします。春は桜が咲き、夏は暑く、秋は紅葉がきれいで、冬は雪が降ります。"
        let (settings, warn) = DirectSettings.load()
        if let warn { print("[警告] \(warn)") }
        print("home: \(TalkPaths.home.path) bargeIn: \(settings.bargeIn.enabled) bargeInMs: \(settings.bargeIn.bargeInMs)")

        // 1) 人の発話だけの書き起こし (比べる基準)
        var refText: [String: String] = [:]
        var refFull: [String: String] = [:]
        for u in spec.users {
            let clip = try EchoGateEval.load(u)
            let mi = EvalMicInput(echo: [], user: clip)
            let e = DirectEngine(makeInput: { mi })
            let t = (try? await e.listen(timeout: 8, locale: "ja-JP")) ?? ""
            let rest = await listenMore(e)
            await e.closeMic(reason: "eval")
            refText[u] = t
            refFull[u] = t + rest
            print("ref  \(URL(fileURLWithPath: u).lastPathComponent): \(t) | \(rest)")
        }

        if spec.refsOnly == true {
            let d = try JSONSerialization.data(withJSONObject: ["first": refText, "full": refFull], options: [.prettyPrinted, .sortedKeys])
            try d.write(to: work.appendingPathComponent("refs.json"))
            return
        }
        struct Case { let name: String; let echo: String; let mic: [Int16]; let echoS: [Int16]; let userS: [Int16]; let user: String?; let onset: Int?; let offset: Int?; let short: Bool }
        var cases: [Case] = []
        for (ename, epath) in spec.echoes.sorted(by: { $0.key < $1.key }) {
            var echo = try EchoGateEval.load(epath)
            if echo.count < ref.count, !echo.isEmpty {
                var tiled: [Int16] = []
                while tiled.count < ref.count { tiled += echo }
                echo = Array(tiled.prefix(ref.count))
            }
            cases.append(Case(name: "\(ename)__none", echo: ename, mic: echo, echoS: echo, userS: [], user: nil, onset: nil, offset: nil, short: false))
            let groups: [(paths: [String], levels: [Double], positions: [Int], short: Bool)] = [
                (spec.users, spec.levelsDb, spec.positionsMs, false),
                (spec.short ?? [], spec.shortLevelsDb ?? [-38], spec.shortPositionsMs ?? [2500, 5500], true),
            ]
            for g in groups {
                for u in g.paths {
                    let clip = try EchoGateEval.load(u)
                    let (on, off) = EchoGateEval.onsetMs(clip)
                    let a = EchoGateEval.activeDb(clip)
                    for L in g.levels {
                        for P in g.positions {
                            let mic = EchoGateEval.mix(echo, clip, at: P * 24, gainDb: L - a)
                            let userS = EchoGateEval.mix([Int16](repeating: 0, count: P * 24 + clip.count), clip, at: P * 24, gainDb: L - a)
                            let n = "\(ename)__\(URL(fileURLWithPath: u).deletingPathExtension().lastPathComponent)__L\(Int(L))__P\(P)"
                            cases.append(Case(name: n, echo: ename, mic: mic, echoS: echo, userS: userS, user: u, onset: P + on, offset: P + off, short: g.short))
                        }
                    }
                }
            }
        }
        if let lim = spec.limit, lim > 0 { cases = Array(cases.prefix(lim)) }
        print("cases: \(cases.count)")

        struct Count { var userCases = 0, hits = 0, early = 0, echoOnly = 0, echoOnlyStops = 0, shortCases = 0, shortStops = 0
            var latencies: [Int] = [], listened = 0, headOK = 0, cers: [Double] = [] }
        var table: [String: Count] = [:]
        var rows: [[String: Any]] = []
        for (i, c) in cases.enumerated() {
            let wav = work.appendingPathComponent(c.name + ".wav")
            try EchoGateEval.writeWav(c.mic, to: wav)
            let mi = EvalMicInput(echo: c.echoS, user: c.userS)
            let engine = DirectEngine(makeInput: { mi }, testSpeakReference: refData)
            let sw = Stopwatch()
            let out = try await engine.speakOutcome(text: text, voice: nil, rate: nil, locale: "ja-JP")
            let stopMs = Int(out.playedSeconds * 1000)
            var row: [String: Any] = ["case": c.name, "echo": c.echo, "interrupted": out.interrupted, "stop_ms": stopMs,
                                      "heard_chars": out.heardText.count, "near_end": out.userStartedNearEnd]
            var cnt = table[c.echo] ?? Count()
            var listened: String?
            if let u = c.user, let on = c.onset, let off = c.offset {
                row["onset_ms"] = on
                if out.interrupted {
                    if stopMs < on {
                        if c.short { cnt.shortCases += 1 } else { cnt.userCases += 1; cnt.early += 1 }
                        row["result"] = "early"
                    } else {
                        let lat = stopMs - on
                        row["latency_ms"] = lat
                        row["result"] = "hit"
                        if c.short { cnt.shortCases += 1; cnt.shortStops += 1 } else {
                            cnt.userCases += 1; cnt.hits += 1; cnt.latencies.append(lat)
                        }
                        if !c.short {
                            let t = (try? await engine.listen(timeout: 6, locale: "ja-JP")) ?? ""
                            let full = t + (await listenMore(engine))
                            listened = t + " | " + full
                            let r = refText[u] ?? ""
                            let e = cer(full, refFull[u] ?? r)
                            row["listen"] = t
                            row["listen_full"] = full
                            row["ref"] = r
                            row["ref_full"] = refFull[u] ?? ""
                            row["cer_full"] = (e * 1000).rounded() / 1000
                            row["head_ok"] = headOK(t, r)
                            cnt.listened += 1
                            cnt.cers.append(e)
                            if headOK(t, r) { cnt.headOK += 1 }
                        }
                    }
                } else {
                    row["result"] = stopMs >= off ? "miss" : "miss"
                    if c.short { cnt.shortCases += 1 } else { cnt.userCases += 1 }
                }
            } else {
                cnt.echoOnly += 1
                if out.interrupted { cnt.echoOnlyStops += 1 }
                row["result"] = out.interrupted ? "false_stop" : "ok"
            }
            await engine.closeMic(reason: "eval")
            table[c.echo] = cnt
            rows.append(row)
            print("[\(i + 1)/\(cases.count)] \(c.name) → \(row["result"] ?? "") stop \(stopMs)ms onset \(c.onset ?? -1) \(sw.ms)ms\(listened.map { " listen「\($0)」" } ?? "")")
        }
        let rowsData = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
        try rowsData.write(to: work.appendingPathComponent("speak-barge-rows.json"))
        print("echo | 人の声で止まった | 遅れの中央 ms | 話す前に止まった | エコーだけで止まった | 相づちで止まった | listen の頭が合う | listen の CER 中央")
        var summary: [[String: Any]] = []
        for (k, c) in table.sorted(by: { $0.key < $1.key }) {
            let lat = c.latencies.sorted()
            let med = lat.isEmpty ? -1 : lat[lat.count / 2]
            let cs = c.cers.sorted()
            let cmed = cs.isEmpty ? -1 : (cs[cs.count / 2] * 1000).rounded() / 1000
            print("\(k) | \(c.hits)/\(c.userCases) | \(med) | \(c.early) | \(c.echoOnlyStops)/\(c.echoOnly) | \(c.shortStops)/\(c.shortCases) | \(c.headOK)/\(c.listened) | \(cmed)")
            summary.append(["echo": k, "hits": c.hits, "user_cases": c.userCases, "median_latency_ms": med, "early": c.early,
                            "echo_only_stops": c.echoOnlyStops, "echo_only": c.echoOnly, "short_stops": c.shortStops,
                            "short_cases": c.shortCases, "head_ok": c.headOK, "listened": c.listened, "median_cer": cmed])
        }
        let sData = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
        try sData.write(to: work.appendingPathComponent("speak-barge-summary.json"))
    }
}
