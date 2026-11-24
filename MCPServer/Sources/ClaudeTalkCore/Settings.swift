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
    /// 読み上げ (Irodori) の speech serve。listen の serve (8766) とは別のプロセス。
    public static var ttsServeLog: URL { directDir.appendingPathComponent("tts-serve.log") }
    public static var ttsServeLock: URL { directDir.appendingPathComponent("tts-serve.lock") }
    public static var ttsServePid: URL { directDir.appendingPathComponent("tts-serve.pid") }
    /// 読み上げ前の読みの辞書 (1 行 1 語、`表記=読み`)。
    public static var readingsFile: URL { directDir.appendingPathComponent("readings.txt") }
    public static var voicesDir: URL { directDir.appendingPathComponent("voices", isDirectory: true) }

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
    /// プリロールの始点は、直前の読み上げの終わり (実際に鳴り終わった時) からこの ms 後より前にしない
    /// (スピーカーの残り音を拾わないため)。0 で無効。
    public var speakTailGuardMs: Int = 150
    /// 読み上げの終わりからこの ms 以内に始まった発話は、直前の読み上げ文と似ていたら捨てて聞き直す。0 で無効。
    public var echoWindowMs: Int = 2000
    /// 「似ている」とみなす一致度 (0〜1。正規化後の近似部分一致)。0 で無効。
    public var echoSimilarity: Double = 0.75
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

    // MARK: 読み上げ (speak)

    /// 読み上げの仕組み: `irodori` (speech.cpp の Irodori-TTS、既定) / `avspeech` (macOS の AVSpeechSynthesizer)。
    /// irodori の serve が立たない・声が無い時は avspeech に落ちて timing.jsonl に `speak.fallback` を書く。
    public var tts: String = "irodori"
    /// Irodori の speech serve の待ち受けポート (127.0.0.1 固定)。listen の port とは別のプロセス。
    public var ttsPort: Int = 8767
    public var ttsModel: String = "irodori-tts-mf:q5_k"
    /// serve に `--add-voice 名前=ファイル` で足す声。
    public var ttsVoiceName: String = "irodori-f-low"
    public var ttsVoiceFile: String = "~/.claude-talk-mcp/direct/voices/irodori-f-low.voice.gguf"
    /// 声と話し方の説明文 (Irodori の instructions)。空なら送らない。
    public var ttsInstructions: String = "落ち着いた低めの女性の声で、ゆっくり穏やかに読み上げてください。"
    /// Irodori の speed (0.25〜4)。未指定はモデルの既定 (1)。
    public var ttsSpeed: Double?
    /// Irodori の seed。未指定は毎回サーバーが選ぶ (声は声ファイルで揃う)。
    public var ttsSeed: Int?
    /// TTS の serve の起動を speak が待つ上限。超えたらその回は avspeech (serve は裏で起動を続ける)。
    public var ttsStartTimeoutSeconds: Double = 20
    /// 最初の音のデータが届くまでの上限。超えたらその回は avspeech。
    public var ttsFirstAudioTimeoutSeconds: Double = 10
    /// 辞書に無い英字の扱い: `auto` (大文字だけの 2〜6 文字はアルファベット読み、ほかはそのまま) / `keep` / `spell`。
    public var ttsLatin: String = "auto"

    public init() {}

    enum CodingKeys: String, CodingKey {
        case port, speechBin, asrModel, vadModel, language, silenceMs, prefixPaddingMs, vadThreshold
        case micIdleCloseSeconds, prerollMaxSeconds, prerollLeadSeconds, maxSpeechSeconds
        case speakTailGuardMs, echoWindowMs, echoSimilarity
        case serverStartTimeoutSeconds, silentMicCheckSeconds, micNoDataTimeoutSeconds, micLockWaitSeconds
        case voice, rate
        case tts, ttsPort, ttsModel, ttsVoiceName, ttsVoiceFile, ttsInstructions, ttsSpeed, ttsSeed
        case ttsStartTimeoutSeconds, ttsFirstAudioTimeoutSeconds, ttsLatin
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
        speakTailGuardMs = try c.decodeIfPresent(Int.self, forKey: .speakTailGuardMs) ?? d.speakTailGuardMs
        echoWindowMs = try c.decodeIfPresent(Int.self, forKey: .echoWindowMs) ?? d.echoWindowMs
        echoSimilarity = try c.decodeIfPresent(Double.self, forKey: .echoSimilarity) ?? d.echoSimilarity
        serverStartTimeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .serverStartTimeoutSeconds) ?? d.serverStartTimeoutSeconds
        silentMicCheckSeconds = try c.decodeIfPresent(Double.self, forKey: .silentMicCheckSeconds) ?? d.silentMicCheckSeconds
        micNoDataTimeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .micNoDataTimeoutSeconds) ?? d.micNoDataTimeoutSeconds
        micLockWaitSeconds = try c.decodeIfPresent(Double.self, forKey: .micLockWaitSeconds) ?? d.micLockWaitSeconds
        voice = try c.decodeIfPresent(String.self, forKey: .voice)
        rate = try c.decodeIfPresent(Double.self, forKey: .rate)
        tts = try c.decodeIfPresent(String.self, forKey: .tts) ?? d.tts
        ttsPort = try c.decodeIfPresent(Int.self, forKey: .ttsPort) ?? d.ttsPort
        ttsModel = try c.decodeIfPresent(String.self, forKey: .ttsModel) ?? d.ttsModel
        ttsVoiceName = try c.decodeIfPresent(String.self, forKey: .ttsVoiceName) ?? d.ttsVoiceName
        ttsVoiceFile = try c.decodeIfPresent(String.self, forKey: .ttsVoiceFile) ?? d.ttsVoiceFile
        ttsInstructions = try c.decodeIfPresent(String.self, forKey: .ttsInstructions) ?? d.ttsInstructions
        ttsSpeed = try c.decodeIfPresent(Double.self, forKey: .ttsSpeed)
        ttsSeed = try c.decodeIfPresent(Int.self, forKey: .ttsSeed)
        ttsStartTimeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .ttsStartTimeoutSeconds) ?? d.ttsStartTimeoutSeconds
        ttsFirstAudioTimeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .ttsFirstAudioTimeoutSeconds) ?? d.ttsFirstAudioTimeoutSeconds
        ttsLatin = try c.decodeIfPresent(String.self, forKey: .ttsLatin) ?? d.ttsLatin
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

    /// 読み上げの仕組み (知らない値は irodori)。
    public var ttsEngine: TTSEngineKind { TTSEngineKind(rawValue: tts.lowercased().trimmingCharacters(in: .whitespaces)) ?? .irodori }
    public var ttsBaseURL: URL { URL(string: "http://127.0.0.1:\(ttsPort)")! }
    public var ttsVoiceFilePath: String { (ttsVoiceFile as NSString).expandingTildeInPath }
}

public enum TTSEngineKind: String, Sendable {
    case irodori
    case avspeech
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
