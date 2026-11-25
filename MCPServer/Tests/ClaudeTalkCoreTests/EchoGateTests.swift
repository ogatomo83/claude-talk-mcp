import XCTest
@testable import ClaudeTalkCore

/// 割り込みの判定 (段 b の層 2) と、その周りの部品 (参照信号の読み出し・設定・エコーの模擬)。
final class EchoGateTests: XCTestCase {
    static let sr = PCM.sampleRate

    /// 声っぽい音: 200Hz + 倍音を 4Hz で揺らす (音節の強弱)。dBFS は大体の RMS。
    static func voice(seconds: Double, db: Double, f0: Double = 200, seed: Double = 0) -> [Int16] {
        let n = Int(seconds * Double(sr))
        let amp = pow(10, db / 20) * 1.41 * 32767
        return (0..<n).map { i in
            let t = Double(i) / Double(sr)
            let env = 0.55 + 0.45 * sin(2 * .pi * 4 * t + seed)
            let v = (sin(2 * .pi * f0 * t) + 0.5 * sin(2 * .pi * 2 * f0 * t + seed)) / 1.25 * env
            return Int16(max(-32768, min(32767, v * amp)))
        }
    }

    static func scaled(_ s: [Int16], db: Double) -> [Int16] {
        let g = pow(10, db / 20)
        return s.map { Int16(max(-32768, min(32767, Double($0) * g))) }
    }

    static func delayed(_ s: [Int16], ms: Int) -> [Int16] {
        let d = ms * sr / 1000
        return [Int16](repeating: 0, count: d) + s.prefix(s.count - d)
    }

    static func add(_ a: [Int16], _ b: [Int16]) -> [Int16] {
        (0..<min(a.count, b.count)).map { Int16(max(-32768, min(32767, Int(a[$0]) + Int(b[$0])))) }
    }

    static func noise(_ n: Int, db: Double) -> [Int16] {
        let amp = pow(10, db / 20) * 1.7 * 32767
        var g = SystemRandomNumberGenerator()
        return (0..<n).map { _ in Int16(Double.random(in: -1...1, using: &g) * amp) }
    }

    let cfg = EchoGateConfig()

    /// 読み上げ (参照信号) が -20 dBFS、マイクにはそれが -40dB 小さく 60ms 遅れて入る (VPIO 後の残り)。
    func testResidualEchoAloneIsNotVoice() {
        let ref = Self.voice(seconds: 4, db: -20)
        let mic = Self.add(Self.scaled(Self.delayed(ref, ms: 60), db: -40), Self.noise(ref.count, db: -66))
        let v = EchoGate.evaluate(mic: mic, ref: ref, judgeFrom: 3 * Self.sr, config: cfg)
        XCTAssertFalse(v.isVoice, "\(v)")
        XCTAssertTrue(v.erlMeasured)
        XCTAssertEqual(Double(v.lagMs), 60, accuracy: 20)
        XCTAssertLessThan(v.erlDb, -30)
    }

    /// 同じ残りのエコーに、人の声 (-35 dBFS、別の高さ) が重なる。
    func testVoiceOverResidualEchoIsVoice() {
        let ref = Self.voice(seconds: 4, db: -20)
        var mic = Self.add(Self.scaled(Self.delayed(ref, ms: 60), db: -40), Self.noise(ref.count, db: -66))
        let user = Self.voice(seconds: 1, db: -35, f0: 130, seed: 1.3)
        let at = 3 * Self.sr
        for i in 0..<user.count { mic[at + i] = Int16(max(-32768, min(32767, Int(mic[at + i]) + Int(user[i])))) }
        let v = EchoGate.evaluate(mic: Array(mic.prefix(at + Self.sr / 3)), ref: Array(ref.prefix(at + Self.sr / 3)),
                                  judgeFrom: at, config: cfg)
        XCTAssertTrue(v.isVoice, "\(v)")
    }

    /// VPIO なし (スピーカーの音がほぼそのまま戻る: -12dB) でも、戻りの大きさを測るので残りだけでは止まらない。
    func testLoudEchoWithoutVPIsNotVoice() {
        let ref = Self.voice(seconds: 4, db: -20)
        let mic = Self.add(Self.scaled(Self.delayed(ref, ms: 40), db: -12), Self.noise(ref.count, db: -60))
        let v = EchoGate.evaluate(mic: mic, ref: ref, judgeFrom: 3 * Self.sr, config: cfg)
        XCTAssertFalse(v.isVoice, "\(v)")
    }

