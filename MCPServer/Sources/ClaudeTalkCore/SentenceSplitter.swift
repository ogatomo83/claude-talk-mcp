//
//  SentenceSplitter.swift
//  ClaudeTalkCore
//
//  Claude の text_delta を受けて、読み上げる文に区切る。句点・感嘆符・疑問符・改行で区切り、
//  読み上げに向かない記号 (Markdown の * # ` や箇条書きの頭) を落とす。
//

import Foundation

public struct SentenceSplitter: Sendable {
    private var buffer = ""
    private var emitted = 0
    /// 最初の文だけ、この文字数を超えたら読点 (、) でも区切る。0 で無効。
    public var firstChunkMinChars: Int

    public init(firstChunkMinChars: Int = 0) {
        self.firstChunkMinChars = firstChunkMinChars
    }

    static let enders: Set<Character> = ["。", "！", "？", "!", "?", "\n", "…"]
    /// 文末の後に続けて文に含めるもの (閉じ括弧など)。
    static let trailers: Set<Character> = ["」", "』", "）", ")", "】", "\u{201D}", "\u{2019}", "。", "！", "？", "!", "?", "…"]

    /// delta を足し、区切れた文を返す (読み上げ用に整えたもの。空は返さない)。
    public mutating func feed(_ delta: String) -> [String] {
        buffer += delta
        var out: [String] = []
        while let cut = nextCut() {
            let raw = String(buffer[..<cut])
            buffer = String(buffer[cut...])
            let s = Self.clean(raw)
            if !s.isEmpty { out.append(s); emitted += 1 }
        }
        return out
    }

    /// 残りを全部返す (返事の終わり)。
    public mutating func flush() -> [String] {
        let s = Self.clean(buffer)
        buffer = ""
        if s.isEmpty { return [] }
        emitted += 1
        return [s]
    }

    public mutating func reset() {
        buffer = ""
        emitted = 0
    }

    private func nextCut() -> String.Index? {
        var i = buffer.startIndex
        var count = 0
        while i < buffer.endIndex {
            let ch = buffer[i]
            count += 1
            if Self.enders.contains(ch) {
                var j = buffer.index(after: i)
                while j < buffer.endIndex, Self.trailers.contains(buffer[j]) { j = buffer.index(after: j) }
                // 末尾がまだ続くかもしれない (「。」の後に「」」が来るなど) ので、バッファの最後なら待つ。
                // 改行は待たない。
                if j == buffer.endIndex, ch != "\n" { return nil }
                return j
            }
            if emitted == 0, firstChunkMinChars > 0, count >= firstChunkMinChars, ch == "、" || ch == "," {
                return buffer.index(after: i)
            }
            i = buffer.index(after: i)
        }
        return nil
    }

    /// 読み上げ用に整える: Markdown の記号・箇条書きの頭・余分な空白を落とす。
    public static func clean(_ s: String) -> String {
        var t = s
        for mark in ["**", "__", "`", "#", "*", "~~", ">"] {
            t = t.replacingOccurrences(of: mark, with: "")
        }
        // 行頭の箇条書き (- / ・ / 1. )
        t = t.replacingOccurrences(of: #"(?m)^\s*([-•・]|\d+[.)])\s+"#, with: "", options: .regularExpression)
        // [text](url) → text
        t = t.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: "\n", with: " ")
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        // 記号だけの文 (「。」だけなど) は読まない。
        let meaningful = t.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
        return meaningful ? t : ""
    }
}
