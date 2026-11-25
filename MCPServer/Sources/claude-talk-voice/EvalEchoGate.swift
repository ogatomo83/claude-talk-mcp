//
//  EvalEchoGate.swift
//  claude-talk-voice
//
//  開発用: 割り込み判定 (EchoGate) を、音を出さずに録音済みの WAV で数える。
//
//    claude-talk-voice --eval-echo-gate SPEC.json
//
//  SPEC.json:
//    { "ref": "読み上げの参照信号 (実際に鳴らした音)", "refOffsetMs": 0,
//      "echoes": { "名前": "その読み上げを鳴らしながら録ったマイクの音", ... },
//      "users": ["人の発話の WAV", ...], "levelsDb": [-30, -38, -46], "positionsMs": [2500, 5500, 8500],
//      "bargeInMs": [200, 300, 400, 500], "silenceMs": 500, "vadThreshold": 0.5,
//      "speechBin": "~/.local/bin/speech", "workDir": "書き出す場所", "gate": { EchoGateConfig の上書き },
//      "short": ["相づち (止まらない方がよい) の WAV", ...] }
//
//  マイク = エコーの録音 + 人の発話 (大きさを levelsDb にそろえて positionsMs に足す)。話し始めは speech.cpp の
//  Silero VAD (speech vad) の区間の始まり。Realtime の VAD と同じく、区間が終わって silenceMs たつまでは「話している」。
//  その間に bargeInMs (と recheck) の時点で判定し、止めた時刻が人の発話の中なら「止まった」、外なら「誤って止まった」。
//

import ClaudeTalkCore
import Foundation

struct EvalSpec: Decodable {
    var ref: String
    var refOffsetMs: Int?
    var echoes: [String: String]
    var users: [String]
    var short: [String]?
    var levelsDb: [Double]
    var positionsMs: [Int]
    var bargeInMs: [Int]
    var silenceMs: Int?
    var vadThreshold: Double?
    var speechBin: String?
    var workDir: String
    var gate: EchoGateConfig?
    var variants: [String: EchoGateConfig]?
}

enum EchoGateEval {
    static func path(_ s: String) -> URL { URL(fileURLWithPath: (s as NSString).expandingTildeInPath) }

    static func load(_ s: String) throws -> [Int16] {
        let d = try PCM.loadFile(path(s))
        return d.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    }

    static func writeWav(_ s: [Int16], to url: URL) throws {
        var d = Data()
        let dataBytes = s.count * 2
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(PCM.sampleRate); u32(PCM.sampleRate * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        s.withUnsafeBytes { d.append(contentsOf: $0) }
        try d.write(to: url)
    }

    /// 声のある 10ms (最大から 40dB 以内) の RMS を dB に。
    static func activeDb(_ s: [Int16]) -> Double {
        let f = EchoGate.frameDb(s)
        guard let mx = f.max() else { return -100 }
        let act = f.filter { $0 > mx - 40 }
        let e = act.map { pow(10, $0 / 10) }.reduce(0, +) / Double(max(act.count, 1))
        return 10 * log10(e + 1e-12)
    }

    static func onsetMs(_ s: [Int16]) -> (Int, Int) {
        let f = EchoGate.frameDb(s)
        guard let mx = f.max() else { return (0, 0) }
        let on = f.firstIndex { $0 > mx - 30 } ?? 0
        let off = f.lastIndex { $0 > mx - 30 } ?? 0
        return (on * EchoGate.frameMs, off * EchoGate.frameMs)
    }

    static func mix(_ base: [Int16], _ add: [Int16], at: Int, gainDb: Double) -> [Int16] {
        var out = base
        let g = pow(10, gainDb / 20)
        for i in 0..<add.count where at + i < out.count {
            let v = Double(out[at + i]) + Double(add[i]) * g
            out[at + i] = Int16(max(-32768, min(32767, v.rounded())))
        }
        return out
    }

    static func vad(_ files: [URL], bin: String, threshold: Double, silenceMs: Int) throws -> [String: [(Int, Int)]] {
        var result: [String: [(Int, Int)]] = [:]
        // 一度にたくさん渡す (モデルの読み込みは 1 回)
        for chunk in stride(from: 0, to: files.count, by: 200) {
            let part = Array(files[chunk..<min(files.count, chunk + 200)])
            let p = Process()
            p.executableURL = path(bin)
            p.arguments = ["vad", "silero-vad", "--format", "json", "--threshold", "\(threshold)",
                           "--min-silence-duration-ms", "100"] + part.map(\.path)
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let file = o["file"] as? String, let regs = o["regions"] as? [[String: Any]] else { continue }
                var rs: [(Int, Int)] = []
                for r in regs {
                    let s = Int(((r["start"] as? Double) ?? 0) * 1000), e = Int(((r["end"] as? Double) ?? 0) * 1000)
                    // Realtime の server_vad と同じく、silenceMs 未満の切れ目はつなぐ
                    if let last = rs.last, s - last.1 < silenceMs { rs[rs.count - 1].1 = e } else { rs.append((s, e)) }
                }
                result[URL(fileURLWithPath: file).lastPathComponent] = rs
            }
        }
        return result
    }

