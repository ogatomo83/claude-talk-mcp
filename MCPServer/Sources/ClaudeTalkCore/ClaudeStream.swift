//
//  ClaudeStream.swift
//  ClaudeTalkCore
//
//  `claude -p --input-format stream-json --output-format stream-json` を子プロセスとして長く動かす。
//  stdin に 1 行 1 JSON (user メッセージ / control_request interrupt / control_response) を書き、
//  stdout の 1 行 1 JSON を ClaudeEvent にして流す。
//
//  確かめた形 (claude 2.1.331):
//    - user メッセージに "uuid" を付けると、command_lifecycle (queued / started / cancelled / completed) の
//      command_uuid と、--replay-user-messages の再送 (isReplay: true) に同じ uuid が付く。返事がどの発話の
//      ものかはこれで決める
//    - interrupt は control_response が数 ms で返り、割り込まれた返事の result が続く。interrupt の直後に
//      送った user メッセージは待ち行列に入り、続けて処理される
//    - 権限の確認は --permission-prompt-tool stdio のとき control_request (subtype can_use_tool) で来る。
//      ただし claude が安全とみなす操作 (echo など) は確認なしで通るので、危ないツールは --tools で外す
//

import Foundation

public enum ClaudeEvent: Equatable, Sendable {
    case initialized(sessionId: String, model: String, tools: [String])
    case commandStarted(uuid: String)
    case commandEnded(uuid: String, state: String)
    case messageStart
    case textDelta(String)
    case toolUseStart(name: String)
    /// 返事の 1 メッセージの全文 (text だけ)。
    case assistant(text: String, toolUses: [String])
    case result(subtype: String, isError: Bool, durationMs: Int?, apiMs: Int?, text: String, sessionId: String)
    case canUseTool(requestId: String, toolName: String, input: String)
    case otherControlRequest(requestId: String, subtype: String)
    case controlResponse(requestId: String, subtype: String, error: String?)
    case other(String)

