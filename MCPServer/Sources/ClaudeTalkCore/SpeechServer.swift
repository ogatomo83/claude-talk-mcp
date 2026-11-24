//
//  SpeechServer.swift
//  ClaudeTalkCore
//
//  direct モード用の speech serve (Haas + Silero VAD、127.0.0.1 だけ) を、要る時に起動して /health で確かめる。
//  起動は 1 つだけ (ファイルロック) で、起こした後は MCP サーバーが終わっても残す (次のセッションも使う)。
//

import Foundation

public enum TalkError: LocalizedError, Equatable {
    case audio(String)
    case micPermission
    case micSilent(String)
    case micBusy
    case server(String)
    case realtime(String)

    public var errorDescription: String? {
        switch self {
        case .audio(let m): return m
        case .micPermission:
            return "マイクの許可がありません。システム設定 > プライバシーとセキュリティ > マイク で、Claude Code を動かしているアプリ (iTerm2 など) を ON にしてください"
        case .micSilent(let m): return m
        case .micBusy:
            return "別の Claude のセッションがマイクを使っています (しばらく待つか、そちらの会話を終えてください)"
        case .server(let m): return "音声認識サーバー: \(m)"
        case .realtime(let m): return "音声認識 (Realtime): \(m)"
        }
    }
}

/// flock(2) のロック。プロセスが終われば OS が外す。
public final class FileLock: @unchecked Sendable {
    private var fd: Int32 = -1
    public let url: URL

    public init(url: URL) { self.url = url }

    deinit { unlock() }

    /// 取れたら true。
    public func tryLock() -> Bool {
        if fd >= 0 { return true }
        TalkPaths.ensureDir(url.deletingLastPathComponent())
        let f = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard f >= 0 else { return false }
        if flock(f, LOCK_EX | LOCK_NB) == 0 {
            fd = f
            let pidLine = "\(getpid())\n"
            ftruncate(f, 0)
            _ = pidLine.withCString { write(f, $0, strlen($0)) }
            return true
        }
        close(f)
        return false
    }

    /// 取れるまで待つ (上限あり)。
    public func lock(timeout: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if tryLock() { return true }
            if Date() >= deadline || Task.isCancelled { return false }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    public func unlock() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    public var isLocked: Bool { fd >= 0 }
}

public struct SpeechServer: Sendable {
    public let settings: DirectSettings

    public init(settings: DirectSettings) { self.settings = settings }

    public enum Health: Equatable { case ready, noVAD(String), down }

    /// /health と /v1/models を見る。
    public func health() async -> Health {
        var req = URLRequest(url: settings.baseURL.appendingPathComponent("health"))
        req.timeoutInterval = 1.5
        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return .down }
        var mreq = URLRequest(url: settings.baseURL.appendingPathComponent("v1/models"))
        mreq.timeoutInterval = 3
        guard let (data, _) = try? await URLSession.shared.data(for: mreq),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["data"] as? [[String: Any]] else { return .noVAD("/v1/models を読めません") }
        let ids = list.compactMap { $0["id"] as? String }
        if ids.contains(where: { $0.lowercased().contains("silero") }) { return .ready }
        return .noVAD("127.0.0.1:\(settings.port) の speech serve に \(settings.vadModel) がありません (models: \(ids.joined(separator: ", ")))")
    }

    /// 動いていなければ起動して、使えるまで待つ。戻り値は「今起動したか」。
    @discardableResult
    public func ensureRunning() async throws -> Bool {
        switch await health() {
        case .ready: return false
        case .noVAD(let m): throw TalkError.server(m)
        case .down: break
        }
        // 起動は 1 つだけ。ほかのセッションが起動中ならロックを待つ間に立ち上がる。
        let lock = FileLock(url: TalkPaths.serveLock)
        guard await lock.lock(timeout: settings.serverStartTimeoutSeconds) else {
            throw TalkError.server("起動のロックを取れません (\(TalkPaths.serveLock.path))")
        }
        defer { lock.unlock() }
        switch await health() {
        case .ready: return false
        case .noVAD(let m): throw TalkError.server(m)
        case .down: break
        }
        let pid = try spawn()
        let deadline = Date().addingTimeInterval(settings.serverStartTimeoutSeconds)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 300_000_000)
            switch await health() {
            case .ready: return true
            case .noVAD(let m): throw TalkError.server(m)
            case .down:
                var status: Int32 = 0
                if waitpid(pid, &status, WNOHANG) == pid {
                    throw TalkError.server("speech serve が終了しました。\(TalkPaths.serveLog.path) を見てください")
                }
            }
            if Task.isCancelled { throw CancellationError() }
        }
        throw TalkError.server("\(Int(settings.serverStartTimeoutSeconds)) 秒待っても起動しません (\(TalkPaths.serveLog.path))")
    }

    /// 起動コマンド (127.0.0.1 だけで待ち受ける)。
    public var arguments: [String] {
        [settings.speechBinPath, "serve", settings.asrModel, settings.vadModel,
         "--host", "127.0.0.1", "--port", String(settings.port), "--language", settings.language]
    }

    /// 新しいセッション (setsid) で起動する。MCP サーバーが終わっても残る。
    private func spawn() throws -> pid_t {
        let bin = settings.speechBinPath
        guard FileManager.default.isExecutableFile(atPath: bin) else {
            throw TalkError.server("\(bin) がありません (speech.cpp のインストール)")
        }
        TalkPaths.ensureDir(TalkPaths.directDir)
        let logPath = TalkPaths.serveLog.path
        let header = "[direct] \(Date()) start: \(arguments.joined(separator: " "))\n"
        if let h = FileHandle(forWritingAtPath: logPath) ?? {
            FileManager.default.createFile(atPath: logPath, contents: nil)
            return FileHandle(forWritingAtPath: logPath)
        }() {
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: Data(header.utf8))
            try? h.close()
        }

        var fa: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fa)
        defer { posix_spawn_file_actions_destroy(&fa) }
        posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&fa, 1, logPath, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        posix_spawn_file_actions_adddup2(&fa, 1, 2)
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // 新しいセッションにし、0〜2 以外の fd (マイクのロックなど) を子に渡さない。
        // シグナルは既定に戻す (MCP サーバー側で無視にしている SIGINT / SIGTERM が子に引き継がれ、
        // kill で止められなくなるのを防ぐ)。
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT
                                              | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigdefault(&attr, &allSignals)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attr, &noSignals)

        var env = ProcessInfo.processInfo.environment
        env["SPEECH_NO_UPDATE_CHECK"] = "1"
        let envStrings = env.map { "\($0.key)=\($0.value)" }
        let argv = arguments.map { strdup($0) } + [nil]
        let envp = envStrings.map { strdup($0) } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, bin, &fa, &attr, argv, envp)
        guard rc == 0 else { throw TalkError.server("起動に失敗 (posix_spawn \(rc))") }
        try? "\(pid)\n".write(to: TalkPaths.directDir.appendingPathComponent("serve.pid"), atomically: true, encoding: .utf8)
        return pid
    }
}
