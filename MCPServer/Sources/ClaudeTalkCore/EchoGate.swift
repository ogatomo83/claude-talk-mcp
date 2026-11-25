//
//  EchoGate.swift
//  ClaudeTalkCore
//
//  読み上げ中の割り込み判定を「人の声だけ」に寄せるための判定 (段 b の層 2)。
//
//  speech serve の VAD (Silero) が「話し始めた」と言った後、その発話が人の声か、自分の読み上げの残り (エコー) かを
//  マイクの音と読み上げの参照信号 (実際に鳴らした音) から決める。
//    1. 10ms ごとの音の大きさ (dBFS) をマイクと参照信号で求める
//    2. 参照信号が何 ms 遅れてマイクに入るか (lag) を、大きさの並びの相関が一番高い所で決める
//    3. 話し始めより前 (読み上げだけが鳴っていた間) の「マイク − 参照信号」の dB から、
//       エコーがどれだけの大きさで戻るか (erl) を測る。VPIO の収束・スピーカーの音量・ヘッドホンかどうかに自分で合う
//    4. 判定の窓 (話し始めの後) で、マイクが「参照信号 + erl + excessDb」より大きく、かつ minVoiceDb より大きい
//       10ms の割合が voicedRatio 以上なら人の声
//  読み上げが鳴っていない時 (参照信号が静か) は、大きさ (minVoiceDb) だけで決まる。
//

import Foundation

public struct EchoGateConfig: Codable, Equatable, Sendable {
    /// false なら判定しない (VAD の話し始め + bargeInMs だけで止める。段 a と同じ)。
    public var enabled: Bool = true
    /// 人の声とみなす最小の大きさ (10ms の RMS、dBFS)。VPIO の後の部屋の音は -64 前後、残りのエコーは -60〜-71。
    public var minVoiceDb: Double = -50
    /// マイクが「予想されるエコーの大きさ」をこの dB 以上超えた 10ms を声とみなす。
    public var excessDb: Double = 10
    /// 判定の窓のうち、声とみなした 10ms の割合がこれ以上なら人の声。
    public var voicedRatio: Double = 0.4
    /// 参照信号がこれより大きい 10ms を「鳴っている」とみなす (dBFS)。
    public var refActiveDb: Double = -50
    /// 参照信号がマイクに入るまでの遅れを探す範囲 (ms)。
    public var maxLagMs: Int = 250
    /// 戻りの大きさ (マイク − 参照信号) を測る、話し始めより前の長さ (ms)。
    public var historyMs: Int = 4000
    /// 戻りの大きさの代表値に使う割合 (0.5 = 中央値。高いほどエコーを大きめに見積もり止まりにくいが、
    /// 履歴にユーザーの前の発話が入ると見積もりが大きくなりすぎる。録音で 0.9 は人の声を 2〜3 割逃した)。
    public var erlPercentile: Double = 0.5
    /// 戻りの大きさを測れるだけの履歴が無い時の値 (dB)。大きめ (止まりにくい側) にしておく。
    public var priorErlDb: Double = 0
    /// 履歴として最低これだけ「参照信号が鳴っていた」10ms が要る。
    public var minHistoryFrames: Int = 30
    /// 1 回目の判定で人の声と言えなかった時、この ms まで 100ms ごとに見直す (窓は直近の bargeInMs)。-1 は発話が続く間ずっと、0 は見直さない。
    public var recheckMs: Int = -1

    public init() {}

