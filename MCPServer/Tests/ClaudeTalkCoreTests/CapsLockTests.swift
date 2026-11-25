import XCTest
@testable import ClaudeTalkCore

/// Caps Lock がオンの間だけマイクを入れる (T-0038): 設定・時系列・音の 0 埋め・オフのままの listen。
/// 本物の Caps Lock は切り替えない (読み口を差し替える)。
final class CapsLockTests: XCTestCase {
    final class FakeReader: CapsLockReader, @unchecked Sendable {
        private let lock = NSLock()
        private var on: Bool
        init(_ on: Bool) { self.on = on }
        func set(_ v: Bool) { lock.lock(); on = v; lock.unlock() }
        func isOn() -> Bool { lock.lock(); defer { lock.unlock() }; return on }
    }

    let ms: UInt64 = 1_000_000

    /// 24kHz の音を start から dur ms (全サンプル 1000)。
    func piece(at start: UInt64, ms dur: Int) -> AudioPiece {
        let n = PCM.sampleRate * dur / 1000
        var d = Data(count: n * 2)
        d.withUnsafeMutableBytes { raw in
            let s = raw.bindMemory(to: Int16.self)
            for i in 0..<n { s[i] = 1000 }
        }
        return AudioPiece(start: start, data: d)
    }

    func samples(_ p: AudioPiece) -> [Int16] {
        p.data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    }

    // MARK: 設定

