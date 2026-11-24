//
//  Readings.swift
//  ClaudeTalkCore
//
//  Irodori-TTS に渡す前の英単語の置き換え。Irodori は日本語専用で英単語を読み違えやすい
//  (聴き比べで macOS → バーコモース、voice → ポイズ) ので、読みの辞書でカタカナにしてから渡す。
//
//  辞書 = 組み込みの既定 + `~/.claude-talk-mcp/direct/readings.txt` (speak のたびに読み直す)。
//  書式は keywords.txt と同じ:
//    - 1 行 1 語。`表記=読み` (読みが複数書いてあれば最初だけ使う)
//    - `#` から行末はコメント、空行は無視
//    - 同じ表記の行は既定を上書き。`-表記` は既定から外す
//  照合は英字の大文字小文字を区別しない。前後が英字の時は当てない (語の一部には当てない。数字は区切り)。長い表記を先に当てる。
//
//  辞書に無い英字 (設定 ttsLatin):
//    auto (既定) … 大文字だけの 2〜6 文字 (API, CLI, URL, AWS など) はアルファベット読み、ほかはそのまま
//    keep        … 全部そのまま (Irodori の読みに任せる)
//    spell       … 全部アルファベット読み
//  「そのまま」にした語は読み違える可能性が残るので、よく出る語は辞書に足す。
//

import Foundation

public enum Readings {
    public enum LatinMode: String, Sendable {
        case auto, keep, spell
    }

    /// 組み込みの既定。
    public static let builtIn: [String] = [
        // 依頼の例
        "Docker=ドッカー",
        "TypeScript=タイプスクリプト",
        "Kubernetes=クバネティス",
        "Python=パイソン",
        "Claude=クロード",
        "MCP=エムシーピー",
        // 聴き比べの文で読み違えた語
        "macOS=マックオーエス",
        "voice=ボイス",
        "PR=ピーアール",
        // よく出る語
        "Claude Code=クロードコード",
        "JavaScript=ジャバスクリプト",
        "GitHub=ギットハブ",
        "Git=ギット",
        "Swift=スウィフト",
        "Xcode=エックスコード",
        "iPhone=アイフォーン",
        "iOS=アイオーエス",
        "Mac=マック",
        "Linux=リナックス",
        "Slack=スラック",
        "Terraform=テラフォーム",
        "JSON=ジェイソン",
        "YAML=ヤムル",
        "OK=オーケー",
        "Haas=ハース",
        "Qwen=クウェン",
        "Irodori=イロドリ",
        "speech.cpp=スピーチシーピーピー",
        "commit=コミット",
        "push=プッシュ",
        "merge=マージ",
        "branch=ブランチ",
        "review=レビュー",
        "issue=イシュー",
        "test=テスト",
        "build=ビルド",
        "deploy=デプロイ",
        "server=サーバー",
        "listen=リッスン",
        "speak=スピーク",
    ]

    static let letters: [Character: String] = [
        "A": "エー", "B": "ビー", "C": "シー", "D": "ディー", "E": "イー", "F": "エフ", "G": "ジー",
        "H": "エイチ", "I": "アイ", "J": "ジェー", "K": "ケー", "L": "エル", "M": "エム", "N": "エヌ",
        "O": "オー", "P": "ピー", "Q": "キュー", "R": "アール", "S": "エス", "T": "ティー", "U": "ユー",
        "V": "ブイ", "W": "ダブリュー", "X": "エックス", "Y": "ワイ", "Z": "ゼット",
    ]

    /// 既定と readings.txt を合わせた (表記, 読み) の一覧。長い表記が先。
    public static func entries(fileText: String?) -> [(String, String)] {
        Vocabulary.merge(builtIn: builtIn, fileText: fileText).compactMap { line in
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].isEmpty else { return nil }
            let reading = parts[1].split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            guard !reading.isEmpty else { return nil }
            return (parts[0], reading)
        }
        .sorted { $0.0.count > $1.0.count }
    }

    public static func load(from url: URL = TalkPaths.readingsFile) -> [(String, String)] {
        entries(fileText: try? String(contentsOf: url, encoding: .utf8))
    }

    /// 英字を読みに置き換える。
    public static func apply(_ text: String, entries: [(String, String)], latin: LatinMode) -> String {
        let chars = Array(text)
        let keys = entries.map { (Array($0.0.lowercased()), $0.1) }
        var out = ""
        var i = 0
        func isLetter(_ c: Character) -> Bool { c.isASCII && c.isLetter }
        while i < chars.count {
            let c = chars[i]
            // 英字の連なりの頭でだけ照合する (前が英字なら語の途中)。数字は区切りとみなす (Qwen3 → クウェン3)。
            guard isLetter(c) || (c.isASCII && c.isNumber), i == 0 || !isLetter(chars[i - 1]) else {
                out.append(c)
                i += 1
                continue
            }
            var matched = false
            for (key, reading) in keys where i + key.count <= chars.count {
                var ok = true
                for (j, k) in key.enumerated() where Character(chars[i + j].lowercased()) != k {
                    ok = false
                    break
                }
                guard ok else { continue }
                let end = i + key.count
                // 語の途中で切らない (英字が続くなら当てない)。
                if end < chars.count, isLetter(chars[end]), isLetter(key.last!) { continue }
                out += reading
                i = end
                matched = true
                break
            }
            if matched { continue }
            if isLetter(c) {
                var end = i
                while end < chars.count, isLetter(chars[end]) { end += 1 }
                out += spellIfNeeded(String(chars[i..<end]), latin: latin)
                i = end
                continue
            }
            out.append(c)
            i += 1
        }
        return out
    }

    static func spellIfNeeded(_ word: String, latin: LatinMode) -> String {
        let spell: Bool
        switch latin {
        case .keep: spell = false
        case .spell: spell = true
        case .auto: spell = word.count >= 2 && word.count <= 6 && word.allSatisfy { $0.isUppercase }
        }
        guard spell else { return word }
        return word.map { letters[Character($0.uppercased())] ?? String($0) }.joined()
    }

    /// 設定と辞書ファイルを読んで置き換える。
    public static func prepare(_ text: String, settings: DirectSettings, url: URL = TalkPaths.readingsFile) -> String {
        apply(text, entries: load(from: url), latin: LatinMode(rawValue: settings.ttsLatin.lowercased()) ?? .auto)
    }
}
