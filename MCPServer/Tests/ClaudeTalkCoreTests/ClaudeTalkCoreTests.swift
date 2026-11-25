import XCTest
@testable import ClaudeTalkCore

final class ModeTests: XCTestCase {
    func testDefaultIsApp() {
        let missing = URL(fileURLWithPath: "/nonexistent/claude-talk-mode")
        XCTAssertEqual(TalkMode.current(environment: [:], modeFile: missing), .app)
    }

    func testFileAndEnv() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("mode")
        try " Direct\n".write(to: f, atomically: true, encoding: .utf8)
        XCTAssertEqual(TalkMode.current(environment: [:], modeFile: f), .direct)
        XCTAssertEqual(TalkMode.current(environment: ["CLAUDE_TALK_MODE": "app"], modeFile: f), .app)
        try "nonsense".write(to: f, atomically: true, encoding: .utf8)
        XCTAssertEqual(TalkMode.current(environment: [:], modeFile: f), .app, "unknown value falls back to app")
    }
}

final class SettingsTests: XCTestCase {
    func testPartialJSONKeepsDefaults() throws {
        let s = try JSONDecoder().decode(DirectSettings.self, from: Data(#"{"silenceMs": 300, "port": 9000}"#.utf8))
        XCTAssertEqual(s.silenceMs, 300)
        XCTAssertEqual(s.port, 9000)
        XCTAssertEqual(s.asrModel, "haas-ja-v1.0:f16")
        XCTAssertEqual(s.micIdleCloseSeconds, 60)
        XCTAssertEqual(s.realtimeURL.absoluteString, "ws://127.0.0.1:9000/v1/realtime")
    }

    func testServeArgumentsBindLoopbackOnly() {
        let args = SpeechServer(settings: DirectSettings()).arguments
        let i = args.firstIndex(of: "--host")!
        XCTAssertEqual(args[i + 1], "127.0.0.1")
        XCTAssertTrue(args.contains("silero-vad"))
        XCTAssertFalse(args.contains("0.0.0.0"))
    }
}

final class VocabularyTests: XCTestCase {
    func testMerge() {
        let merged = Vocabulary.merge(builtIn: ["Docker=ドッカー", "Python=パイソン"], fileText: """
        # comment
        Docker=ドッカー,どうか   # override
        Swift=スウィフト

        -Python
        """)
        XCTAssertEqual(merged, ["Docker=ドッカー,どうか", "Swift=スウィフト"])
    }

    func testBuiltInHasRequestedWords() {
        let keys = Vocabulary.builtIn.map { $0.split(separator: "=").first.map(String.init) ?? "" }
        for w in ["Docker", "TypeScript", "Kubernetes", "Python", "Qwen", "Haas", "Claude"] {
            XCTAssertTrue(keys.contains(w), w)
        }
    }
}

final class RealtimeTests: XCTestCase {
    func testParse() {
        XCTAssertEqual(RealtimeEvent.parse(#"{"type":"input_audio_buffer.speech_started","item_id":"a","audio_start_ms":500}"#),
                       .speechStarted(item: "a", audioStartMs: 500))
        XCTAssertEqual(RealtimeEvent.parse(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"a","transcript":"こんにちは"}"#),
                       .completed(item: "a", transcript: "こんにちは"))
        XCTAssertEqual(RealtimeEvent.parse(#"{"type":"error","error":{"code":"x","message":"bad"}}"#), .error("x: bad"))
    }

    func testTrackerFinishesAfterAllItemsCompleted() {
        var t = TurnTracker()
        XCTAssertEqual(t.handle(.speechStarted(item: "a", audioStartMs: 0)), .wait)
        XCTAssertEqual(t.handle(.speechStopped(item: "a", audioEndMs: 1000)), .wait)
        XCTAssertEqual(t.handle(.speechStarted(item: "b", audioStartMs: 1200)), .wait)
        XCTAssertEqual(t.handle(.completed(item: "a", transcript: "前半。")), .wait, "b is still being spoken")
        XCTAssertEqual(t.handle(.speechStopped(item: "b", audioEndMs: 2000)), .wait)
        XCTAssertEqual(t.handle(.completed(item: "b", transcript: "後半。")), .finish("前半。後半。"))
    }

    func testTrackerDiscardsEmpty() {
        var t = TurnTracker()
        _ = t.handle(.speechStarted(item: "a", audioStartMs: 0))
        _ = t.handle(.speechStopped(item: "a", audioEndMs: 300))
        XCTAssertEqual(t.handle(.completed(item: "a", transcript: " ")), .wait)
        XCTAssertFalse(t.heardSpeech)
        XCTAssertEqual(t.discardedEmpty, 1)
    }

    func testSessionUpdateShape() throws {
        var s = DirectSettings()
        s.silenceMs = 450
        let obj = RealtimeSession.sessionUpdate(settings: s, language: "ja", keywords: ["Docker=ドッカー"])
        let data = try JSONSerialization.data(withJSONObject: obj)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"silence_duration_ms\":450"))
        XCTAssertTrue(text.contains("server_vad"))
        XCTAssertTrue(text.contains("Docker"))
        XCTAssertTrue(text.contains("24000"))
    }
}

final class AudioTests: XCTestCase {
    func testRingPrerollSlicesFromTime() async {
        let ring = AudioRing(retainSeconds: 10)
        let base: UInt64 = 10_000_000_000
        // 0.1 s ずつ 5 個 (値で区別)
        for i in 0..<5 {
            var d = Data(count: PCM.bytesPerSecond / 10)
            d.withUnsafeMutableBytes { $0.bindMemory(to: Int16.self).initialize(repeating: Int16(i + 1)) }
            ring.append(AudioPiece(start: base + UInt64(i) * 100_000_000, data: d))
        }
        let sub = ring.subscribe(since: base + 250_000_000)
        let bytes = sub.backlog.reduce(0) { $0 + $1.data.count }
        XCTAssertEqual(bytes, PCM.bytesPerSecond * 25 / 100)
        XCTAssertEqual(sub.backlog.first?.start, base + 250_000_000)
        ring.unsubscribe(sub.id)
        XCTAssertEqual(ring.stats.peak, 5)
    }

    func testPeak() {
        var d = Data(count: 8)
        d.withUnsafeMutableBytes { $0.bindMemory(to: Int16.self).initialize(from: [0, -300, 12, 7]) }
        XCTAssertEqual(PCM.peakAbs(d), 300)
    }

    func testIsoLanguage() {
        XCTAssertEqual(DirectEngine.isoLanguage("ja-JP", fallback: "ja"), "ja")
        XCTAssertEqual(DirectEngine.isoLanguage("", fallback: "ja"), "ja")
    }
}

final class TimingLogTests: XCTestCase {
    func testWritesJSONLines() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        setenv("CLAUDE_TALK_HOME", dir.path, 1)
        defer { unsetenv("CLAUDE_TALK_HOME") }
        let log = TimingLog()
        log.enabled = true
        _ = log.nextTurn()
        log.event("listen.recv", mode: .app, fields: ["timeout": 30])
        log.event("listen.return", mode: .app, fields: ["ms": 1234])
        let text = try String(contentsOf: dir.appendingPathComponent("logs/timing.jsonl"), encoding: .utf8)
        let lines = text.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        let obj = try JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as! [String: Any]
        XCTAssertEqual(obj["ev"] as? String, "listen.return")
        XCTAssertEqual(obj["turn"] as? Int, 1)
        XCTAssertEqual(obj["mode"] as? String, "app")
    }
}

final class EchoFilterTests: XCTestCase {
    let spoken = "今日はここまでにしておくぞ。"

    func testTailOfSpeechIsEcho() {
        XCTAssertTrue(EchoFilter.judge(transcript: "ぞ。", spoken: spoken, threshold: 0.75).isEcho)
        XCTAssertTrue(EchoFilter.judge(transcript: "しておくぞ", spoken: spoken, threshold: 0.75).isEcho)
        // 実測: 残り音が「ぞう」「ておくぞー」と書き起こされた
        XCTAssertTrue(EchoFilter.judge(transcript: "ぞう", spoken: spoken, threshold: 0.75).isEcho)
        XCTAssertTrue(EchoFilter.judge(transcript: "ておくぞー", spoken: spoken, threshold: 0.75).isEcho)
        XCTAssertTrue(EchoFilter.judge(transcript: "行くぞ", spoken: spoken, threshold: 0.75).isEcho)
        XCTAssertTrue(EchoFilter.judge(transcript: "きれいにしておくぞ", spoken: spoken, threshold: 0.75).isEcho)
        // 書き起こしの揺れ (カタカナ・記号・1 文字違い)
        XCTAssertTrue(EchoFilter.judge(transcript: "ここまでにしとくぞ!", spoken: spoken, threshold: 0.75).isEcho)
        XCTAssertTrue(EchoFilter.judge(transcript: "Dockerを使います", spoken: "では、ドッカーをつかいます。dockerを使います。",
                                       threshold: 0.75).isEcho)
    }

    func testUserReplyIsNotEcho() {
        XCTAssertFalse(EchoFilter.judge(transcript: "はい、お願いします", spoken: spoken, threshold: 0.75).isEcho)
        XCTAssertFalse(EchoFilter.judge(transcript: "うん", spoken: spoken, threshold: 0.75).isEcho)
        XCTAssertFalse(EchoFilter.judge(transcript: "そう", spoken: spoken, threshold: 0.75).isEcho)
        XCTAssertFalse(EchoFilter.judge(transcript: "え", spoken: spoken, threshold: 0.75).isEcho)
        // 長い返事の一部に同じ語があっても捨てない
        XCTAssertFalse(EchoFilter.judge(transcript: "ここまでにするなら明日は何から始める?", spoken: spoken,
                                        threshold: 0.75).isEcho)
        // 0 で無効
        XCTAssertFalse(EchoFilter.judge(transcript: "ぞ", spoken: spoken, threshold: 0).isEcho)
    }

    func testRomaji() {
        XCTAssertEqual(String(EchoFilter.romaji("しておくぞ。")), "shiteokuzo")
        XCTAssertEqual(String(EchoFilter.romaji("Docker を")), "dockerwo")
    }

    func testNormalize() {
        XCTAssertEqual(String(EchoFilter.normalize("ドッカー、Ｄｏｃｋｅｒ！ 1")), "どっかーdocker1")
    }
}

final class TailGuardTests: XCTestCase {
    func testSettingsDefaultsAndOverride() throws {
        let d = DirectSettings()
        XCTAssertEqual(d.speakTailGuardMs, 150)
        XCTAssertEqual(d.echoWindowMs, 2000)
        XCTAssertEqual(d.echoSimilarity, 0.75)
        let s = try JSONDecoder().decode(DirectSettings.self,
                                         from: Data(#"{"speakTailGuardMs": 300, "echoSimilarity": 0}"#.utf8))
        XCTAssertEqual(s.speakTailGuardMs, 300)
        XCTAssertEqual(s.echoSimilarity, 0)
        XCTAssertEqual(s.echoWindowMs, 2000)
    }

    func testPieceSlicedFromFutureStart() {
        let d = Data(count: PCM.bytesPerSecond / 10) // 0.1 s
        let p = AudioPiece(start: 1_000_000_000, data: d)
        XCTAssertNil(p.sliced(from: 1_100_000_000))
        XCTAssertEqual(p.sliced(from: 0)?.data.count, d.count)
        let half = p.sliced(from: 1_050_000_000)
        XCTAssertEqual(half?.start, 1_050_000_000)
        XCTAssertEqual(half?.data.count, d.count / 2)
    }
}