    func testDefaultsOnAndCanBeTurnedOff() throws {
        let d = DirectSettings().capsLock
        XCTAssertTrue(d.enabled)
        XCTAssertEqual(d.pollMs, 50)
        XCTAssertEqual(d.leadMs, 150)
        XCTAssertEqual(d.offMaxWaitSeconds, 300)
        XCTAssertEqual(d.source, "flags")
        let off = try JSONDecoder().decode(DirectSettings.self, from: Data(#"{"capsLock": {"enabled": false}}"#.utf8))
        XCTAssertFalse(off.capsLock.enabled)
        XCTAssertEqual(off.capsLock.pollMs, 50, "書かなかった項目は既定")
        let other = try JSONDecoder().decode(DirectSettings.self, from: Data(#"{"bargeIn": {"enabled": false}}"#.utf8))
        XCTAssertTrue(other.capsLock.enabled, "ほかの項目を書いても既定のまま")
    }

    func testRealReadersNeedNoPermissionAndAgree() {
        // 読むだけ (切り替えない)。どちらも許可なしで読め、同じ状態を返す
        let flags = FlagsCapsLockReader().isOn()
        let hid = HIDCapsLockReader()
        XCTAssertTrue(hid.available, "IOHIDSystem を開けない")
        XCTAssertEqual(flags, hid.isOn())
    }

    // MARK: 時系列

    func testTimelineSpansUsePreviousPollAndLead() {
        var t = CapsLockTimeline(leadNs: 150 * ms)
        let base: UInt64 = 10_000 * ms
        XCTAssertTrue(t.record(on: false, at: base))
        XCTAssertFalse(t.record(on: false, at: base + 50 * ms))
        XCTAssertTrue(t.record(on: true, at: base + 100 * ms))   // 50〜100ms の間に押された
        XCTAssertEqual(t.spans, [.init(from: base + 50 * ms - 150 * ms, to: nil)])
        XCTAssertTrue(t.isOn(at: base - 50 * ms), "前の読みの lead 前からオン")
        XCTAssertFalse(t.isOn(at: base - 150 * ms))
        XCTAssertTrue(t.record(on: false, at: base + 1000 * ms))
        XCTAssertEqual(t.spans.last?.to, base + 1000 * ms)
        XCTAssertTrue(t.isOn(at: base + 999 * ms))
        XCTAssertFalse(t.isOn(at: base + 1000 * ms))
        XCTAssertFalse(t.isOn(at: base + 5000 * ms), "まだ読んでいない時刻は今の状態 (オフ)")
        XCTAssertNil(t.onStart(since: 0), "今オフなら nil")
    }

    func testFirstReadOnStartsWithLead() {
        var t = CapsLockTimeline(leadNs: 150 * ms)
        let base: UInt64 = 10_000 * ms
        t.record(on: true, at: base)
        XCTAssertTrue(t.isOn)
        XCTAssertEqual(t.onStart(since: 0), base - 150 * ms)
        XCTAssertEqual(t.onStart(since: base), base, "since より前から続くオンは since")
    }

    func testMaskZeroesOnlyOffSamplesAndKeepsLength() {
        var t = CapsLockTimeline(leadNs: 0)
        let base: UInt64 = 10_000 * ms
        t.record(on: false, at: base)
        t.record(on: true, at: base + 100 * ms)    // 前の読み base からオン
        t.record(on: false, at: base + 300 * ms)
        t.record(on: false, at: base + 600 * ms)
        // base-100 〜 base+500: オンは [base, base+300)
        let p = piece(at: base - 100 * ms, ms: 600)
        XCTAssertTrue(t.covers(p))
        let m = t.mask(p)
        XCTAssertEqual(m.start, p.start)
        XCTAssertEqual(m.data.count, p.data.count)
        let s = samples(m)
        let per = PCM.sampleRate / 1000
        XCTAssertEqual(s[0], 0)
        XCTAssertEqual(s[100 * per - 1], 0)
        XCTAssertEqual(s[100 * per], 1000)
        XCTAssertEqual(s[400 * per - 1], 1000)
        XCTAssertEqual(s[400 * per], 0)
        XCTAssertEqual(s.last, 0)
        XCTAssertEqual(s.filter { $0 != 0 }.count, 300 * per, "オンの 300ms だけ残る")
    }

    func testMaskAllOnIsUnchangedAndUncoveredUsesCurrentState() {
        var t = CapsLockTimeline(leadNs: 0)
        let base: UInt64 = 10_000 * ms
        t.record(on: true, at: base)
        t.record(on: true, at: base + 50 * ms)
        let p = piece(at: base + 10 * ms, ms: 100)   // 終わり (base+110) はまだ読んでいない
        XCTAssertFalse(t.covers(p))
        XCTAssertEqual(t.mask(p).data, p.data)
    }

    // MARK: 門

    func testGateDisabledPassesEverything() async {
        var s = CapsLockSettings()
        s.enabled = false
        let g = CapsLockGate(settings: s, reader: FakeReader(false))
        g.start()
        XCTAssertTrue(g.isOn)
        let p = piece(at: PCM.now(), ms: 100)
        let m = await g.masked(p)
        XCTAssertEqual(m.data, p.data)
    }

    func testGateMasksWhileOffAndWaitsForPoll() async {
        let reader = FakeReader(false)
        var s = CapsLockSettings()
        s.pollMs = 20
        s.leadMs = 0
        let g = CapsLockGate(settings: s, reader: reader)
        g.start()
        defer { g.stop() }
        XCTAssertFalse(g.isOn)
        let now = PCM.now()
        let off = await g.masked(piece(at: now > 200 * ms ? now - 200 * ms : 0, ms: 100))
        XCTAssertTrue(samples(off).allSatisfy { $0 == 0 }, "オフの間の音は 0")
        reader.set(true)
        // 次の読みでオンに気付く。その後に録った音はそのまま
        for _ in 0..<100 where !g.isOn { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(g.isOn)
        let later = piece(at: PCM.now(), ms: 30)    // まだ読んでいない時刻: 読みが追いつくまで待ってから
        let m = await g.masked(later)
        XCTAssertTrue(samples(m).allSatisfy { $0 == 1000 })
    }

    // MARK: オフのままの listen

    func testListenWhileOffWaitsThenReturnsMarker() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let direct = dir.appendingPathComponent("direct")
        try FileManager.default.createDirectory(at: direct, withIntermediateDirectories: true)
        // speech serve には繋がない (オフの間は Realtime を開けない)。割り込みは切ってテストの入力をそのまま使う
        try #"{"capsLock": {"offMaxWaitSeconds": 1, "pollMs": 20}, "bargeIn": {"enabled": false}, "port": 1}"#
            .write(to: direct.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        setenv("CLAUDE_TALK_HOME", dir.path, 1)
        defer { unsetenv("CLAUDE_TALK_HOME") }
        TimingLog.shared.enabled = true
        let engine = DirectEngine(makeInput: { try WavFileInput(spec: "silent") }, capsReader: FakeReader(false))
        let sw = Stopwatch()
        let text = try await engine.listen(timeout: 0.2, locale: "ja-JP")
        await engine.closeMic(reason: "test")
        XCTAssertTrue(text.hasPrefix(CapsLockListen.marker + "\n"), text)
        XCTAssertGreaterThanOrEqual(sw.ms, 1000, "timeout (0.2 秒) では返らず、offMaxWaitSeconds まで待つ")
        let log = try String(contentsOf: dir.appendingPathComponent("logs/timing.jsonl"), encoding: .utf8)
        XCTAssertTrue(log.contains("\"ev\":\"listen.caps_wait\""), log)
        XCTAssertTrue(log.contains("\"ev\":\"listen.caps_off_return\""), log)
        XCTAssertFalse(log.contains("listen.server_ready"), "オフの間は speech serve を待たない")
    }

    func testListenMarkerText() {
        let t = CapsLockListen.text(waitedSeconds: 299.6)
        XCTAssertEqual(t.split(separator: "\n").first, "caps_lock_off")
        XCTAssertTrue(t.contains("300 秒"))
    }
}

/// 本物の speech serve (:8766) で、Caps Lock の門つきの listen を通しで確かめる。音は出さない (WAV をマイクの代わりに流す)。
/// `CLAUDE_TALK_CAPS_E2E_WAV` (話している WAV) がある時だけ動く。Caps Lock は読み口を差し替える (本物は切り替えない)。
final class CapsLockLiveTests: XCTestCase {
    typealias FakeReader = CapsLockTests.FakeReader

    func setUpHome(_ json: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let direct = dir.appendingPathComponent("direct")
        try FileManager.default.createDirectory(at: direct, withIntermediateDirectories: true)
        try json.write(to: direct.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        setenv("CLAUDE_TALK_HOME", dir.path, 1)
        TimingLog.shared.enabled = true
        return dir
    }

    func wav() throws -> String {
        guard let w = ProcessInfo.processInfo.environment["CLAUDE_TALK_CAPS_E2E_WAV"] else {
            throw XCTSkip("CLAUDE_TALK_CAPS_E2E_WAV が無い")
        }
        return w
    }

    /// オフで待ち、オンになってから話した発話は今まで通り返る (頭も切れない)。
    func testWaitsWhileOffThenHearsAfterOn() async throws {
        let w = try wav()
        let dir = try setUpHome(#"{"capsLock": {"pollMs": 20}, "bargeIn": {"enabled": false}}"#)
        defer { unsetenv("CLAUDE_TALK_HOME") }
        let reader = FakeReader(false)
        let engine = DirectEngine(makeInput: { try WavFileInput(spec: w, trigger: "listen", delayMs: 0) },
                                  capsReader: reader)
        Task { try? await Task.sleep(nanoseconds: 1_500_000_000); reader.set(true) }
        let sw = Stopwatch()
        let text = try await engine.listen(timeout: 10, locale: "ja-JP")
        await engine.closeMic(reason: "test")
        print("caps e2e on-after-wait: \(text) (\(sw.ms) ms)")
        XCTAssertGreaterThanOrEqual(sw.ms, 1500)
        XCTAssertTrue(text.contains("天気"), text)
        XCTAssertTrue(text.hasPrefix("今日"), "頭が切れない: \(text)")
        let log = try String(contentsOf: dir.appendingPathComponent("logs/timing.jsonl"), encoding: .utf8)
        XCTAssertTrue(log.contains("\"ev\":\"listen.caps_on\""), log)
    }

    /// オンで聞き始めても、話す前にオフにした発話は聞かない (0 で送る)。オフのままなら caps_lock_off を返す。
    func testSpeechWhileOffIsNotHeard() async throws {
        let w = try wav()
        let dir = try setUpHome(#"{"capsLock": {"pollMs": 20, "offMaxWaitSeconds": 3}, "bargeIn": {"enabled": false}}"#)
        defer { unsetenv("CLAUDE_TALK_HOME") }
        let reader = FakeReader(true)
        let engine = DirectEngine(makeInput: { try WavFileInput(spec: w, trigger: "listen", delayMs: 800) },
                                  capsReader: reader)
        Task { try? await Task.sleep(nanoseconds: 300_000_000); reader.set(false) }
        let text = try await engine.listen(timeout: 20, locale: "ja-JP")
        await engine.closeMic(reason: "test")
        print("caps e2e off-before-speech: \(text)")
        XCTAssertTrue(text.hasPrefix(CapsLockListen.marker), text)
        XCTAssertFalse(text.contains("天気"))
        let log = try String(contentsOf: dir.appendingPathComponent("logs/timing.jsonl"), encoding: .utf8)
        XCTAssertTrue(log.contains("\"ev\":\"listen.caps_off\""), log)
        XCTAssertFalse(log.contains("\"ev\":\"asr.speech_started\""), "オフの間の発話を VAD が拾っていない")
    }

    /// 話している途中でオフにしたら、そこまでの発話を返す (オフの後の音は送らない)。
    func testOffMidSpeechReturnsWhatWasSaid() async throws {
        let w = try wav()
        _ = try setUpHome(#"{"capsLock": {"pollMs": 20}, "bargeIn": {"enabled": false}}"#)
        defer { unsetenv("CLAUDE_TALK_HOME") }
        let reader = FakeReader(true)
        let engine = DirectEngine(makeInput: { try WavFileInput(spec: w, trigger: "listen", delayMs: 0) },
                                  capsReader: reader)
        // 「今日はいい天気ですね。」の後 (WAV の 1.9 秒あたり) でオフ。listen の前に serve と ws を待つ分を見込む
        Task { try? await Task.sleep(nanoseconds: 2_000_000_000); reader.set(false) }
        let text = try await engine.listen(timeout: 10, locale: "ja-JP")
        await engine.closeMic(reason: "test")
        print("caps e2e off-mid-speech: \(text)")
        XCTAssertTrue(text.hasPrefix("今日"), text)
        XCTAssertFalse(text.contains("散歩"), "オフの後の音は聞かない: \(text)")
    }
}

/// 読み上げ中の割り込みも Caps Lock がオンの時だけ (本物の speech serve の VAD、音は出さない)。
/// `CLAUDE_TALK_CAPS_E2E_WAV` (ユーザーの発話) と `CLAUDE_TALK_CAPS_E2E_REF` (読み上げの音) がある時だけ動く。
final class CapsLockBargeLiveTests: XCTestCase {
    typealias FakeReader = CapsLockTests.FakeReader

    func run(capsOn: Bool) async throws -> SpeakOutcome {
        let env = ProcessInfo.processInfo.environment
        guard let w = env["CLAUDE_TALK_CAPS_E2E_WAV"], let r = env["CLAUDE_TALK_CAPS_E2E_REF"] else {
            throw XCTSkip("CLAUDE_TALK_CAPS_E2E_WAV / CLAUDE_TALK_CAPS_E2E_REF が無い")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let direct = dir.appendingPathComponent("direct")
        try FileManager.default.createDirectory(at: direct, withIntermediateDirectories: true)
        try #"{"capsLock": {"pollMs": 20}}"#.write(to: direct.appendingPathComponent("settings.json"),
                                                   atomically: true, encoding: .utf8)
        setenv("CLAUDE_TALK_HOME", dir.path, 1)
        defer { unsetenv("CLAUDE_TALK_HOME") }
        let ref = try PCM.loadFile(URL(fileURLWithPath: r))
        let engine = DirectEngine(makeInput: { try WavFileInput(spec: w, trigger: "speak_start", delayMs: 2500) },
                                  testSpeakReference: ref, capsReader: FakeReader(capsOn))
        let o = try await engine.speakOutcome(text: "今日は日本の四季について順番にお話しします。春は桜が咲き、夏は暑く、秋は紅葉がきれいで、冬は雪が降ります。",
                                              voice: nil, rate: nil, locale: "ja-JP")
        await engine.closeMic(reason: "test")
        print("caps barge e2e caps_on=\(capsOn): \(o.toolText.replacingOccurrences(of: "\n", with: " / "))")
        return o
    }

    func testBargeInOnlyWhileOn() async throws {
        let on = try await run(capsOn: true)
        XCTAssertTrue(on.interrupted, "オンなら割り込める")
        let off = try await run(capsOn: false)
        XCTAssertFalse(off.interrupted, "オフなら割り込まない")
        XCTAssertTrue(off.finished)
    }
}
