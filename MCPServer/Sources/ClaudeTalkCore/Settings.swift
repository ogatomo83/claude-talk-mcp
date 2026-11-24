//
//  Settings.swift
//  ClaudeTalkCore
//
//  モード切替 (~/.claude-talk-mcp/mode) と direct モードの設定・語彙を読む。
//  どれも呼び出しのたびに読み直すので、ファイルを書き換えれば MCP サーバーの再起動なしで効く。
//

import Foundation

/// 置き場所。`CLAUDE_TALK_HOME` で差し替えられる (テスト用)。
public enum TalkPaths {
    public static var home: URL {
        if let override = ProcessInfo.processInfo.environment["CLAUDE_TALK_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude-talk-mcp", isDirectory: true)
    }

    /// `app` / `direct` の 1 語。
    public static var modeFile: URL { home.appendingPathComponent("mode") }
    public static var directDir: URL { home.appendingPathComponent("direct", isDirectory: true) }
    /// direct モードの設定 (JSON、全項目省略可)。
    public static var settingsFile: URL { directDir.appendingPathComponent("settings.json") }
    /// 語彙の追加 (1 行 1 語、`表記=読み,読み`)。
    public static var keywordsFile: URL { directDir.appendingPathComponent("keywords.txt") }
    public static var serveLog: URL { directDir.appendingPathComponent("serve.log") }
    public static var serveLock: URL { directDir.appendingPathComponent("serve.lock") }
    public static var micLock: URL { directDir.appendingPathComponent("mic.lock") }
    public static var logsDir: URL { home.appendingPathComponent("logs", isDirectory: true) }
    /// 1 往復の各段の時間 (JSON Lines)。
    public static var timingLog: URL { logsDir.appendingPathComponent("timing.jsonl") }