    enum CodingKeys: String, CodingKey {
        case enabled, minVoiceDb, excessDb, voicedRatio, refActiveDb, maxLagMs, historyMs, erlPercentile
        case priorErlDb, minHistoryFrames, recheckMs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = EchoGateConfig()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        minVoiceDb = try c.decodeIfPresent(Double.self, forKey: .minVoiceDb) ?? d.minVoiceDb
        excessDb = try c.decodeIfPresent(Double.self, forKey: .excessDb) ?? d.excessDb
        voicedRatio = try c.decodeIfPresent(Double.self, forKey: .voicedRatio) ?? d.voicedRatio
        refActiveDb = try c.decodeIfPresent(Double.self, forKey: .refActiveDb) ?? d.refActiveDb
        maxLagMs = try c.decodeIfPresent(Int.self, forKey: .maxLagMs) ?? d.maxLagMs
        historyMs = try c.decodeIfPresent(Int.self, forKey: .historyMs) ?? d.historyMs
        erlPercentile = try c.decodeIfPresent(Double.self, forKey: .erlPercentile) ?? d.erlPercentile
        priorErlDb = try c.decodeIfPresent(Double.self, forKey: .priorErlDb) ?? d.priorErlDb
        minHistoryFrames = try c.decodeIfPresent(Int.self, forKey: .minHistoryFrames) ?? d.minHistoryFrames
        recheckMs = try c.decodeIfPresent(Int.self, forKey: .recheckMs) ?? d.recheckMs
    }
}

public enum EchoGate {
    public static let frameMs = 10
    public static var frameSamples: Int { PCM.sampleRate * frameMs / 1000 }
    static let floorDb = -100.0

    public struct Verdict: Sendable, Equatable {
        public var isVoice: Bool
        public var frames: Int
        public var voicedFrames: Int
        /// 窓のマイク / 参照信号 (lag 後) の大きさの中央値 (dBFS)
        public var micDb: Double
        public var refDb: Double
        /// 推定した戻りの大きさ (マイク − 参照信号、dB) と、測れたか
        public var erlDb: Double
        public var erlMeasured: Bool
        public var lagMs: Int
        /// 窓の中のマイクと参照信号の大きさの並びの相関 (-1〜1。エコーなら高い)
        public var corr: Double

        public var ratio: Double { frames > 0 ? Double(voicedFrames) / Double(frames) : 0 }

        public var fields: [String: Any] {
            func r(_ v: Double) -> Double { (v * 10).rounded() / 10 }
            return ["voice": isVoice, "frames": frames, "voiced": voicedFrames, "ratio": r(ratio * 10) / 10,
                    "mic_db": r(micDb), "ref_db": r(refDb), "erl_db": r(erlDb), "erl_measured": erlMeasured,
                    "lag_ms": lagMs, "corr": (corr * 100).rounded() / 100]
        }
    }

    /// 10ms ごとの RMS (dBFS)。
    public static func frameDb(_ s: [Int16]) -> [Double] {
        let n = frameSamples
        var out: [Double] = []
        out.reserveCapacity(s.count / n)
        var i = 0
        while i + n <= s.count {
            var e = 0.0
            for k in i..<(i + n) { let v = Double(s[k]) / 32768; e += v * v }
            out.append(max(floorDb, 10 * log10(e / Double(n) + 1e-12)))
            i += n
        }
        return out
    }

    static func pearson(_ a: ArraySlice<Double>, _ b: ArraySlice<Double>) -> Double {
        let n = min(a.count, b.count)
        guard n >= 3 else { return 0 }
        let xa = Array(a.prefix(n)), xb = Array(b.prefix(n))
        let ma = xa.reduce(0, +) / Double(n), mb = xb.reduce(0, +) / Double(n)
        var sab = 0.0, saa = 0.0, sbb = 0.0
        for i in 0..<n {
            let da = xa[i] - ma, db = xb[i] - mb
            sab += da * db; saa += da * da; sbb += db * db
        }
        guard saa > 1e-9, sbb > 1e-9 else { return 0 }
        return sab / (saa * sbb).squareRoot()
    }

    static func median(_ v: [Double]) -> Double {
        guard !v.isEmpty else { return floorDb }
        let s = v.sorted()
        return s[s.count / 2]
    }

    static func percentile(_ v: [Double], _ p: Double) -> Double {
        let s = v.sorted()
        let i = min(s.count - 1, max(0, Int((Double(s.count - 1) * p).rounded())))
        return s[i]
    }

