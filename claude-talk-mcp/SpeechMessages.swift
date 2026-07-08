//
//  SpeechMessages.swift
//  claude-talk-mcp
//
//  MCP サーバーとやりとりする NDJSON メッセージと共有パス定義。
//

import Foundation

/// 両プロセスが同じ場所を算出するためのソケットパス。
enum SpeechSocket {
    /// `~/.claude-talk-mcp/`
    static var directoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude-talk-mcp", isDirectory: true)
    }

    /// `~/.claude-talk-mcp/speech.sock`
    static var path: String {
        directoryURL.appendingPathComponent("speech.sock").path
    }
}

/// MCP サーバーから届くリクエスト。
struct SpeechRequest {
    enum Kind: String {
        case speak
        case listen
    }

    let type: Kind
    let text: String?
    let voice: String?
    let rate: Double?
    let timeout: Double?
    let locale: String?

    /// NDJSON の 1 行（JSON オブジェクト）をパースする。
    static func parse(line: Data) -> SpeechRequest? {
        guard
            let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            let typeString = object["type"] as? String,
            let kind = Kind(rawValue: typeString)
        else {
            return nil
        }

        func number(_ key: String) -> Double? {
            (object[key] as? NSNumber)?.doubleValue
        }

        return SpeechRequest(
            type: kind,
            text: object["text"] as? String,
            voice: object["voice"] as? String,
            rate: number("rate"),
            timeout: number("timeout"),
            locale: object["locale"] as? String
        )
    }
}

/// アプリから返すレスポンス。
struct SpeechResponse {
    let ok: Bool
    let text: String?
    let error: String?

    static func success(text: String? = nil) -> SpeechResponse {
        SpeechResponse(ok: true, text: text, error: nil)
    }

    static func failure(_ message: String) -> SpeechResponse {
        SpeechResponse(ok: false, text: nil, error: message)
    }

    /// 改行付きの 1 行 JSON にエンコードする。
    func jsonLine() -> Data {
        var object: [String: Any] = ["ok": ok]
        if let text { object["text"] = text }
        if let error { object["error"] = error }
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{\"ok\":false}".utf8)
        return data + Data("\n".utf8)
    }
}
