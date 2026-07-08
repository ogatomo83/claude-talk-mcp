//
//  main.swift
//  claude-talk-mcp-server
//
//  Claude と stdio(MCP) で接続し、speak/listen ツールを常駐音声アプリへ転送する。
//

import Foundation
import MCP

let client = SpeechSocketClient()

let server = Server(
    name: "claude-talk-mcp",
    version: "1.0.0",
    capabilities: .init(tools: .init(listChanged: false))
)

// MARK: - ツール定義

let speakTool = Tool(
    name: "speak",
    description: "与えられたテキストを macOS の音声で読み上げる。読み上げ完了まで待機する。",
    inputSchema: .object([
        "type": .string("object"),
        "properties": .object([
            "text": .object([
                "type": .string("string"),
                "description": .string("読み上げるテキスト"),
            ]),
            "voice": .object([
                "type": .string("string"),
                "description": .string("音声識別子（未指定はシステム既定）"),
            ]),
            "rate": .object([
                "type": .string("number"),
                "description": .string("読み上げ速度（0.0〜1.0 程度）"),
            ]),
        ]),
        "required": .array([.string("text")]),
    ])
)

let listenTool = Tool(
    name: "listen",
    description: "マイクからユーザーの発話を認識してテキストで返す。無音またはタイムアウトで確定する。",
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

// MARK: - ハンドラ登録

await server.withMethodHandler(ListTools.self) { _ in
    ListTools.Result(tools: [speakTool, listenTool])
}

await server.withMethodHandler(CallTool.self) { params in
    do {
        switch params.name {
        case "speak":
            guard let text = params.arguments?["text"]?.stringValue, !text.isEmpty else {
                return .init(content: [.text("text が指定されていません")], isError: true)
            }
            var request: [String: Any] = ["type": "speak", "text": text]
            if let voice = params.arguments?["voice"]?.stringValue {
                request["voice"] = voice
            }
            if let rate = params.arguments?["rate"]?.doubleValue {
                request["rate"] = rate
            }
            let response = try client.send(request)
            if response["ok"] as? Bool == true {
                return .init(content: [.text("done")], isError: false)
            } else {
                let message = response["error"] as? String ?? "不明なエラー"
                return .init(content: [.text(message)], isError: true)
            }

        case "listen":
            var request: [String: Any] = ["type": "listen"]
            if let timeout = params.arguments?["timeout"]?.doubleValue {
                request["timeout"] = timeout
            }
            let locale = params.arguments?["locale"]?.stringValue ?? "ja-JP"
            request["locale"] = locale

            let response = try client.send(request)
            if response["ok"] as? Bool == true {
                let text = response["text"] as? String ?? ""
                return .init(content: [.text(text)], isError: false)
            } else {
                let message = response["error"] as? String ?? "不明なエラー"
                return .init(content: [.text(message)], isError: true)
            }

        default:
            return .init(content: [.text("不明なツール: \(params.name)")], isError: true)
        }
    } catch {
        return .init(content: [.text(error.localizedDescription)], isError: true)
    }
}

// MARK: - 起動

try await server.start(transport: StdioTransport())
await server.waitUntilCompleted()
