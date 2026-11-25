import XCTest
@testable import ClaudeTalkCore

final class SentenceSplitterTests: XCTestCase {
    func testSplitsOnEndersAcrossDeltas() {
        var s = SentenceSplitter()
        XCTAssertEqual(s.feed("こんにちは"), [])
        // 「。」がバッファの最後の時は、閉じ括弧が続くかもしれないので次の delta まで待つ。
        XCTAssertEqual(s.feed("。"), [])
        XCTAssertEqual(s.feed("今日は"), ["こんにちは。"])
        XCTAssertEqual(s.feed("晴れです！明日は？"), ["今日は晴れです！"])
        XCTAssertEqual(s.flush(), ["明日は？"])
        XCTAssertEqual(s.flush(), [])
    }

    func testKeepsClosingBracketWithSentence() {
        var s = SentenceSplitter()
        XCTAssertEqual(s.feed("彼は「行くぞ。」と言った。次"), ["彼は「行くぞ。」", "と言った。"])
    }

    func testNewlineCutsImmediately() {
        var s = SentenceSplitter()
        XCTAssertEqual(s.feed("見出し\n"), ["見出し"])
    }

    func testCleansMarkdown() {
        XCTAssertEqual(SentenceSplitter.clean("- **Docker** を使います。"), "Docker を使います。")
        XCTAssertEqual(SentenceSplitter.clean("1. `swift build` を実行"), "swift build を実行")
        XCTAssertEqual(SentenceSplitter.clean("[公式](https://example.com)を見て"), "公式を見て")
        XCTAssertEqual(SentenceSplitter.clean("。"), "")
        XCTAssertEqual(SentenceSplitter.clean("  \n"), "")
    }

    func testFirstChunkMinChars() {
        var s = SentenceSplitter(firstChunkMinChars: 5)
        // 「ええと、」は 4 文字で短いので区切らず、5 文字を超えた次の読点で区切る
        XCTAssertEqual(s.feed("ええと、それはですね、"), ["ええと、それはですね、"])
        // 2 文目からは読点では区切らない
        XCTAssertEqual(s.feed("長い説明になりますが、"), [])
        XCTAssertEqual(s.flush(), ["長い説明になりますが、"])
    }

    func testFirstChunkOffByDefault() {
        var s = SentenceSplitter()
        XCTAssertEqual(s.feed("ええと、それはですね、"), [])
    }
}

