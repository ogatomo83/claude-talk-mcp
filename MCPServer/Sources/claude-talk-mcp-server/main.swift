//
//  main.swift
//  claude-talk-mcp-server
//
//  Claude と stdio(MCP) で接続し、speak/listen ツールを提供する。経路は ~/.claude-talk-mcp/mode で選ぶ
//  (呼び出しのたびに読むので、書き換えればすぐ効く):
//    app    (既定) … 今まで通り、常駐音声アプリへ Unix ソケットで転送する
//    direct        … MCP サーバー自身が録音・読み上げし、speech.cpp の Realtime (Haas + Silero VAD) に流す
//  どちらの経路も 1 往復の各段の時刻を ~/.claude-talk-mcp/logs/timing.jsonl に残す。
//

import ClaudeTalkCore
import Foundation
import MCP

let client = SpeechSocketClient()
let timing = TimingLog.shared

let server = Server(
    name: "claude-talk-mcp",
    version: "1.1.0",
    capabilities: .init(tools: .init(listChanged: false))
)

// MARK: - ツール定義

let speakTool = Tool(
    name: "speak",
    description: "与えられたテキストを読み上げる (direct モードは既定で Irodori-TTS、app モードは macOS の音声)。音が鳴り終わるまで待機する。",
    inputSchema: .object([
        "type": .string("object"),
        "properties": .object([
            "text": .object([
                "type": .string("string"),
                "description": .string("読み上げるテキスト"),
            ]),
            "voice": .object([
                "type": .string("string"),
                "description": .string("macOS の音声識別子 (com.apple.…)。指定するとその回は macOS の音声で読む。未指定は設定の既定"),
            ]),
            "rate": .object([
                "type": .string("number"),
                "description": .string("読み上げ速度（0.0〜1.0 程度）"),
            ]),
            "locale": .object([
                "type": .string("string"),
                "description": .string("読み上げロケール（既定 ja-JP）"),
            ]),
        ]),
        "required": .array([.string("text")]),
    ])
)

let listenTool = Tool(
    name: "listen",
    description: "マイクからユーザーの発話を認識してテキストで返す。話し終わり（無音）またはタイムアウトで確定する。",
    inputSchema: .object([
        "type": .string("object"),
        "properties": .object([
            "timeout": .object([
                "type": .string("number"),
                "description": .string("最大待機秒数（既定 30）"),
            ]),
            "locale": .object([
                "type": .string("string"),
                "description": .string("認識ロケール（既定 ja-JP）"),
            ]),
        ]),
    ])
)

/// 数値の引数。JSON の 30 は .int、30.5 は .double で届くので両方を受ける
/// (以前は doubleValue だけを見ていて、整数の timeout / rate が無視されていた)。
func number(_ v: Value?) -> Double? {
    if let d = v?.doubleValue { return d }
    if let i = v?.intValue { return Double(i) }
    return nil
}

// MARK: - app モード (今まで通り: 音声アプリへ転送)

func appSpeak(_ args: [String: Value]?, text: String) throws -> CallTool.Result {
    var request: [String: Any] = ["type": "speak", "text": text]
    if let voice = args?["voice"]?.stringValue {
        request["voice"] = voice
    }
    if let rate = number(args?["rate"]) {
        request["rate"] = rate
    }
    if let locale = args?["locale"]?.stringValue {
        request["locale"] = locale
    }
    let response = try client.send(request)
    if response["ok"] as? Bool == true {
        return .init(content: [.text("done")], isError: false)
    } else {
        let message = response["error"] as? String ?? "不明なエラー"
        return .init(content: [.text(message)], isError: true)
    }
}

func appListen(_ args: [String: Value]?) throws -> CallTool.Result {
    var request: [String: Any] = ["type": "listen"]
    if let timeout = number(args?["timeout"]) {
        request["timeout"] = timeout
    }
    let locale = args?["locale"]?.stringValue ?? "ja-JP"
    request["locale"] = locale

    let response = try client.send(request)
    if response["ok"] as? Bool == true {
        let text = response["text"] as? String ?? ""
        return .init(content: [.text(text)], isError: false)
    } else {
        let message = response["error"] as? String ?? "不明なエラー"
        return .init(content: [.text(message)], isError: true)
    }
}

// MARK: - ハンドラ登録

await server.withMethodHandler(ListTools.self) { _ in
    ListTools.Result(tools: [speakTool, listenTool])
}

await server.withMethodHandler(CallTool.self) { params in
    let mode = TalkMode.current()
    let args = params.arguments
    switch params.name {
    case "speak":
        guard let text = args?["text"]?.stringValue, !text.isEmpty else {
            return .init(content: [.text("text が指定されていません")], isError: true)
        }
        switch mode {
        case .app:
            let sw = Stopwatch()
            timing.event("speak.recv", mode: .app, fields: ["chars": text.count])
            do {
                let result = try appSpeak(args, text: text)
                timing.event("speak.done", mode: .app, fields: ["ms": sw.ms, "ok": !(result.isError ?? false)])
                return result
            } catch {
                timing.event("speak.done", mode: .app, fields: ["ms": sw.ms, "ok": false,
                                                                "error": error.localizedDescription])
                return .init(content: [.text(error.localizedDescription)], isError: true)
            }
        case .direct:
            do {
                let finished = try await DirectEngine.shared.speak(
                    text: text,
                    voice: args?["voice"]?.stringValue,
                    rate: number(args?["rate"]),
                    locale: args?["locale"]?.stringValue ?? "ja-JP")
                return .init(content: [.text(finished ? "done" : "stopped")], isError: false)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return .init(content: [.text(error.localizedDescription)], isError: true)
            }
        }

    case "listen":
        switch mode {
        case .app:
            _ = timing.nextTurn()
            let sw = Stopwatch()
            timing.event("listen.recv", mode: .app, fields: ["timeout": number(args?["timeout"]) ?? 30])
            do {
                let result = try appListen(args)
                var f: [String: Any] = ["ms": sw.ms, "ok": !(result.isError ?? false)]
                if case .text(let t, _, _)? = result.content.first { f["chars"] = t.count }
                timing.event("listen.return", mode: .app, fields: f)
                return result
            } catch {
                timing.event("listen.return", mode: .app, fields: ["ms": sw.ms, "ok": false,
                                                                   "error": error.localizedDescription])
                return .init(content: [.text(error.localizedDescription)], isError: true)
            }
        case .direct:
            do {
                let text = try await DirectEngine.shared.listen(
                    timeout: number(args?["timeout"]) ?? 30,
                    locale: args?["locale"]?.stringValue ?? "ja-JP")
                return .init(content: [.text(text)], isError: false)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return .init(content: [.text(error.localizedDescription)], isError: true)
            }
        }

    default:
        return .init(content: [.text("不明なツール: \(params.name)")], isError: true)
    }
}

// MARK: - 起動

timing.event("server.start", mode: TalkMode.current(), fields: ["version": "1.1.0"])
if TalkMode.current() == .direct {
    // 初回 listen の待ちを減らすため、speech serve を先に起こしておく。
    Task { await DirectEngine.shared.prewarm() }
}

try await server.start(transport: StdioTransport())
await server.waitUntilCompleted()