    public static func ensureDir(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

/// 経路の切り替え。
public enum TalkMode: String, Sendable {
    /// 今まで通り: Unix ソケット経由でメニューバーの音声アプリに頼む。
    case app
    /// MCP サーバー自身が録音・読み上げし、speech.cpp の Realtime に流す。
    case direct

    /// 環境変数 `CLAUDE_TALK_MODE` > `~/.claude-talk-mcp/mode` > 既定 `app`。
    /// 読めない・知らない値は `app` (今の動作) に倒す。
    public static func current(environment: [String: String] = ProcessInfo.processInfo.environment,
                               modeFile: URL = TalkPaths.modeFile) -> TalkMode {
        if let env = environment["CLAUDE_TALK_MODE"], let mode = parse(env) {
            return mode
        }
        if let text = try? String(contentsOf: modeFile, encoding: .utf8), let mode = parse(text) {
            return mode
        }
        return .app
    }

    public static func parse(_ text: String) -> TalkMode? {
        TalkMode(rawValue: text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
}

/// direct モードの設定。`~/.claude-talk-mcp/direct/settings.json` の項目で上書きできる。
public struct DirectSettings: Codable, Equatable, Sendable {
    /// speech serve の待ち受けポート (127.0.0.1 固定)。app モードの 8765 とは別。
    public var port: Int = 8766
    public var speechBin: String = "~/.local/bin/speech"
    public var asrModel: String = "haas-ja-v1.0:f16"
    public var vadModel: String = "silero-vad"
    public var language: String = "ja"
    /// 話し終わりとみなす無音 (server_vad の silence_duration_ms)。
    public var silenceMs: Int = 500
    public var prefixPaddingMs: Int = 300
    public var vadThreshold: Double = 0.5
    /// 最後の listen / speak からこの秒数でマイクを閉じる。
    public var micIdleCloseSeconds: Double = 60
    /// 合図 (speak) の後、listen が来る前の音をどこまで遡って使うか (プリロール)。
    public var prerollMaxSeconds: Double = 8
    /// speak が無い時に listen の前の音を足す長さ (頭切れの保険)。
    public var prerollLeadSeconds: Double = 0.3
    /// 話し始めてからの上限 (超えたら区切って返す)。listen の timeout は「話し始めを待つ長さ」。
    public var maxSpeechSeconds: Double = 120
    /// speech serve の起動待ち (Haas の初回読み込みは 14 秒前後のことがある)。
    public var serverStartTimeoutSeconds: Double = 120
    /// マイクを開けてからこの秒数の音が全部 0 なら「無音のマイク」としてエラーにする。
    public var silentMicCheckSeconds: Double = 1.0
    /// この秒数たっても音のデータが 1 つも来なければエラー。
    public var micNoDataTimeoutSeconds: Double = 3.0
    /// 2 つ目のセッションがマイクを待つ上限 (秒)。
    public var micLockWaitSeconds: Double = 10
    /// 読み上げの声 (AVSpeechSynthesisVoice の identifier)。未指定は locale の既定。
    public var voice: String?
    public var rate: Double?

    public init() {}

    enum CodingKeys: String, CodingKey {
        case port, speechBin, asrModel, vadModel, language, silenceMs, prefixPaddingMs, vadThreshold
        case micIdleCloseSeconds, prerollMaxSeconds, prerollLeadSeconds, maxSpeechSeconds
        case serverStartTimeoutSeconds, silentMicCheckSeconds, micNoDataTimeoutSeconds, micLockWaitSeconds
        case voice, rate
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DirectSettings()
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? d.port
        speechBin = try c.decodeIfPresent(String.self, forKey: .speechBin) ?? d.speechBin
        asrModel = try c.decodeIfPresent(String.self, forKey: .asrModel) ?? d.asrModel
        vadModel = try c.decodeIfPresent(String.self, forKey: .vadModel) ?? d.vadModel
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? d.language
        silenceMs = try c.decodeIfPresent(Int.self, forKey: .silenceMs) ?? d.silenceMs
        prefixPaddingMs = try c.decodeIfPresent(Int.self, forKey: .prefixPaddingMs) ?? d.prefixPaddingMs
        vadThreshold = try c.decodeIfPresent(Double.self, forKey: .vadThreshold) ?? d.vadThreshold
        micIdleCloseSeconds = try c.decodeIfPresent(Double.self, forKey: .micIdleCloseSeconds) ?? d.micIdleCloseSeconds
        prerollMaxSeconds = try c.decodeIfPresent(Double.self, forKey: .prerollMaxSeconds) ?? d.prerollMaxSeconds
        prerollLeadSeconds = try c.decodeIfPresent(Double.self, forKey: .prerollLeadSeconds) ?? d.prerollLeadSeconds
        maxSpeechSeconds = try c.decodeIfPresent(Double.self, forKey: .maxSpeechSeconds) ?? d.maxSpeechSeconds
        serverStartTimeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .serverStartTimeoutSeconds) ?? d.serverStartTimeoutSeconds
        silentMicCheckSeconds = try c.decodeIfPresent(Double.self, forKey: .silentMicCheckSeconds) ?? d.silentMicCheckSeconds
        micNoDataTimeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .micNoDataTimeoutSeconds) ?? d.micNoDataTimeoutSeconds
        micLockWaitSeconds = try c.decodeIfPresent(Double.self, forKey: .micLockWaitSeconds) ?? d.micLockWaitSeconds
        voice = try c.decodeIfPresent(String.self, forKey: .voice)
        rate = try c.decodeIfPresent(Double.self, forKey: .rate)
    }

    /// 設定ファイルを読む。無い・壊れている時は既定値 (壊れている時は warning を返す)。
    public static func load(from url: URL = TalkPaths.settingsFile) -> (DirectSettings, String?) {
        guard let data = try? Data(contentsOf: url) else { return (DirectSettings(), nil) }
        do {
            return (try JSONDecoder().decode(DirectSettings.self, from: data), nil)
        } catch {
            return (DirectSettings(), "settings.json を読めません (既定値で続けます): \(error)")
        }
    }

    public var speechBinPath: String { (speechBin as NSString).expandingTildeInPath }
    public var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }
    public var realtimeURL: URL { URL(string: "ws://127.0.0.1:\(port)/v1/realtime")! }
}

/// Haas の語彙 (keywords)。組み込みの既定 + `keywords.txt` の追加・上書き・削除。
public enum Vocabulary {
    /// 組み込みの既定。表記=読み (Haas がそう書きがちな形も読みに入れる)。
    public static let builtIn: [String] = [
        "Docker=ドッカー,ドーカー,どうか",
        "TypeScript=タイプスクリプト",
        "JavaScript=ジャバスクリプト",
        "Kubernetes=クバネティス,クーバネティス,キューバーネティス,キューバーニーツ",
        "Python=パイソン",
        "Qwen=クウェン,キューウェン",
        "Haas=ハース",
        "Claude=クロード",
        "GitHub=ギットハブ",
    ]

    /// `keywords.txt` の書式:
    /// - 1 行 1 語。`表記=読み,読み` (読みは省略可)
    /// - `#` から行末はコメント、空行は無視
    /// - 同じ表記の行は既定を上書き。`-表記` は既定から外す
    public static func merge(builtIn: [String] = builtIn, fileText: String?) -> [String] {
        var order: [String] = []
        var entries: [String: String] = [:]
        func key(of line: String) -> String {
            String(line.split(separator: "=", maxSplits: 1).first ?? "").trimmingCharacters(in: .whitespaces)
        }
        func put(_ line: String) {
            let k = key(of: line)
            guard !k.isEmpty else { return }
            if entries[k] == nil { order.append(k) }
            entries[k] = line
        }
        builtIn.forEach(put)
        for raw in (fileText ?? "").components(separatedBy: .newlines) {
            var line = raw
            if let hash = line.firstIndex(of: "#") { line = String(line[..<hash]) }
            line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("-") {
                let k = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                entries[k] = nil
                order.removeAll { $0 == k }
                continue
            }
            put(line)
        }
        return order.compactMap { entries[$0] }
    }

    public static func load(from url: URL = TalkPaths.keywordsFile) -> [String] {
        merge(fileText: try? String(contentsOf: url, encoding: .utf8))
    }
}