    struct Fire { let atMs: Int; let verdict: EchoGate.Verdict? }
    nonisolated(unsafe) static var lastRejected: EchoGate.Verdict?

    /// 1 つの話し始め (区間 s〜e) で、止めるならその時刻。
    static func decide(mic: [Int16], ref: [Int16], region: (Int, Int), bargeInMs: Int, silenceMs: Int,
                       gate: EchoGateConfig?) -> Fire? {
        let (s, e) = region
        let openUntil = e + silenceMs
        var t = s + bargeInMs
        guard t < openUntil else { return nil }
        guard let g = gate, g.enabled else { return Fire(atMs: t, verdict: nil) }
        let limit = g.recheckMs < 0 ? Int.max : s + bargeInMs + g.recheckMs
        let sr = PCM.sampleRate / 1000
        while t < openUntil && t <= limit {
            // 履歴は「今の窓の前」(見直しのたびに後ろへずらす)
            let from = max(0, max(s, t - bargeInMs) - g.historyMs - g.maxLagMs)
            let to = min(mic.count, t * sr)
            guard to > from * sr else { return nil }
            let m = Array(mic[(from * sr)..<to])
            let r = Array(ref[(from * sr)..<min(ref.count, to)]) + [Int16](repeating: 0, count: max(0, to - ref.count))
            // 窓は「今から bargeInMs 前」〜今 (見直しでは最近の音で決める)
            let judgeFrom = (max(s, t - bargeInMs) - from) * sr
            let v = EchoGate.evaluate(mic: m, ref: r, judgeFrom: judgeFrom, config: g)
            if v.isVoice { return Fire(atMs: t, verdict: v) }
            lastRejected = v
            t += 100
        }
        return nil
    }

