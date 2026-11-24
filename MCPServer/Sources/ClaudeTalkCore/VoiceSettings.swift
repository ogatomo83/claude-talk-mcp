//
//  VoiceSettings.swift
//  ClaudeTalkCore
//
//  claude-talk-voice (常駐する声のプロセス) の設定。`~/.claude-talk-mcp/voice/settings.json` (全項目省略可)。
//  録音・書き起こし・読み上げの設定は direct モードと同じ `direct/settings.json` (DirectSettings) を使う。
//

import Foundation

public extension TalkPaths {
    static var voiceDir: URL { home.appendingPathComponent("voice", isDirectory: true) }
    static var voiceSettingsFile: URL { voiceDir.appendingPathComponent("settings.json") }
    /// claude を動かす既定の作業ディレクトリ (空のフォルダ。CLAUDE.md・project の hook が入らない)。
    static var voiceWorkDir: URL { voiceDir.appendingPathComponent("work", isDirectory: true) }
    /// 会話の書き起こし (1 行 1 発話、人が読む用)。
    static var voiceTranscript: URL { voiceDir.appendingPathComponent("transcript.log") }
    /// claude の stderr。
    static var voiceClaudeStderr: URL { voiceDir.appendingPathComponent("claude-stderr.log") }
}

public struct VoiceSettings: Codable, Equatable, Sendable {
    /// claude の実行ファイル (PATH から探す名前か絶対パス)。
    public var claudeBin: String = "claude"
    /// claude を動かす作業ディレクトリ。空 (既定) は ~/.claude-talk-mcp/voice/work (空のフォルダ)。
    public var cwd: String = ""
    /// claude の --model。未指定は claude の既定。
    public var model: String?
    /// claude の --tools (使える組み込みツール)。既定は読み取りだけ。"" ならツールなし。
    public var tools: String = "Read,Glob,Grep"
    /// 権限の確認 (can_use_tool) が来た時に許すツール名。ここに無いものは全部断る。
    public var allowTools: [String] = ["Read", "Glob", "Grep"]
    /// true なら --strict-mcp-config (MCP サーバーを読まない)。claude-talk の MCP がマイクを取り合うのを防ぐ。
    public var strictMcp: Bool = true
    /// claude の --append-system-prompt。空なら付けない。
    public var appendSystemPrompt: String = VoiceSettings.defaultSystemPrompt
    /// 読み上げ中・考え中にユーザーが話し始めてから、この ms 話し続けたら割り込みとみなす (短い相づちで止めない)。
    public var bargeInMs: Int = 300
    /// 割り込まれた返事の、聞こえた所までを次のメッセージの頭に付ける。
    public var tellInterrupted: Bool = true
    /// 返事の最初の文だけ、この文字数を超えた読点 (、) でも区切る (最初の声を早くする)。0 で無効 (句点などでだけ区切る)。
    public var firstChunkMinChars: Int = 20
    /// claude に足す引数 (そのまま渡す)。
    public var extraArgs: [String] = []

    public init() {}

    public static let defaultSystemPrompt = """
    これは音声の会話です。あなたの返事はそのまま日本語で読み上げられ、ユーザーは耳で聞きます。
    - 話し言葉で、短く答える (ふつうは 1〜3 文)。長い説明が要る時は要点だけ先に言い、続きを聞くか尋ねる
    - Markdown・箇条書き・表・コード・URL・絵文字は使わない。記号や英字の略語は読める形にする
    - ターンを渡す合図 (「どうぞ」など) は付けない
    - ユーザーの発話は音声認識の書き起こしなので、誤字や聞き間違いがありうる。意味が通らなければ短く聞き返す
    - 「(割り込み: …)」で始まるメッセージは、前の返事の途中でユーザーが話し始めたことを示す。続きを言い直さず、新しい発話に答える
    - この会話ではファイルの読み取り以外のツールは使えない
    """

    enum CodingKeys: String, CodingKey {
        case claudeBin, cwd, model, tools, allowTools, strictMcp, appendSystemPrompt, bargeInMs, tellInterrupted
        case firstChunkMinChars, extraArgs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = VoiceSettings()
        claudeBin = try c.decodeIfPresent(String.self, forKey: .claudeBin) ?? d.claudeBin
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd) ?? d.cwd
        model = try c.decodeIfPresent(String.self, forKey: .model)
        tools = try c.decodeIfPresent(String.self, forKey: .tools) ?? d.tools
        allowTools = try c.decodeIfPresent([String].self, forKey: .allowTools) ?? d.allowTools
        strictMcp = try c.decodeIfPresent(Bool.self, forKey: .strictMcp) ?? d.strictMcp
        appendSystemPrompt = try c.decodeIfPresent(String.self, forKey: .appendSystemPrompt) ?? d.appendSystemPrompt
        bargeInMs = try c.decodeIfPresent(Int.self, forKey: .bargeInMs) ?? d.bargeInMs
        tellInterrupted = try c.decodeIfPresent(Bool.self, forKey: .tellInterrupted) ?? d.tellInterrupted
        firstChunkMinChars = try c.decodeIfPresent(Int.self, forKey: .firstChunkMinChars) ?? d.firstChunkMinChars
        extraArgs = try c.decodeIfPresent([String].self, forKey: .extraArgs) ?? d.extraArgs
    }

    public static func load(from url: URL = TalkPaths.voiceSettingsFile) -> (VoiceSettings, String?) {
        guard let data = try? Data(contentsOf: url) else { return (VoiceSettings(), nil) }
        do {
            return (try JSONDecoder().decode(VoiceSettings.self, from: data), nil)
        } catch {
            return (VoiceSettings(), "voice/settings.json を読めません (既定値で続けます): \(error)")
        }
    }

    public var cwdPath: String { cwd.isEmpty ? TalkPaths.voiceWorkDir.path : (cwd as NSString).expandingTildeInPath }

    /// 権限の確認への答え。allowTools にあるものだけ許す。
    public func permits(tool: String) -> Bool { allowTools.contains(tool) }

    /// claude に渡す引数 (実行ファイルの後ろ)。
    public func claudeArguments(sessionId: String?, resume: String?) -> [String] {
        var a = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                 "--include-partial-messages", "--replay-user-messages",
                 // 権限の確認をこのプロセスが stdin/stdout の control_request で受ける。
                 "--permission-prompt-tool", "stdio",
                 "--tools", tools]
        if strictMcp { a.append("--strict-mcp-config") }
        if let model, !model.isEmpty { a += ["--model", model] }
        if !appendSystemPrompt.isEmpty { a += ["--append-system-prompt", appendSystemPrompt] }
        if let resume, !resume.isEmpty {
            a += ["--resume", resume]
        } else if let sessionId {
            a += ["--session-id", sessionId]
        }
        return a + extraArgs
    }
}