    /// mic と ref は同じ時間軸 (index 0 が同じ時刻、24kHz mono)。`judgeFrom` (サンプル位置) から後が判定の窓、
    /// それより前が履歴 (読み上げだけが鳴っていた間として戻りの大きさを測る)。
    public static func evaluate(mic: [Int16], ref: [Int16], judgeFrom: Int, config c: EchoGateConfig) -> Verdict {
        let m = frameDb(mic)
        let r = frameDb(ref)
        let nf = min(m.count, r.count)
        let jf = min(nf, max(0, judgeFrom / frameSamples))
        let maxLag = max(0, c.maxLagMs / frameMs)
        // 参照信号の遅れ: 鳴っていた区間で、マイクとの大きさの並びの相関が一番高い lag。
        let histStart = max(0, jf - c.historyMs / frameMs)
        func lagged(_ f: Int, _ lag: Int) -> Double {
            // 前後 1 フレームの最大 (遅れの細かいずれと、音の立ち上がりの差を吸収する)
            var best = floorDb
            for k in (f - lag - 1)...(f - lag + 1) where k >= 0 && k < r.count { best = max(best, r[k]) }
            return best
        }
        var bestLag = 0
        var bestCorr = -2.0
        let lagRange = histStart..<jf
        let activeHist = lagRange.filter { r[$0] > c.refActiveDb }.count
        let corrRange = activeHist >= c.minHistoryFrames ? lagRange : 0..<nf
        if corrRange.count >= 3 {
            for lag in 0...maxLag {
                var a: [Double] = [], b: [Double] = []
                for f in corrRange where f - lag >= 0 {
                    a.append(m[f]); b.append(r[f - lag])
                }
                let cc = pearson(a[...], b[...])
                if cc > bestCorr { bestCorr = cc; bestLag = lag }
            }
        }
        // 戻りの大きさ: 履歴のうち参照信号 (lag 後) が鳴っていた 10ms の「マイク − 参照信号」。
        var diffs: [Double] = []
        for f in lagRange {
            let rv = lagged(f, bestLag)
            if rv > c.refActiveDb { diffs.append(m[f] - rv) }
        }
        let measured = diffs.count >= c.minHistoryFrames
        let erl = measured ? percentile(diffs, c.erlPercentile) : c.priorErlDb
        // 判定の窓
        var voiced = 0
        var wm: [Double] = [], wr: [Double] = []
        for f in jf..<nf {
            let mv = m[f]
            let rv = lagged(f, bestLag)
            wm.append(mv); wr.append(rv)
            guard mv >= c.minVoiceDb else { continue }
            if rv <= c.refActiveDb || mv >= rv + erl + c.excessDb { voiced += 1 }
        }
        let frames = max(0, nf - jf)
        let ratio = frames > 0 ? Double(voiced) / Double(frames) : 0
        return Verdict(isVoice: frames > 0 && ratio >= c.voicedRatio, frames: frames, voicedFrames: voiced,
                       micDb: median(wm), refDb: median(wr), erlDb: erl, erlMeasured: measured,
                       lagMs: bestLag * frameMs, corr: pearson(wm[...], wr[...]))
    }
}

public extension AudioRing {
    /// [from, to) の音 (24kHz mono Int16)。残っていない所・届いていない所は 0。
    func samples(from: UInt64, to: UInt64) -> [Int16] {
        guard to > from else { return [] }
        let count = PCM.bytes(nanoseconds: to - from) / 2
        var out = [Int16](repeating: 0, count: count)
        for p in snapshot() where p.end > from && p.start < to {
            p.data.withUnsafeBytes { raw in
                let s = raw.bindMemory(to: Int16.self)
                // p の各サンプルの位置 (out の index)
                let offset: Int
                if p.start >= from {
                    offset = PCM.bytes(nanoseconds: p.start - from) / 2
                } else {
                    offset = -(PCM.bytes(nanoseconds: from - p.start) / 2)
                }
                let lo = max(0, -offset), hi = min(s.count, count - offset)
                if lo < hi { for i in lo..<hi { out[offset + i] = s[i] } }
            }
        }
        return out
    }
}