    static func run(specPath: String) throws {
        let spec = try JSONDecoder().decode(EvalSpec.self, from: Data(contentsOf: path(specPath)))
        let work = path(spec.workDir)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let silence = spec.silenceMs ?? 500
        let bin = spec.speechBin ?? "~/.local/bin/speech"
        var refRaw = try load(spec.ref)
        if let off = spec.refOffsetMs, off > 0 { refRaw = [Int16](repeating: 0, count: off * 24) + refRaw }
        var variants: [(String, EchoGateConfig?)] = [("vad_only", nil)]
        var base = spec.gate ?? EchoGateConfig()
        base.enabled = true
        variants.append(("gate", base))
        for (k, v) in (spec.variants ?? [:]).sorted(by: { $0.key < $1.key }) { variants.append((k, v)) }

        struct Case { let name: String; let echo: String; let mic: [Int16]; let user: (Int, Int)?; let short: Bool; let level: Double? }
        var cases: [Case] = []
        let users = try spec.users.map { ($0, try load($0)) }
        let shorts = try (spec.short ?? []).map { ($0, try load($0)) }
        for (ename, epath) in spec.echoes.sorted(by: { $0.key < $1.key }) {
            var echo = try load(epath)
            // 参照信号より短い録音 (部屋の音だけ) は繰り返して長さをそろえる
            if echo.count < refRaw.count, !echo.isEmpty {
                var tiled: [Int16] = []
                while tiled.count < refRaw.count { tiled += echo }
                echo = Array(tiled.prefix(refRaw.count))
            }
            cases.append(Case(name: "\(ename)__none", echo: ename, mic: echo, user: nil, short: false, level: nil))
            for (ui, u) in (users.map { ($0, false) } + shorts.map { ($0, true) }).enumerated() {
                let ((upath, clip), isShort) = u
                let (on, off) = onsetMs(clip)
                let a = activeDb(clip)
                for L in spec.levelsDb {
                    for P in spec.positionsMs {
                        let mic = mix(echo, clip, at: P * 24, gainDb: L - a)
                        let n = "\(ename)__u\(ui)_\(URL(fileURLWithPath: upath).deletingPathExtension().lastPathComponent)__L\(Int(L))__P\(P)"
                        cases.append(Case(name: n, echo: ename, mic: mic, user: (P + on, P + off), short: isShort, level: L))
                    }
                }
            }
        }
        // 書き出して Silero でまとめて区間を出す
        var urls: [URL] = []
        for c in cases {
            let u = work.appendingPathComponent(c.name + ".wav")
            try writeWav(c.mic, to: u)
            urls.append(u)
        }
        let regions = try vad(urls, bin: bin, threshold: spec.vadThreshold ?? 0.5, silenceMs: silence)

        // 数える: [variant][bargeIn][echo] -> counts
        struct Count { var userCases = 0, hits = 0, falseStops = 0, echoOnlyCases = 0, echoOnlyFalse = 0
            var shortCases = 0, shortStops = 0, latencies: [Int] = [] }
        var table: [String: Count] = [:]
        var rows: [[String: Any]] = []
        for c in cases {
            let regs = regions[c.name + ".wav"] ?? []
            for B in spec.bargeInMs {
                for (vn, g) in variants {
                    var fires: [Int] = []
                    var verdicts: [[String: Any]] = []
                    for r in regs {
                        lastRejected = nil
                        defer { if let v = lastRejected { verdicts.append(["rejected": v.fields]) } }
                        if let f = decide(mic: c.mic, ref: refRaw, region: r, bargeInMs: B, silenceMs: silence, gate: g) {
                            fires.append(f.atMs)
                            if let v = f.verdict { verdicts.append(v.fields) }
                        }
                    }
                    let key = "\(vn)|\(B)|\(c.echo)"
                    var cnt = table[key] ?? Count()
                    var hit = false, falseN = 0, lat: Int?
                    // 最初に止めた時点で読み上げは止まる (その後のエコーは無い) ので、最初の 1 回だけで決める。
                    if let (u0, u1) = c.user {
                        if let t = fires.first {
                            if t >= u0 && t <= u1 + silence { hit = true; lat = t - u0 } else { falseN = 1 }
                        }
                        if c.short {
                            cnt.shortCases += 1
                            if hit { cnt.shortStops += 1 }
                        } else {
                            cnt.userCases += 1
                            if hit { cnt.hits += 1; cnt.latencies.append(lat!) }
                        }
                        cnt.falseStops += falseN
                    } else {
                        cnt.echoOnlyCases += 1
                        falseN = fires.isEmpty ? 0 : 1
                        cnt.echoOnlyFalse += falseN
                    }
                    table[key] = cnt
                    rows.append(["case": c.name, "variant": vn, "barge_in_ms": B, "echo": c.echo, "level": c.level ?? 0,
                                 "short": c.short, "regions": regs.map { [$0.0, $0.1] }, "fires": fires, "hit": hit,
                                 "false": falseN, "latency_ms": lat ?? -1, "verdicts": verdicts])
                }
            }
        }
        // 判定だけの誤り: エコーだけの録音で「VAD が毎回話し始めたと言った」とみなし、100ms ごとの窓をすべて判定する。
        print("gate-only (エコーだけの録音の 100ms ごとの窓のうち、人の声と判定した数)")
        for c in cases where c.user == nil {
            for B in spec.bargeInMs {
                for (vn, g) in variants {
                    guard let g else { continue }
                    var pass = 0, total = 0
                    var t = B
                    let sr = PCM.sampleRate / 1000
                    while t * sr <= c.mic.count {
                        let ws = t - B
                        let from = max(0, ws - g.historyMs - g.maxLagMs)
                        let m = Array(c.mic[(from * sr)..<(t * sr)])
                        let r = Array(refRaw[(from * sr)..<min(refRaw.count, t * sr)]) + [Int16](repeating: 0, count: max(0, t * sr - refRaw.count))
                        if EchoGate.evaluate(mic: m, ref: r, judgeFrom: (ws - from) * sr, config: g).isVoice { pass += 1 }
                        total += 1
                        t += 100
                    }
                    print("  \(vn) | \(B) | \(c.echo) | \(pass)/\(total)")
                    rows.append(["case": c.name, "variant": vn, "barge_in_ms": B, "gate_only_pass": pass, "gate_only_total": total])
                }
            }
        }
        let rowsData = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
        try rowsData.write(to: work.appendingPathComponent("eval-rows.json"))
        print("variant | bargeInMs | echo | 人の声で止まった | 人の声の中央の遅れ ms | 誤って止まった (人の発話ありの外) | 誤って止まった (エコーだけ) | 相づちで止まった")
        var summary: [[String: Any]] = []
        for key in table.keys.sorted() {
            let c = table[key]!
            let parts = key.split(separator: "|")
            let lat = c.latencies.sorted()
            let med = lat.isEmpty ? -1 : lat[lat.count / 2]
            print("\(parts[0]) | \(parts[1]) | \(parts[2]) | \(c.hits)/\(c.userCases) | \(med) | \(c.falseStops) | \(c.echoOnlyFalse)/\(c.echoOnlyCases) | \(c.shortStops)/\(c.shortCases)")
            summary.append(["variant": String(parts[0]), "barge_in_ms": Int(parts[1])!, "echo": String(parts[2]),
                            "hits": c.hits, "user_cases": c.userCases, "median_latency_ms": med,
                            "false_stops_user_cases": c.falseStops, "false_stops_echo_only": c.echoOnlyFalse,
                            "echo_only_cases": c.echoOnlyCases, "short_stops": c.shortStops, "short_cases": c.shortCases])
        }
        let sData = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
        try sData.write(to: work.appendingPathComponent("eval-summary.json"))
    }
}