final class ClaudeEventTests: XCTestCase {
    func testParsesInitAndLifecycle() {
        XCTAssertEqual(ClaudeEvent.parse(#"{"type":"system","subtype":"init","session_id":"s1","model":"claude-opus-5-5","tools":["Read"]}"#),
                       .initialized(sessionId: "s1", model: "claude-opus-5-5", tools: ["Read"]))
        XCTAssertEqual(ClaudeEvent.parse(#"{"type":"command_lifecycle","command_uuid":"u1","state":"started"}"#),
                       .commandStarted(uuid: "u1"))
        XCTAssertEqual(ClaudeEvent.parse(#"{"type":"command_lifecycle","command_uuid":"u1","state":"cancelled"}"#),
                       .commandEnded(uuid: "u1", state: "cancelled"))
        XCTAssertEqual(ClaudeEvent.parse(#"{"type":"system","subtype":"hook_started"}"#), .other("system.hook_started"))
    }

    func testParsesStreamEvents() {
        XCTAssertEqual(ClaudeEvent.parse(#"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"一、"}}}"#),
                       .textDelta("一、"))
        XCTAssertEqual(ClaudeEvent.parse(#"{"type":"stream_event","event":{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","name":"Read","id":"t"}}}"#),
                       .toolUseStart(name: "Read"))
        XCTAssertEqual(ClaudeEvent.parse(#"{"type":"stream_event","event":{"type":"message_start"}}"#), .messageStart)
        XCTAssertEqual(ClaudeEvent.parse(#"{"type":"assistant","message":{"content":[{"type":"thinking","thinking":""},{"type":"text","text":"はい。"},{"type":"tool_use","name":"Grep"}]}}"#),
                       .assistant(text: "はい。", toolUses: ["Grep"]))
    }

    func testParsesResultAndControl() {
        XCTAssertEqual(ClaudeEvent.parse(#"{"type":"result","subtype":"success","is_error":false,"duration_ms":3000,"duration_api_ms":2400,"result":"ok","session_id":"s"}"#),
                       .result(subtype: "success", isError: false, durationMs: 3000, apiMs: 2400, text: "ok", sessionId: "s"))
        let cut = ClaudeEvent.parse(#"{"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"rm -rf x"}}}"#)
        XCTAssertEqual(cut, .canUseTool(requestId: "r1", toolName: "Bash", input: #"{"command":"rm -rf x"}"#))
        XCTAssertEqual(ClaudeEvent.parse(#"{"type":"control_response","response":{"subtype":"success","request_id":"int-1","response":{"still_queued":[]}}}"#),
                       .controlResponse(requestId: "int-1", subtype: "success", error: nil))
        XCTAssertEqual(ClaudeEvent.parse("not json"), .other("unparsable"))
    }

    func testOutgoingShapes() throws {
        let u = ClaudeEvent.userMessage(text: "こんにちは", uuid: "u1")
        XCTAssertEqual(u["type"] as? String, "user")
        XCTAssertEqual(u["uuid"] as? String, "u1")
        let msg = u["message"] as? [String: Any]
        XCTAssertEqual((msg?["content"] as? [[String: Any]])?.first?["text"] as? String, "こんにちは")

        let i = ClaudeEvent.interruptRequest(id: "int-1")
        XCTAssertEqual((i["request"] as? [String: Any])?["subtype"] as? String, "interrupt")

        let deny = ClaudeEvent.permissionResponse(requestId: "r1", allow: false, input: "{}", message: "だめ")
        let inner = ((deny["response"] as? [String: Any])?["response"] as? [String: Any])
        XCTAssertEqual(inner?["behavior"] as? String, "deny")
        XCTAssertEqual(inner?["message"] as? String, "だめ")
        let allow = ClaudeEvent.permissionResponse(requestId: "r2", allow: true, input: #"{"file_path":"/a"}"#, message: "")
        let ai = ((allow["response"] as? [String: Any])?["response"] as? [String: Any])
        XCTAssertEqual(ai?["behavior"] as? String, "allow")
        XCTAssertEqual((ai?["updatedInput"] as? [String: Any])?["file_path"] as? String, "/a")
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: allow))
    }
}

final class VoiceSettingsTests: XCTestCase {
    func testDefaultsAreReadOnlyAndNoMCP() {
        let v = VoiceSettings()
        let a = v.claudeArguments(sessionId: "sid", resume: nil)
        XCTAssertTrue(a.contains("--strict-mcp-config"))
        XCTAssertEqual(a[a.firstIndex(of: "--tools")! + 1], "Read,Glob,Grep")
        XCTAssertEqual(a[a.firstIndex(of: "--permission-prompt-tool")! + 1], "stdio")
        XCTAssertEqual(a[a.firstIndex(of: "--session-id")! + 1], "sid")
        XCTAssertFalse(a.contains("--dangerously-skip-permissions"))
        XCTAssertFalse(a.contains("--model"))
        XCTAssertTrue(v.permits(tool: "Read"))
        XCTAssertFalse(v.permits(tool: "Bash"))
        XCTAssertFalse(v.permits(tool: "Write"))
        XCTAssertFalse(v.permits(tool: "mcp__taskcard__state"))
    }

    func testResumeReplacesSessionId() {
        let a = VoiceSettings().claudeArguments(sessionId: "sid", resume: "old")
        XCTAssertEqual(a[a.firstIndex(of: "--resume")! + 1], "old")
        XCTAssertFalse(a.contains("--session-id"))
    }

    func testPartialJSON() throws {
        let v = try JSONDecoder().decode(VoiceSettings.self, from: Data(#"{"model":"sonnet","bargeInMs":500}"#.utf8))
        XCTAssertEqual(v.model, "sonnet")
        XCTAssertEqual(v.bargeInMs, 500)
        XCTAssertEqual(v.tools, "Read,Glob,Grep")
        XCTAssertTrue(v.strictMcp)
        let a = v.claudeArguments(sessionId: nil, resume: nil)
        XCTAssertEqual(a[a.firstIndex(of: "--model")! + 1], "sonnet")
    }

    func testSystemPromptHasNoTurnCue() {
        // 合図 (どうぞ等) を付けない指示が入っていること (EPM 指示)。
        XCTAssertTrue(VoiceSettings.defaultSystemPrompt.contains("合図"))
    }
}

final class TimingLogEncodeTests: XCTestCase {
    func testKeepsElapsedMsAndAddsEpoch() {
        let d = Date(timeIntervalSince1970: 1_795_556_687.833)
        let obj = TimingLog.shared.encode("speak.audio_start", modeName: "direct", fields: ["ms": 227], at: d)
        XCTAssertEqual(obj["ms"] as? Int, 227)
        XCTAssertEqual(obj["at_ms"] as? Int64, 1_795_556_687_833)
        XCTAssertEqual(obj["mode"] as? String, "direct")
        let noMs = TimingLog.shared.encode("listen.recv", modeName: "direct", fields: [:], at: d)
        XCTAssertNil(noMs["ms"])
    }
}

final class ScriptedWavInputTests: XCTestCase {
    func testParseRejectsMissingTrigger() {
        XCTAssertThrowsError(try ScriptedWavInput.parse("/tmp/a.wav"))
    }

    func testPlaysClipsInOrderOnTriggers() throws {
        let clip = Data(repeating: 0x10, count: PCM.bytesPerSecond / 10)  // 0.1 秒
        let a = ScriptedWavInput.Clip(name: "a", data: clip, trigger: "ready", delayMs: 0)
        let b = ScriptedWavInput.Clip(name: "b", data: clip, trigger: "tts_audio", delayMs: 0)
        let input = ScriptedWavInput(clips: [a, b])
        TimingLog.shared.enabled = false
        defer { TimingLog.shared.enabled = true }
        let ring = AudioRing()
        try input.start(into: ring)
        defer { input.stop() }
        input.trigger("tts_audio")  // 順番が違うので無視
        XCTAssertFalse(input.allPlayed)
        input.trigger("ready")
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertFalse(input.allPlayed)
        input.trigger("tts_audio")
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertTrue(input.allPlayed)
        XCTAssertNotNil(input.lastSpeechEnd)
    }
}
