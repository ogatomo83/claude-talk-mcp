import XCTest
@testable import ClaudeTalkCore

/// direct モードの speak の割り込み (T-0035): 設定・返り値・判定の時点・listen への受け渡し・リングでの判定。
final class BargeInTests: XCTestCase {
    // MARK: 設定

    func testBargeInDefaultsOnAndCanBeTurnedOff() throws {
        XCTAssertTrue(DirectSettings().bargeIn.enabled)
        XCTAssertEqual(DirectSettings().bargeIn.bargeInMs, 300)
        XCTAssertFalse(DirectSettings().bargeIn.vpAGC)
        let off = try JSONDecoder().decode(DirectSettings.self, from: Data(#"{"bargeIn": {"enabled": false}}"#.utf8))
        XCTAssertFalse(off.bargeIn.enabled)
        XCTAssertEqual(off.bargeIn.bargeInMs, 300, "書かなかった項目は既定")
        let partial = try JSONDecoder().decode(DirectSettings.self,
                                               from: Data(#"{"bargeIn": {"bargeInMs": 400, "echoGate": {"minVoiceDb": -55}}}"#.utf8))
        XCTAssertTrue(partial.bargeIn.enabled)
        XCTAssertEqual(partial.bargeIn.bargeInMs, 400)
        XCTAssertEqual(partial.bargeIn.echoGate.minVoiceDb, -55)
        XCTAssertEqual(partial.bargeIn.echoGate.excessDb, 10)
        // ほかの項目の読み方は変わらない
        let other = try JSONDecoder().decode(DirectSettings.self, from: Data(#"{"silenceMs": 700}"#.utf8))
        XCTAssertEqual(other.silenceMs, 700)
        XCTAssertTrue(other.bargeIn.enabled)
    }

    // MARK: 返り値

    func testToolTextKeepsDoneAndStopped() {
        XCTAssertEqual(SpeakOutcome(finished: true).toolText, "done")
        XCTAssertEqual(SpeakOutcome(finished: false).toolText, "stopped")
        XCTAssertEqual(SpeakOutcome(finished: true, userStartedNearEnd: true).toolText, "done")
    }

    func testToolTextInterrupted() {
        let o = SpeakOutcome(finished: false, interrupted: true, heardText: "今日は日本の四季について",
                             totalChars: 50, playedSeconds: 2.34)
        let lines = o.toolText.components(separatedBy: "\n")
        XCTAssertEqual(lines.first, "interrupted")
        XCTAssertTrue(o.toolText.contains("「今日は日本の四季について」"))
        XCTAssertTrue(o.toolText.contains("(12/50 文字、2.3 秒)"))
        XCTAssertTrue(o.toolText.contains("listen"))
        // 長い時は末尾 40 文字
        let long = SpeakOutcome(finished: false, interrupted: true, heardText: String(repeating: "あ", count: 30) +
                                String(repeating: "い", count: 40), totalChars: 100)
        XCTAssertTrue(long.toolText.contains("「…" + String(repeating: "い", count: 40) + "」"))
    }

    // MARK: 判定の時点

    static let ms: UInt64 = 1_000_000

    func testShortUtteranceIsNeverJudged() {
        var t = BargeInTracker(bargeInMs: 300, recheckMs: -1)
        t.started("a", audioStart: 1000 * Self.ms)
        XCTAssertNil(t.nextDue(now: 1200 * Self.ms), "まだ 300ms たっていない")
        t.stopped("a")
        XCTAssertNil(t.nextDue(now: 5000 * Self.ms), "話し終えた発話 (相づち) は判定しない")
    }

    func testJudgesAtAudioTimeAndRechecksEvery100ms() {
        var t = BargeInTracker(bargeInMs: 300, recheckMs: -1)
        t.started("a", audioStart: 1000 * Self.ms)
        // speech_started が遅れて届き、音は 1850ms まで届いている: 1300, 1400, … , 1800 の時点を順に判定する
        var points: [UInt64] = []
        while let d = t.nextDue(now: 1850 * Self.ms) {
            XCTAssertEqual(d.item, "a")
            XCTAssertEqual(d.audioStart, 1000 * Self.ms)
            points.append(d.at / Self.ms)
            t.rejected("a")
        }
        XCTAssertEqual(points, [1300, 1400, 1500, 1600, 1700, 1800])
        XCTAssertEqual(t.open["a"]?.rejections, 6)
    }

    func testRecheckLimit() {
        var t = BargeInTracker(bargeInMs: 300, recheckMs: 0)
        t.started("a", audioStart: 0)
        XCTAssertNotNil(t.nextDue(now: 300 * Self.ms))
        t.rejected("a")
        XCTAssertNil(t.nextDue(now: 10_000 * Self.ms), "recheckMs 0 は見直さない")
        var u = BargeInTracker(bargeInMs: 300, recheckMs: 200)
        u.started("b", audioStart: 0)
        var n = 0
        while u.nextDue(now: 10_000 * Self.ms) != nil { u.rejected("b"); n += 1 }
        XCTAssertEqual(n, 3, "300 / 400 / 500 の 3 回")
    }

    func testHandoffStartIncludesPrecedingUtterance() {
        var t = BargeInTracker(bargeInMs: 300, recheckMs: -1)
        t.started("echo", audioStart: 100 * Self.ms)      // 読み上げの始まりの残り (遠い)
        t.stopped("echo")
        t.started("stop", audioStart: 8000 * Self.ms)     // 「ストップ」(短くて止めなかった)
        t.stopped("stop")
        t.started("more", audioStart: 9100 * Self.ms)     // 続けて話した (これで止めた)
        XCTAssertEqual(t.handoffStart(for: 9100 * Self.ms, gapNs: 2000 * Self.ms), 8000 * Self.ms)
        XCTAssertEqual(t.handoffStart(for: 9100 * Self.ms, gapNs: 500 * Self.ms), 9100 * Self.ms)
        XCTAssertEqual(t.earliestOpenAudioStart, 9100 * Self.ms)
    }

    // MARK: listen の始点

    func testPrerollPlanUsesHandoffWithoutTailGuard() {
        let s = DirectSettings()
        let speechStart = 10_000 * Self.ms
        let stopAt = 10_800 * Self.ms
        let listenAt = 13_000 * Self.ms
        let p = DirectEngine.prerollPlan(listenAt: listenAt, speakEndAt: stopAt, lastSpeakEnd: stopAt,
                                         handoff: (speechStart, stopAt), settings: s)
        XCTAssertTrue(p.handoff)
        XCTAssertEqual(p.since, speechStart - 200 * Self.ms, "話し始めの 200ms 前から")
        XCTAssertEqual(p.guardedMs, 0)
    }

    func testPrerollPlanWithoutHandoffIsUnchanged() {
        let s = DirectSettings()
        let end = 10_000 * Self.ms
        // 読み上げの終わりの直後に listen: 始点は終わり + 150ms (tail guard)
        let p = DirectEngine.prerollPlan(listenAt: end + 50 * Self.ms, speakEndAt: end, lastSpeakEnd: end,
                                         handoff: nil, settings: s)
        XCTAssertFalse(p.handoff)
        XCTAssertEqual(p.since, end + 150 * Self.ms)
        // 2 秒後の listen: 始点は読み上げの終わり + 150ms (プリロール)
        let q = DirectEngine.prerollPlan(listenAt: end + 2000 * Self.ms, speakEndAt: end, lastSpeakEnd: end,
                                         handoff: nil, settings: s)
        XCTAssertEqual(q.since, end + 150 * Self.ms)
        // speak が無い: listen の 0.3 秒前から
        let r = DirectEngine.prerollPlan(listenAt: end, speakEndAt: nil, lastSpeakEnd: nil, handoff: nil, settings: s)
        XCTAssertEqual(r.since, end - 300 * Self.ms)
    }

    func testPrerollPlanDropsStaleHandoff() {
        let s = DirectSettings()
        let stopAt = 10_000 * Self.ms
        let p = DirectEngine.prerollPlan(listenAt: stopAt + 20_000 * Self.ms, speakEndAt: stopAt, lastSpeakEnd: stopAt,
                                         handoff: (stopAt - 500 * Self.ms, stopAt), settings: s)
        XCTAssertFalse(p.handoff, "handoffMaxSeconds (14 秒) を過ぎたら渡さない")
    }

    // MARK: リングでの判定 (EchoGate と同じ判定を、録音と参照信号のリングから)

    static func fill(_ ring: AudioRing, _ s: [Int16], at t0: UInt64) {
        let chunk = PCM.sampleRate / 25   // 40ms
        var i = 0
        while i < s.count {
            let n = min(chunk, s.count - i)
            let piece = Array(s[i..<(i + n)])
            ring.append(AudioPiece(start: t0 + PCM.nanoseconds(bytes: i * 2), data: piece.withUnsafeBytes { Data($0) }))
            i += n
        }
    }

    func testEvaluateRingsSeparatesVoiceFromResidualEcho() {
        let sr = PCM.sampleRate
        let ref = EchoGateTests.voice(seconds: 5, db: -20)
        let echo = EchoGateTests.add(EchoGateTests.scaled(EchoGateTests.delayed(ref, ms: 60), db: -40),
                                     EchoGateTests.noise(ref.count, db: -66))
        let user = EchoGateTests.voice(seconds: 1, db: -35, f0: 130, seed: 1.3)
        var withUser = echo
        let at = 3 * sr
        for i in 0..<user.count { withUser[at + i] = Int16(max(-32768, min(32767, Int(withUser[at + i]) + Int(user[i])))) }
        let t0: UInt64 = 100_000 * Self.ms
        let userStart = t0 + 3000 * Self.ms
        for (mic, expectVoice) in [(echo, false), (withUser, true)] {
            let micRing = AudioRing(), refRing = AudioRing()
            Self.fill(micRing, mic, at: t0)
            Self.fill(refRing, ref, at: t0)
            let v = EchoGate.evaluateRings(mic: micRing, reference: refRing, itemAudioStart: userStart,
                                           now: userStart + 400 * Self.ms, bargeInMs: 300, config: EchoGateConfig())
            XCTAssertEqual(v.isVoice, expectVoice, "\(v)")
            XCTAssertTrue(v.erlMeasured)
        }
    }

    // MARK: テスト用の再生 (音を出さない)

    func testWavReferencePlaybackFinishAndStop() async {
        let pcm = Data(count: PCM.bytesPerSecond / 5)   // 0.2 秒
        let ring = AudioRing()
        let a = WavReferencePlayback(pcm: pcm, reference: ring)
        a.enqueue("あいうえお")
        let done = await a.finish()
        XCTAssertTrue(done)
        XCTAssertEqual(a.progress.heardText, "あいうえお")
        XCTAssertGreaterThan(ring.stats.bytes, PCM.bytesPerSecond / 6)

        let long = WavReferencePlayback(pcm: Data(count: PCM.bytesPerSecond * 4), reference: AudioRing())
        long.enqueue("一二三四五六七八九十")
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let p = long.stop()
        let finished = await long.finish()
        XCTAssertFalse(finished)
        XCTAssertGreaterThan(p.heardText.count, 0)
        XCTAssertLessThan(p.heardText.count, 10, "\(p)")
        XCTAssertEqual(p.playedSeconds, 1.0, accuracy: 0.3)
    }
}
