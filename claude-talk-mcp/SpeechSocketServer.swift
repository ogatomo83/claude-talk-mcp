//
//  SpeechSocketServer.swift
//  claude-talk-mcp
//
//  Unix ドメインソケットで待ち受け、NDJSON リクエストを逐次処理する。
//

import Foundation

/// `~/.claude-talk-mcp/speech.sock` を listen し、1 接続ずつ順番に処理するサーバー。
///
/// blocking な accept/read ループは専用スレッドで回し、リクエスト処理は
/// 渡された async ハンドラ（= MainActor 側の TTS/STT）へブリッジする。
final class SpeechSocketServer: @unchecked Sendable {

    typealias Handler = @Sendable (SpeechRequest) async -> SpeechResponse

    nonisolated(unsafe) private var listenFD: Int32 = -1
    nonisolated(unsafe) private var handler: Handler?
    nonisolated(unsafe) private var isRunning = false
    private let queue = DispatchQueue(label: "claude-talk-mcp.socket", qos: .userInitiated)

    /// 待ち受けを開始する。
    func start(handler: @escaping Handler) throws {
        guard !isRunning else { return }
        self.handler = handler

        try FileManager.default.createDirectory(
            at: SpeechSocket.directoryURL,
            withIntermediateDirectories: true
        )

        let path = SpeechSocket.path
        // 既存の stale なソケットファイルを削除。
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw SocketError.system("socket() 失敗")
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            throw SocketError.system("ソケットパスが長すぎます")
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count + 1) { dst in
                for (i, b) in pathBytes.enumerated() { dst[i] = CChar(bitPattern: b) }
                dst[pathBytes.count] = 0
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            throw SocketError.system("bind() 失敗: \(String(cString: strerror(errno)))")
        }

        guard listen(fd, 8) == 0 else {
            close(fd)
            throw SocketError.system("listen() 失敗")
        }

        listenFD = fd
        isRunning = true

        // 受信ループは必ずバックグラウンドのシリアルキューで回す。
        // （メインスレッドで回すと runBlocking の semaphore.wait で MainActor が
        //   止まり、handle() が実行できずデッドロックする）
        queue.async { [weak self] in
            self?.acceptLoop()
        }
    }

    /// 待ち受けを停止する。
    func stop() {
        isRunning = false
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        unlink(SpeechSocket.path)
    }

    // MARK: - Background loop

    nonisolated private func acceptLoop() {
        while isRunning {
            let clientFD = accept(listenFD, nil, nil)
            if clientFD < 0 {
                if !isRunning { break }
                continue
            }
            handleConnection(clientFD)
            close(clientFD)
        }
    }

    /// 1 接続分を処理。改行区切りで複数リクエストを順に捌く。
    nonisolated private func handleConnection(_ fd: Int32) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)

        while isRunning {
            // 溜まっている完全な行をすべて処理。
            while let nl = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                processLine(lineData, fd: fd)
            }

            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break } // 切断 or エラー
            buffer.append(contentsOf: chunk[0..<n])
        }
    }

    nonisolated private func processLine(_ line: Data, fd: Int32) {
        let trimmed = line.filter { $0 != 0x0D } // CR 除去
        guard !trimmed.isEmpty else { return }

        let response: SpeechResponse
        if let request = SpeechRequest.parse(line: Data(trimmed)), let handler {
            response = runBlocking { await handler(request) }
        } else {
            response = .failure("不正なリクエストです")
        }
        writeAll(fd: fd, data: response.jsonLine())
    }

    /// async ハンドラをこのバックグラウンドスレッド上で同期的に待つ。
    /// Task.detached でメインアクターに載らないようにし、handle()（MainActor）が
    /// 空いたメインスレッドで実行できるようにする。
    nonisolated private func runBlocking(_ work: @escaping @Sendable () async -> SpeechResponse) -> SpeechResponse {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox()
        Task.detached {
            let result = await work()
            box.value = result
            semaphore.signal()
        }
        semaphore.wait()
        return box.value ?? .failure("内部エラー")
    }

    nonisolated private func writeAll(fd: Int32, data: Data) {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            let total = raw.count
            while offset < total {
                let written = write(fd, base + offset, total - offset)
                if written <= 0 { break }
                offset += written
            }
        }
    }

    private final class ResultBox: @unchecked Sendable {
        var value: SpeechResponse?
    }

    enum SocketError: LocalizedError {
        case system(String)
        var errorDescription: String? {
            switch self {
            case .system(let message): return message
            }
        }
    }
}
