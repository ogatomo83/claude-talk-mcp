//
//  EchoFilter.swift
//  ClaudeTalkCore
//
//  direct モードの listen が、直前の読み上げ (speak) の音をマイクで拾って書き起こした時に捨てる判定。
//  エコー除去が無いので、スピーカーの残り音・部屋の響きが「…ぞ。」のように返ってくることがある。
//
//  方式: 書き起こしと直前の読み上げ文を正規化 (NFKC・小文字・カタカナ→ひらがな・記号と空白を除く) し、
//  書き起こしが読み上げ文のどこかの部分と近いか (近似部分一致: 編集距離 / 書き起こしの長さ) を見る。
//  - 読み上げ文の末尾と完全一致 (末尾の伸ばし「ぞー」「ぞう」は 1 文字外して比べる) なら残り音
//  - 1 文字の書き起こしは、末尾と一致した時だけ (「ぞ」など)
//  - 読み (ローマ字、CFStringTokenizer) の末尾一致 (3 文字以上) でも残り音 (漢字・かなの書き分けの違いを吸収)
//  - 2 文字以上は、近似部分一致の一致度 (かな / 4 文字以上なら読みも) が threshold 以上
//  ユーザーが直前の文を言い返す場合と区別するため、呼び出し側は「読み上げの終わりから echoWindowMs 以内に
//  始まった発話」にだけこの判定を使う。
//

import Foundation

public enum EchoFilter {
    public struct Verdict: Equatable, Sendable {
        public let isEcho: Bool
        /// 0〜1。1 は読み上げ文の部分と完全一致。
        public let score: Double
        public let reason: String
    }

    /// 比べるための正規化。
    public static func normalize(_ s: String) -> [Character] {
        let folded = s.precomposedStringWithCompatibilityMapping.lowercased()
        var out: [Character] = []
        for scalar in folded.unicodeScalars {
            let props = scalar.properties
            guard props.isAlphabetic || props.numericType != nil else { continue }
            var v = scalar.value
            // カタカナ (ァ〜ヶ) → ひらがな
            if (0x30A1...0x30F6).contains(v) { v -= 0x60 }
            if let u = Unicode.Scalar(v) { out.append(Character(u)) }
        }
        return out
    }

    /// 書き起こし `transcript` が、読み上げた文 `spoken` の音を拾ったものか。
    public static func judge(transcript: String, spoken: String, threshold: Double) -> Verdict {
        let t = normalize(transcript)
        let s = normalize(spoken)
        guard !t.isEmpty, !s.isEmpty, threshold > 0 else { return Verdict(isEcho: false, score: 0, reason: "none") }
        // 末尾の伸ばし (「ぞー」「ぞう」) を外しても読み上げの末尾と一致すれば、残り音とみなす。
        for cand in [t, stripElongation(t)] where !cand.isEmpty && s.count >= cand.count {
            if Array(s.suffix(cand.count)) == cand {
                return Verdict(isEcho: true, score: 1, reason: cand.count == t.count ? "suffix" : "suffix_elongated")
            }
        }
        // 読み (ローマ字) でも比べる: 書き起こしが漢字・かな・ローマ字のどれで来ても揃える (「行くぞ」と「…しておくぞ」)。
        let tr = romaji(transcript), sr = romaji(spoken)
        if tr.count >= 3, sr.count >= tr.count, Array(sr.suffix(tr.count)) == tr {
            return Verdict(isEcho: true, score: 1, reason: "suffix_reading")
        }
        if t.count == 1 { return Verdict(isEcho: false, score: 0, reason: "short") }
        let score = similarity(t, s)
        let scoreR = tr.count >= 4 ? similarity(tr, sr) : 0
        let best = max(score, scoreR)
        return Verdict(isEcho: best >= threshold, score: (best * 1000).rounded() / 1000,
                       reason: scoreR > score ? "similar_reading" : "similar")
    }

    /// 1 - (近似部分一致の編集距離 / t の長さ)。
    static func similarity(_ t: [Character], _ s: [Character]) -> Double {
        guard !t.isEmpty, !s.isEmpty else { return 0 }
        return max(0, 1 - Double(substringDistance(t, in: s)) / Double(t.count))
    }

    /// 読みのローマ字 (英数字だけ、小文字)。日本語は CFStringTokenizer の読み、それ以外はそのまま。
    public static func romaji(_ text: String) -> [Character] {
        let str = text.precomposedStringWithCompatibilityMapping as NSString
        let cf = str as CFString
        let tok = CFStringTokenizerCreate(nil, cf, CFRange(location: 0, length: str.length),
                                          kCFStringTokenizerUnitWordBoundary, Locale(identifier: "ja") as CFLocale)
        var out = ""
        var type = CFStringTokenizerAdvanceToNextToken(tok)
        while !type.isEmpty {
            let range = CFStringTokenizerGetCurrentTokenRange(tok)
            if let latin = CFStringTokenizerCopyCurrentTokenAttribute(tok, kCFStringTokenizerAttributeLatinTranscription) as? String {
                out += latin
            } else {
                out += str.substring(with: NSRange(location: range.location, length: range.length))
            }
            type = CFStringTokenizerAdvanceToNextToken(tok)
        }
        let folded = out.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
        return folded.filter { ("a"..."z").contains($0) || ("0"..."9").contains($0) }.map { $0 }
    }

    /// 末尾の伸ばし 1 つ (ー / 〜 / 小書き母音 / 母音のかな) を外す。2 文字以上の時だけ。
    static func stripElongation(_ t: [Character]) -> [Character] {
        guard t.count >= 2, let last = t.last, "ー〜~ぁぃぅぇぉあいうえお".contains(last) else { return t }
        return Array(t.dropLast())
    }

    /// `t` と `s` のどこかの部分文字列との最小編集距離 (semi-global alignment)。
    static func substringDistance(_ t: [Character], in s: [Character]) -> Int {
        // prev[j] = t[0..<i] と、s[..<j] で終わる部分文字列との最小距離
        guard !t.isEmpty else { return 0 }
        guard !s.isEmpty else { return t.count }
        var prev = [Int](repeating: 0, count: s.count + 1)
        var cur = prev
        for i in 1...t.count {
            cur[0] = i
            for j in 1...s.count {
                let sub = prev[j - 1] + (t[i - 1] == s[j - 1] ? 0 : 1)
                cur[j] = min(sub, prev[j] + 1, cur[j - 1] + 1)
            }
            swap(&prev, &cur)
        }
        return prev.min() ?? t.count
    }
}
