//
//  Realtime.swift
//  ClaudeTalkCore
//
//  speech.cpp の /v1/realtime (OpenAI Realtime の文字起こしセッション) のクライアントと、
//  届いたイベントから「話し終わった」を決める TurnTracker。
//

import Foundation

public enum RealtimeEvent: Equatable, Sendable {
    case sessionCreated
    case sessionUpdated
    case speechStarted(item: String, audioStartMs: Int)
    case speechStopped(item: String, audioEndMs: Int)
    case committed(item: String)
    case delta(item: String, text: String)
    case completed(item: String, transcript: String)
    case failed(item: String, message: String)
    case error(String)
    case other(String)

    public static func parse(_ text: String) -> RealtimeEvent {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return .other("unparsable") }
        let item = obj["item_id"] as? String ?? ""
        func errorMessage(_ any: Any?) -> String {
            guard let e = any as? [String: Any] else { return "\(any ?? "")" }
            let code = e["code"] as? String
            let msg = e["message"] as? String ?? ""
            return [code, msg].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ": ")
        }
        switch type {
        case "session.created": return .sessionCreated
        case "session.updated": return .sessionUpdated
        case "input_audio_buffer.speech_started":
            return .speechStarted(item: item, audioStartMs: (obj["audio_start_ms"] as? NSNumber)?.intValue ?? -1)
        case "input_audio_buffer.speech_stopped":
            return .speechStopped(item: item, audioEndMs: (obj["audio_end_ms"] as? NSNumber)?.intValue ?? -1)
        case "input_audio_buffer.committed": return .committed(item: item)
        case "conversation.item.input_audio_transcription.delta":
            return .delta(item: item, text: obj["delta"] as? String ?? "")
        case "conversation.item.input_audio_transcription.completed":
            return .completed(item: item, transcript: obj["transcript"] as? String ?? "")
        case "conversation.item.input_audio_transcription.failed":
            return .failed(item: item, message: errorMessage(obj["error"]))
        case "error": return .error(errorMessage(obj["error"]))
        default: return .other(type)
        }
    }
}

/// 発話 (item) ごとの完了を待ち、話している途中でなく、始まった発話が全部書き起こされたら確定する。
/// 書き起こしが空 (咳・物音) なら捨てて聞き続ける。
public struct TurnTracker: Sendable {
    public enum Decision: Equatable, Sendable { case wait, finish(String) }

    private var order: [String] = []
    private var done: [String: String] = [:]
    public private(set) var speaking = false
    public private(set) var discardedEmpty = 0
    public private(set) var failures: [String] = []

    public init() {}

    /// 話し始めを 1 度でも聞いたか (空で捨てた分は数えない)。
    public var heardSpeech: Bool { !order.isEmpty }

    public var partialText: String { order.compactMap { done[$0] }.joined() }

    public mutating func handle(_ event: RealtimeEvent) -> Decision {
        switch event {
        case .speechStarted(let item, _):
            speaking = true
            add(item)
        case .speechStopped(let item, _):
            speaking = false
            add(item)
        case .committed(let item):
            add(item)
        case .completed(let item, let transcript):
            add(item)
            done[item] = transcript
        case .failed(let item, let message):
            add(item)
            done[item] = ""
            failures.append(message)
        default:
            return .wait
        }
        return check()
    }

    private mutating func add(_ item: String) {
        if !order.contains(item) { order.append(item) }
    }

    private mutating func check() -> Decision {
        guard !speaking, !order.isEmpty, order.allSatisfy({ done[$0] != nil }) else { return .wait }
        let text = order.compactMap { done[$0] }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            discardedEmpty += 1
            order.removeAll()
            done.removeAll()
            return .wait
        }
        return .finish(text)
    }
}

/// 1 回の listen の間だけ開く WebSocket (claude-talk-voice は常駐中ずっと開く)。
public final class RealtimeSession: @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let session: URLSession

    /// requestTimeout: 受信が途切れてよい長さ。listen (1 回ごと) は 10 秒、常駐の claude-talk-voice は長くする。
    public init(url: URL, requestTimeout: TimeInterval = 10) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = requestTimeout
        session = URLSession(configuration: config)
        task = session.webSocketTask(with: url)
        task.maximumMessageSize = 16 * 1024 * 1024
    }

    public static func sessionUpdate(settings: DirectSettings, language: String, keywords: [String]) -> [String: Any] {
        var transcription: [String: Any] = ["language": language]
        if !keywords.isEmpty { transcription["keywords"] = keywords }
        return [
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": [
                    "input": [
                        "format": ["type": "audio/pcm", "rate": PCM.sampleRate],
                        "transcription": transcription,
                        "turn_detection": [
                            "type": "server_vad",
                            "silence_duration_ms": settings.silenceMs,
                            "prefix_padding_ms": settings.prefixPaddingMs,
                            "threshold": settings.vadThreshold,
                        ],
                    ] as [String: Any],
                ],
            ] as [String: Any],
        ]
    }

    /// つないで session.update を送り、session.updated を待つ。
    public func open(update: [String: Any], timeout: Double = 5) async throws {
        task.resume()
        try await sendJSON(update)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let ev = try await receive()
            switch ev {
            case .sessionUpdated: return
            case .error(let m): throw TalkError.realtime(m)
            default: continue
            }
        }
        throw TalkError.realtime("session.updated が来ません")
    }

    public func append(_ pcm: Data) async throws {
        try await sendJSON(["type": "input_audio_buffer.append", "audio": pcm.base64EncodedString()])
    }

    public func commit() async throws {
        try await sendJSON(["type": "input_audio_buffer.commit"])
    }

    public func receive() async throws -> RealtimeEvent {
        do {
            switch try await task.receive() {
            case .string(let s): return RealtimeEvent.parse(s)
            case .data(let d): return RealtimeEvent.parse(String(decoding: d, as: UTF8.self))
            @unknown default: return .other("unknown message")
            }
        } catch {
            throw TalkError.realtime("受信できません: \(error.localizedDescription)")
        }
    }

    public func close() {
        task.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }

    private func sendJSON(_ obj: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: obj)
        do {
            try await task.send(.string(String(decoding: data, as: UTF8.self)))
        } catch {
            throw TalkError.realtime("送信できません: \(error.localizedDescription)")
        }
    }
}
