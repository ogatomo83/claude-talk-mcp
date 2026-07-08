//
//  SpeechSocketClient.swift
//  claude-talk-mcp-server
//
//  常駐音声アプリへ Unix ドメインソケットで接続し、NDJSON を 1 往復する。
//

import Foundation

enum SpeechSocketError: LocalizedError {
    case appNotRunning
    case io(String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .appNotRunning:
            return "音声アプリが起動していません（claude-talk-mcp を起動してください）"
        case .io(let message):
            return "ソケット通信エラー: \(message)"
        case .badResponse:
            return "音声アプリからの応答を解釈できませんでした"
        }
    }
}

struct SpeechSocketClient {

    /// `~/.claude-talk-mcp/speech.sock`
    static var socketPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".claude-talk-mcp", isDirectory: true)
            .appendingPathComponent("speech.sock")
            .path
    }

    /// リクエスト（JSON オブジェクト）を送り、レスポンス（1 行 JSON）を受け取る。
    func send(_ request: [String: Any]) throws -> [String: Any] {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw SpeechSocketError.io("socket() 失敗")
        }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = Self.socketPath
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            throw SpeechSocketError.io("ソケットパスが長すぎます")
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count + 1) { dst in
                for (i, b) in pathBytes.enumerated() { dst[i] = CChar(bitPattern: b) }
                dst[pathBytes.count] = 0
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            throw SpeechSocketError.appNotRunning
        }

        // 送信
        var payload = try JSONSerialization.data(withJSONObject: request)
        payload.append(0x0A) // 改行
        try writeAll(fd: fd, data: payload)

        // 受信（1 行）
        let line = try readLine(fd: fd)
        guard
            let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
        else {
            throw SpeechSocketError.badResponse
        }
        return object
    }

    private func writeAll(fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = write(fd, base + offset, raw.count - offset)
                if written <= 0 {
                    throw SpeechSocketError.io("write() 失敗")
                }
                offset += written
            }
        }
    }

    private func readLine(fd: Int32) throws -> Data {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                return buffer.subdata(in: buffer.startIndex..<nl)
            }
            let n = read(fd, &chunk, chunk.count)
            if n < 0 {
                throw SpeechSocketError.io("read() 失敗")
            }
            if n == 0 {
                // EOF：改行なしでも溜まっていれば返す。
                return buffer
            }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }
}
