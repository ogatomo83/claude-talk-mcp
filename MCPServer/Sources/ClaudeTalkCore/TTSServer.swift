//
//  TTSServer.swift
//  ClaudeTalkCore
//
//  読み上げ用の speech serve (Qwen3-TTS 0.6B の 8768 / Irodori-TTS + 声ファイルの 8767、127.0.0.1 だけ) を、
//  要る時に起動して /health で確かめる。
//  listen の serve (SpeechServer、Haas + Silero、8766) とは別のプロセスにした:
//    - 8766 に足すと、動いている 8766 を止めて起動し直す必要があり、listen の起動も 0.4 秒 → 2 秒に延びる
//    - メモリは別にしても +0.1 GB ほど (同居 2.2 GB / 別々 1.3 + 1.0 GB、T-0031 の実測)
//  起動は 1 つだけ (ファイルロック) で、起こした後は MCP サーバーが終わっても残す (次のセッションも使う)。
//

import Foundation

public enum TTSError: LocalizedError, Equatable {
    case server(String)
    case stream(String)

    public var errorDescription: String? {
        switch self {
        case .server(let m): return "読み上げサーバー: \(m)"
        case .stream(let m): return "読み上げ: \(m)"
        }
    }
}

public struct TTSServer: Sendable {
    public let settings: DirectSettings

    public init(settings: DirectSettings) { self.settings = settings }

    public enum Health: Equatable { case ready, wrong(String), down }

    /// /health と /v1/models を見る: 合成のモデルがあり、声 (ttsVoiceName) が足されていれば ready。
    public func health() async -> Health {
        var req = URLRequest(url: settings.ttsBaseURL.appendingPathComponent("health"))
        req.timeoutInterval = 1.5
        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return .down }
        var mreq = URLRequest(url: settings.ttsBaseURL.appendingPathComponent("v1/models"))
        mreq.timeoutInterval = 3
        guard let (data, _) = try? await URLSession.shared.data(for: mreq),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["data"] as? [[String: Any]] else { return .wrong("/v1/models を読めません") }
        return Self.check(models: list, voice: settings.ttsVoiceName, port: settings.ttsPort)
    }

    static func check(models: [[String: Any]], voice: String, port: Int) -> Health {
        let synth = models.first { (($0["speech"] as? [String: Any])?["task"] as? String) == "synthesis" }
        guard let synth else {
            return .wrong("127.0.0.1:\(port) の speech serve に読み上げのモデルがありません")
        }
        let voices = ((synth["speech"] as? [String: Any])?["voices"] as? [[String: Any]])?
            .compactMap { $0["name"] as? String } ?? []
        guard voices.contains(voice) else {
            return .wrong("127.0.0.1:\(port) の speech serve に声 \(voice) がありません (voices: \(voices.joined(separator: ", ")))")
        }
        return .ready
    }

    /// 動いていなければ起動して、使えるまで待つ (上限 timeout 秒)。戻り値は「今起動したか」。
    /// 上限を超えても起動したプロセスは止めない (次の speak で使う)。
    @discardableResult
    public func ensureRunning(timeout: Double) async throws -> Bool {
        switch await health() {
        case .ready: return false
        case .wrong(let m): throw TTSError.server(m)
        case .down: break
        }
        let lock = FileLock(url: lockURL)
        guard await lock.lock(timeout: timeout) else {
            throw TTSError.server("読み上げの serve の起動を待ちきれません (\(lockURL.path))")
        }
        defer { lock.unlock() }
        switch await health() {
        case .ready: return false
        case .wrong(let m): throw TTSError.server(m)
        case .down: break
        }
        if let file = settings.ttsVoiceFilePath, !FileManager.default.fileExists(atPath: file) {
            throw TTSError.server("声ファイルがありません: \(file)")
        }
        let pid = try DetachedProcess.spawn(arguments: arguments, logURL: logURL, pidURL: pidURL)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
            switch await health() {
            case .ready: return true
            case .wrong(let m): throw TTSError.server(m)
            case .down:
                var status: Int32 = 0
                if waitpid(pid, &status, WNOHANG) == pid {
                    throw TTSError.server("読み上げの speech serve が終了しました。\(logURL.path) を見てください")
                }
            }
            if Task.isCancelled { throw CancellationError() }
        }
        throw TTSError.server("読み上げの speech serve が \(Int(timeout)) 秒で立ちません (\(logURL.path))")
    }

    public var logURL: URL { TalkPaths.ttsServeFile(settings.ttsServeEngine, "log") }
    public var lockURL: URL { TalkPaths.ttsServeFile(settings.ttsServeEngine, "lock") }
    public var pidURL: URL { TalkPaths.ttsServeFile(settings.ttsServeEngine, "pid") }

    /// 起動コマンド (127.0.0.1 だけで待ち受ける)。声ファイルがある時だけ --add-voice。
    public var arguments: [String] {
        var a = [settings.speechBinPath, "serve", settings.ttsModel,
                 "--host", "127.0.0.1", "--port", String(settings.ttsPort), "--language", settings.language]
        if let file = settings.ttsVoiceFilePath { a += ["--add-voice", "\(settings.ttsVoiceName)=\(file)"] }
        return a
    }
}

/// 新しいセッション (setsid) で子プロセスを起動する。MCP サーバーが終わっても残る。
/// SpeechServer.spawn と同じ作り (listen 側のコードを変えないため別に置いた)。
enum DetachedProcess {
    static func spawn(arguments: [String], logURL: URL, pidURL: URL) throws -> pid_t {
        let bin = arguments[0]
        guard FileManager.default.isExecutableFile(atPath: bin) else {
            throw TTSError.server("\(bin) がありません (speech.cpp のインストール)")
        }
        TalkPaths.ensureDir(logURL.deletingLastPathComponent())
        let logPath = logURL.path
        let header = "[direct] \(Date()) start: \(arguments.joined(separator: " "))\n"
        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: nil)
        }
        if let h = FileHandle(forWritingAtPath: logPath) {
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
        guard rc == 0 else { throw TTSError.server("起動に失敗 (posix_spawn \(rc))") }
        try? "\(pid)\n".write(to: pidURL, atomically: true, encoding: .utf8)
        return pid
    }
}