    /// 読み上げが鳴っていない (参照信号が無音) 時は、大きさだけで決まる。
    func testNoReferenceUsesLevelOnly() {
        let n = 2 * Self.sr
        let ref = [Int16](repeating: 0, count: n)
        let loud = Self.add(Self.noise(n, db: -66), [Int16](repeating: 0, count: Self.sr) + Self.voice(seconds: 1, db: -38))
        XCTAssertTrue(EchoGate.evaluate(mic: loud, ref: ref, judgeFrom: Self.sr, config: cfg).isVoice)
        let quiet = Self.add(Self.noise(n, db: -66), [Int16](repeating: 0, count: Self.sr) + Self.voice(seconds: 1, db: -60))
        XCTAssertFalse(EchoGate.evaluate(mic: quiet, ref: ref, judgeFrom: Self.sr, config: cfg).isVoice)
    }

    /// 履歴が無い (読み上げの最初) 時は priorErlDb (0dB = 参照信号と同じ大きさのエコー) を仮定して止まりにくくする。
    func testNoHistoryIsConservative() {
        let ref = Self.voice(seconds: 0.4, db: -20)
        let mic = Self.scaled(Self.delayed(ref, ms: 30), db: -15)
        let v = EchoGate.evaluate(mic: mic, ref: ref, judgeFrom: 0, config: cfg)
        XCTAssertFalse(v.erlMeasured)
        XCTAssertFalse(v.isVoice, "\(v)")
    }

    func testRingSamplesFillsGapsWithZero() {
        let ring = AudioRing(retainSeconds: 10)
        let t0: UInt64 = 1_000_000_000
        let a = Data([Int16](repeating: 100, count: 240).withUnsafeBytes { Data($0) })   // 10ms
        ring.append(AudioPiece(start: t0, data: a))
        ring.append(AudioPiece(start: t0 + 20_000_000, data: a))                          // 10ms の隙間の後
        let s = ring.samples(from: t0 - 5_000_000, to: t0 + 30_000_000)
        XCTAssertEqual(s.count, 35 * 24)
        XCTAssertEqual(s[0], 0)                // 前 5ms は無い
        XCTAssertEqual(s[5 * 24], 100)
        XCTAssertEqual(s[20 * 24], 0)          // 隙間
        XCTAssertEqual(s[30 * 24], 100)
    }

    func testVoiceSettingsLayersDecodeAndDefaults() throws {
        let d = VoiceSettings()
        XCTAssertTrue(d.sharedEngine)
        XCTAssertTrue(d.voiceProcessing)
        XCTAssertFalse(d.vpAGC)
        XCTAssertEqual(d.vpDucking, "min")
        XCTAssertTrue(d.echoGate.enabled)
        XCTAssertTrue(d.echoFilter)
        XCTAssertEqual(d.bargeInMs, 300)
        let j = #"{"voiceProcessing": false, "echoGate": {"enabled": false, "minVoiceDb": -55}, "echoFilter": false}"#
        let v = try JSONDecoder().decode(VoiceSettings.self, from: Data(j.utf8))
        XCTAssertFalse(v.voiceProcessing)
        XCTAssertFalse(v.echoGate.enabled)
        XCTAssertEqual(v.echoGate.minVoiceDb, -55)
        XCTAssertEqual(v.echoGate.excessDb, EchoGateConfig().excessDb)   // 書いていない所は既定
        XCTAssertFalse(v.echoFilter)
        XCTAssertTrue(v.sharedEngine)
        XCTAssertFalse(v.audioOptions.voiceProcessing)
    }

    func testParseEchoSpec() {
        XCTAssertEqual(ScriptedWavInput.parseEcho("-35@150")?.gainDb, -35)
        XCTAssertEqual(ScriptedWavInput.parseEcho("-35@150")?.delayMs, 150)
        XCTAssertEqual(ScriptedWavInput.parseEcho("-20")?.delayMs, 150)
        XCTAssertNil(ScriptedWavInput.parseEcho(""))
        XCTAssertNil(ScriptedWavInput.parseEcho("x"))
    }
}

final class EchoPrefixTests: XCTestCase {
    func testStripsLeadingEchoClause() {
        let r = EchoFilter.stripEchoPrefix(transcript: "日本の四季のことですね。ちょっと待って、冬のことだけもう少し詳しく教えて",
                                           spoken: "日本の四季のことですね。長くなる", threshold: 0.75)
        XCTAssertEqual(r.removed, "日本の四季のことですね。")
        XCTAssertEqual(r.rest, "ちょっと待って、冬のことだけもう少し詳しく教えて")
    }

    func testKeepsUserOnlyTranscript() {
        let r = EchoFilter.stripEchoPrefix(transcript: "はい、それで明日の予定は？", spoken: "今日は晴れです。気温は二十度です。", threshold: 0.75)
        XCTAssertEqual(r.removed, "")
        XCTAssertEqual(r.rest, "はい、それで明日の予定は？")
    }

    func testDisabledWhenThresholdZero() {
        let r = EchoFilter.stripEchoPrefix(transcript: "今日は晴れです。待って", spoken: "今日は晴れです。", threshold: 0)
        XCTAssertEqual(r.rest, "今日は晴れです。待って")
    }
}