    public static func parse(_ line: String) -> ClaudeEvent {
        guard let data = line.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = o["type"] as? String else { return .other("unparsable") }
        switch type {
        case "system":
            let sub = o["subtype"] as? String ?? ""
            if sub == "init" {
                return .initialized(sessionId: o["session_id"] as? String ?? "", model: o["model"] as? String ?? "",
                                    tools: o["tools"] as? [String] ?? [])
            }
            return .other("system.\(sub)")
        case "command_lifecycle":
            let uuid = o["command_uuid"] as? String ?? ""
            let state = o["state"] as? String ?? ""
            if state == "started" { return .commandStarted(uuid: uuid) }
            if state == "queued" { return .other("command_lifecycle.queued") }
            return .commandEnded(uuid: uuid, state: state)
        case "stream_event":
            guard let ev = o["event"] as? [String: Any], let et = ev["type"] as? String else { return .other("stream_event") }
            switch et {
            case "message_start": return .messageStart
            case "content_block_start":
                if let b = ev["content_block"] as? [String: Any], b["type"] as? String == "tool_use" {
                    return .toolUseStart(name: b["name"] as? String ?? "")
                }
            case "content_block_delta":
                if let d = ev["delta"] as? [String: Any], d["type"] as? String == "text_delta" {
                    return .textDelta(d["text"] as? String ?? "")
                }
            default: break
            }
            return .other("stream_event.\(et)")
        case "assistant":
            let content = (o["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            let text = content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
            let tools = content.filter { $0["type"] as? String == "tool_use" }.compactMap { $0["name"] as? String }
            return .assistant(text: text, toolUses: tools)
        case "result":
            return .result(subtype: o["subtype"] as? String ?? "", isError: o["is_error"] as? Bool ?? false,
                           durationMs: (o["duration_ms"] as? NSNumber)?.intValue,
                           apiMs: (o["duration_api_ms"] as? NSNumber)?.intValue,
                           text: o["result"] as? String ?? "", sessionId: o["session_id"] as? String ?? "")
        case "control_request":
            let id = o["request_id"] as? String ?? ""
            let req = o["request"] as? [String: Any] ?? [:]
            let sub = req["subtype"] as? String ?? ""
            if sub == "can_use_tool" {
                var input = ""
                if let i = req["input"], let d = try? JSONSerialization.data(withJSONObject: i, options: [.sortedKeys]) {
                    input = String(decoding: d, as: UTF8.self)
                }
                return .canUseTool(requestId: id, toolName: req["tool_name"] as? String ?? "", input: input)
            }
            return .otherControlRequest(requestId: id, subtype: sub)
        case "control_response":
            let r = o["response"] as? [String: Any] ?? [:]
            return .controlResponse(requestId: r["request_id"] as? String ?? "", subtype: r["subtype"] as? String ?? "",
                                    error: r["error"] as? String)
        default:
            return .other(type)
        }
    }

    // MARK: stdin に書く形

    public static func userMessage(text: String, uuid: String) -> [String: Any] {
        ["type": "user", "uuid": uuid,
         "message": ["role": "user", "content": [["type": "text", "text": text]]] as [String: Any]]
    }

    public static func interruptRequest(id: String) -> [String: Any] {
        ["type": "control_request", "request_id": id, "request": ["subtype": "interrupt"]]
    }

    public static func permissionResponse(requestId: String, allow: Bool, input: String, message: String) -> [String: Any] {
        var inner: [String: Any]
        if allow {
            let parsed = (try? JSONSerialization.jsonObject(with: Data(input.utf8))) ?? [String: Any]()
            inner = ["behavior": "allow", "updatedInput": parsed]
        } else {
            inner = ["behavior": "deny", "message": message]
        }
        return ["type": "control_response",
                "response": ["subtype": "success", "request_id": requestId, "response": inner] as [String: Any]]
    }

    public static func errorResponse(requestId: String, message: String) -> [String: Any] {
        ["type": "control_response",
         "response": ["subtype": "error", "request_id": requestId, "error": message]]
    }
}

/// claude の子プロセス。
public final class ClaudeProcess: @unchecked Sendable {
    public let events: AsyncStream<ClaudeEvent>
    private let cont: AsyncStream<ClaudeEvent>.Continuation
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let lock = NSLock()
    private var lineBuffer = Data()
    private var stderrHandle: FileHandle?
    /// 1 行ごとに呼ぶ (生の JSON をログに残す用)。
    public var onRawLine: (@Sendable (String) -> Void)?
    public private(set) var exitStatus: Int32?

    public init(executable: String, arguments: [String], cwd: String, stderrLog: URL) throws {
        (events, cont) = AsyncStream<ClaudeEvent>.makeStream(bufferingPolicy: .unbounded)
        // PATH から探す (Process は絶対パスが要る)。
        if executable.contains("/") {
            process.executableURL = URL(fileURLWithPath: (executable as NSString).expandingTildeInPath)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + arguments
        }
        process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        TalkPaths.ensureDir(stderrLog.deletingLastPathComponent())
        if !FileManager.default.fileExists(atPath: stderrLog.path) {
            FileManager.default.createFile(atPath: stderrLog.path, contents: nil)
        }
        if let h = FileHandle(forWritingAtPath: stderrLog.path) {
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: Data("[voice] \(Date()) start: \(arguments.prefix(20).joined(separator: " "))\n".utf8))
            stderrHandle = h
            process.standardError = h
        }
        // 音声の会話の中から入れ子の claude と判定されないようにする。
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "CLAUDECODE")
        env.removeValue(forKey: "CLAUDE_CODE_ENTRYPOINT")
        process.environment = env
        let cont = self.cont
        process.terminationHandler = { [weak self] p in
            self?.exitStatus = p.terminationStatus
            cont.finish()
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard let self else { return }
            if d.isEmpty {
                h.readabilityHandler = nil
                return
            }
            self.consume(d)
        }
        try process.run()
    }

    public var pid: Int32 { process.processIdentifier }
    public var isRunning: Bool { process.isRunning }

    private func consume(_ d: Data) {
        lock.lock()
        lineBuffer.append(d)
        var lines: [String] = []
        while let nl = lineBuffer.firstIndex(of: 0x0A) {
            let line = lineBuffer.subdata(in: lineBuffer.startIndex..<nl)
            lineBuffer.removeSubrange(lineBuffer.startIndex...nl)
            if !line.isEmpty { lines.append(String(decoding: line, as: UTF8.self)) }
        }
        lock.unlock()
        for l in lines {
            onRawLine?(l)
            cont.yield(ClaudeEvent.parse(l))
        }
    }

    public func send(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        lock.lock(); defer { lock.unlock() }
        guard process.isRunning else { return }
        try? stdinPipe.fileHandleForWriting.write(contentsOf: data + Data([0x0A]))
    }

    /// stdin を閉じて終わるのを待ち、待ちきれなければ SIGTERM → SIGKILL。
    public func terminate(grace: Double = 3) {
        try? stdinPipe.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(grace)
        while process.isRunning, Date() < deadline { usleep(50_000) }
        if process.isRunning { process.terminate() }
        let d2 = Date().addingTimeInterval(1)
        while process.isRunning, Date() < d2 { usleep(50_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        try? stderrHandle?.close()
    }
}
