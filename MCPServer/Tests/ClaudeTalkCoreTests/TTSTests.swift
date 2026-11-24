import AVFoundation
import XCTest
@testable import ClaudeTalkCore

final class ReadingsTests: XCTestCase {
    let entries = Readings.entries(fileText: nil)

    func testRequestedWords() {
        let text = "Docker と TypeScript と Kubernetes と Python と Claude と MCP"
        XCTAssertEqual(Readings.apply(text, entries: entries, latin: .auto),
                       "ドッカー と タイプスクリプト と クバネティス と パイソン と クロード と エムシーピー")
    }

    func testBenchSentences() {
        XCTAssertEqual(Readings.apply("今は macOS の標準の声で読み上げています。設定の voice を書き換えます。", entries: entries, latin: .auto),
                       "今は マックオーエス の標準の声で読み上げています。設定の ボイス を書き換えます。")
        XCTAssertEqual(Readings.apply("このまま PR を作ってもいいですか？", entries: entries, latin: .auto),
                       "このまま ピーアール を作ってもいいですか？")
    }

    func testBoundariesAndCase() {
        // 日本語に直に続く・大文字小文字の違い・語の一部には当てない・数字は区切り
        XCTAssertEqual(Readings.apply("dockerのMCPサーバー", entries: entries, latin: .keep), "ドッカーのエムシーピーサーバー")
        XCTAssertEqual(Readings.apply("Dockerfile", entries: entries, latin: .keep), "Dockerfile")
        XCTAssertEqual(Readings.apply("Qwen3 と Claude Code", entries: entries, latin: .keep), "クウェン3 と クロードコード")
        XCTAssertEqual(Readings.apply("MacBook と Mac", entries: entries, latin: .keep), "MacBook と マック")
    }

    func testUnknownLatin() {
        XCTAssertEqual(Readings.apply("API と CLI と foo と M4", entries: entries, latin: .auto), "エーピーアイ と シーエルアイ と foo と M4")
        XCTAssertEqual(Readings.apply("API と foo", entries: entries, latin: .keep), "API と foo")
        XCTAssertEqual(Readings.apply("foo", entries: entries, latin: .spell), "エフオーオー")
        XCTAssertEqual(Readings.apply("日本語だけ。", entries: entries, latin: .auto), "日本語だけ。")
    }

    func testFileOverrideAndRemove() {
        let e = Readings.entries(fileText: "Docker=ドッカ\n-Python\nNeovim=ネオビム,ニオビム # comment\n")
        XCTAssertEqual(Readings.apply("Docker Python Neovim", entries: e, latin: .keep), "ドッカ Python ネオビム")
    }
}

final class TTSSettingsTests: XCTestCase {
    func testDefaults() throws {
        let s = try JSONDecoder().decode(DirectSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(s.ttsEngine, .qwen)
        XCTAssertEqual(s.ttsPort, 8768)
        XCTAssertEqual(s.ttsModel, "qwen3-tts-0.6b")
        XCTAssertEqual(s.ttsVoiceName, "serena")
        XCTAssertNil(s.ttsVoiceFilePath, "Qwen は組み込みの話者なので声ファイルを足さない")
        XCTAssertEqual(s.ttsInstructions, "", "Qwen3-TTS 0.6B は instructions を受け付けない")
        XCTAssertEqual(s.ttsSpeedValue, 1)
        XCTAssertEqual(s.ttsLocalSpeed, 1)
        XCTAssertEqual(s.port, 8766, "listen の port は変えない")
        XCTAssertEqual(s.prerollLeadSeconds, 0.3, "listen の設定は変えない")
    }

    func testIrodoriDefaultsStayTheSame() throws {
        let s = try JSONDecoder().decode(DirectSettings.self, from: Data(#"{"tts": "irodori"}"#.utf8))
        XCTAssertEqual(s.ttsEngine, .irodori)
        XCTAssertEqual(s.ttsPort, 8767)
        XCTAssertEqual(s.ttsModel, "irodori-tts-mf:q5_k")
        XCTAssertEqual(s.ttsVoiceName, "irodori-f-low")
        XCTAssertTrue(s.ttsVoiceFilePath?.hasSuffix("/.claude-talk-mcp/direct/voices/irodori-f-low.voice.gguf") ?? false)
        XCTAssertEqual(s.ttsInstructions, "落ち着いた低めの女性の声で、ゆっくり穏やかに読み上げてください。")
        XCTAssertEqual(TTSServer(settings: s).logURL.lastPathComponent, "tts-serve.log", "Irodori のログは今まで通り")
    }

    func testOverridesWinOverProfile() throws {
        let s = try JSONDecoder().decode(DirectSettings.self, from: Data(
            #"{"tts": "qwen", "ttsVoiceName": "uncle_fu", "ttsPort": 9999, "ttsSpeed": 1.3}"#.utf8))
        XCTAssertEqual(s.ttsVoiceName, "uncle_fu")
        XCTAssertEqual(s.ttsPort, 9999)
        XCTAssertEqual(s.ttsModel, "qwen3-tts-0.6b")
        XCTAssertEqual(s.ttsLocalSpeed, 1.3, accuracy: 1e-9, "Qwen は手元で伸縮")
        var irodori = s
        irodori.tts = "irodori"
        XCTAssertEqual(irodori.ttsLocalSpeed, 1, "Irodori は serve の speed")
        var wild = s
        wild.ttsSpeed = 9
        XCTAssertEqual(wild.ttsSpeedValue, 2)
    }

    func testSwitchToAVSpeech() throws {
        let s = try JSONDecoder().decode(DirectSettings.self, from: Data(#"{"tts": "AVSpeech", "ttsSeed": 7}"#.utf8))
        XCTAssertEqual(s.ttsEngine, .avspeech)
        XCTAssertEqual(s.ttsServeEngine, .qwen)
        XCTAssertEqual(s.ttsSeed, 7)
        let unknown = try JSONDecoder().decode(DirectSettings.self, from: Data(#"{"tts": "nonsense"}"#.utf8))
        XCTAssertEqual(unknown.ttsEngine, .qwen)
    }

    func testServeArgumentsBindLoopbackOnly() {
        let args = TTSServer(settings: DirectSettings()).arguments
        XCTAssertEqual(args[args.firstIndex(of: "--host")! + 1], "127.0.0.1")
        XCTAssertEqual(args[args.firstIndex(of: "--port")! + 1], "8768")
        XCTAssertEqual(args[args.firstIndex(of: "--language")! + 1], "ja")
        XCTAssertTrue(args.contains("qwen3-tts-0.6b"))
        XCTAssertFalse(args.contains("--add-voice"))
        XCTAssertFalse(args.contains("0.0.0.0"))
        XCTAssertFalse(args.contains("haas-ja-v1.0:f16"), "listen の serve とは別")
        XCTAssertEqual(TTSServer(settings: DirectSettings()).logURL.lastPathComponent, "tts-serve-qwen.log")

        var s = DirectSettings()
        s.tts = "irodori"
        let ia = TTSServer(settings: s).arguments
        XCTAssertEqual(ia[ia.firstIndex(of: "--port")! + 1], "8767")
        XCTAssertTrue(ia.contains("irodori-tts-mf:q5_k"))
        XCTAssertTrue(ia[ia.firstIndex(of: "--add-voice")! + 1].hasPrefix("irodori-f-low=/"))
    }

    func testHealthCheckNeedsSynthesisAndVoice() {
        let ok: [[String: Any]] = [["id": "Irodori", "speech": ["task": "synthesis", "voices": [["name": "none"], ["name": "irodori-f-low"]]]]]
        XCTAssertEqual(TTSServer.check(models: ok, voice: "irodori-f-low", port: 1), .ready)
        if case .wrong = TTSServer.check(models: ok, voice: "serena", port: 1) {} else { XCTFail("missing voice") }
        let qwen: [[String: Any]] = [["id": "Qwen3-TTS", "speech": ["task": "synthesis", "voices": [["name": "ono_anna"], ["name": "serena"]]]]]
        XCTAssertEqual(TTSServer.check(models: qwen, voice: "serena", port: 1), .ready)
        let asr: [[String: Any]] = [["id": "Haas", "speech": ["task": "recognition"]]]
        if case .wrong = TTSServer.check(models: asr, voice: "irodori-f-low", port: 1) {} else { XCTFail("no synthesis") }
    }

    func testRequestBody() {
        var s = DirectSettings()
        s.tts = "irodori"
        s.ttsSpeed = 0.9
        let b = IrodoriSpeaker.requestBody(text: "こんにちは", settings: s)
        XCTAssertEqual(b["response_format"] as? String, "pcm")
        XCTAssertEqual(b["voice"] as? String, "irodori-f-low")
        XCTAssertEqual(b["speed"] as? Double, 0.9)
        XCTAssertNil(b["seed"])
        XCTAssertNotNil(b["instructions"])
    }

    func testQwenRequestBodyHasNoSpeedNorInstructions() {
        var s = DirectSettings()
        s.ttsSpeed = 1.2
        s.ttsSeed = 3
        let b = IrodoriSpeaker.requestBody(text: "こんにちは", settings: s)
        XCTAssertEqual(b["voice"] as? String, "serena")
        XCTAssertEqual(b["response_format"] as? String, "pcm")
        XCTAssertNil(b["speed"], "Qwen3-TTS 0.6B は speed を 400 で断る")
        XCTAssertNil(b["instructions"])
        XCTAssertEqual(b["seed"] as? Int, 3)
    }

    /// 手元の伸縮: 1 秒の音を速さ 2 / 0.5 で WAV に描くと、ほぼ 0.5 / 2 秒になる (音は鳴らさない)。
    func testLocalSpeedStretchesOfflineRender() async throws {
        for (speed, expect) in [(1.0, 1.0), (2.0, 0.5), (0.5, 2.0)] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: url) }
            var d = Data(count: 24_000 * 2)
            d.withUnsafeMutableBytes { raw in
                let s = raw.bindMemory(to: Int16.self)
                for i in 0..<s.count { s[i] = Int16(8000 * sin(Double(i) * 2 * .pi * 220 / 24_000)) }
            }
            // StreamPlayer を手放した時に WAV が閉じる
            var p: StreamPlayer? = try StreamPlayer(sampleRate: 24_000, outputFile: url, volume: nil, speed: speed, probe: nil)
            for k in stride(from: 0, to: d.count, by: 4800) { try p!.schedule(int16: d.subdata(in: k..<min(k + 4800, d.count))) }
            let ok = await p!.finishAndWait()
            p!.shutdown()
            p = nil
            XCTAssertTrue(ok)
            let f = try AVAudioFile(forReading: url)
            let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
            try f.read(into: buf)
            let ch = buf.floatChannelData![0]
            let n = Int(buf.frameLength)
            let lastVoiced = (0..<n).last { abs(ch[$0]) > 0.02 } ?? 0
            let firstVoiced = (0..<n).first { abs(ch[$0]) > 0.02 } ?? 0
            let voicedSeconds = Double(lastVoiced - firstVoiced) / 24_000
            XCTAssertEqual(voicedSeconds, expect, accuracy: 0.06, "speed \(speed)")
        }
    }

    func testLeadingSilence() {
        var d = Data(count: 200)
        d.withUnsafeMutableBytes { $0.bindMemory(to: Int16.self)[50] = 3000 }
        XCTAssertEqual(PCMHTTPStream.leadingSilenceSeconds(d, sampleRate: 1000), 0.05, accuracy: 1e-9)
    }
}

/// serve が立たない時は avspeech に落ちる (音量 0、マイクは無音のテスト入力)。
final class TTSFallbackTests: XCTestCase {
    func testFallsBackToAVSpeechWhenServeIsDown() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let direct = dir.appendingPathComponent("direct")
        try FileManager.default.createDirectory(at: direct, withIntermediateDirectories: true)
        try #"{"tts": "qwen", "ttsPort": 1, "ttsStartTimeoutSeconds": 2}"#
            .write(to: direct.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        setenv("CLAUDE_TALK_HOME", dir.path, 1)
        setenv("CLAUDE_TALK_TTS_VOLUME", "0", 1)
        defer { unsetenv("CLAUDE_TALK_HOME"); unsetenv("CLAUDE_TALK_TTS_VOLUME") }
        let engine = DirectEngine(makeInput: { try WavFileInput(spec: "silent") })
        TimingLog.shared.enabled = true
        let finished = try await engine.speak(text: "あ", voice: nil, rate: nil, locale: "ja-JP")
        await engine.closeMic(reason: "test")
        XCTAssertTrue(finished)
        let log = try String(contentsOf: dir.appendingPathComponent("logs/timing.jsonl"), encoding: .utf8)
        XCTAssertTrue(log.contains("\"ev\":\"speak.fallback\""), log)
        XCTAssertTrue(log.contains("\"tts\":\"avspeech\""), log)
    }
}

/// 本物の speech serve (既定 Qwen、CLAUDE_TALK_TTS_BENCH_ENGINE=irodori で Irodori) を使う測定。速さは CLAUDE_TALK_TTS_BENCH_SPEED。`CLAUDE_TALK_TTS_BENCH_PORT` (serve の port) と
/// `CLAUDE_TALK_TTS_BENCH_OUT` (結果の置き場) がある時だけ動く。スピーカーには出さない
/// (WAV への offline 描画と、mainMixer の音量 0 の実時間再生だけ)。
final class IrodoriBenchTests: XCTestCase {
    func testBench() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let port = env["CLAUDE_TALK_TTS_BENCH_PORT"].flatMap(Int.init), let outDir = env["CLAUDE_TALK_TTS_BENCH_OUT"] else {
            throw XCTSkip("CLAUDE_TALK_TTS_BENCH_PORT / CLAUDE_TALK_TTS_BENCH_OUT が無い")
        }
        let sentences = try String(contentsOfFile: env["CLAUDE_TALK_TTS_BENCH_SENTENCES"] ?? "", encoding: .utf8)
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var s = DirectSettings()
        if let engine = env["CLAUDE_TALK_TTS_BENCH_ENGINE"] { s.tts = engine }   // 既定 qwen
        s.ttsPort = port
        s.ttsSpeed = env["CLAUDE_TALK_TTS_BENCH_SPEED"].flatMap(Double.init)
        let speaker = IrodoriSpeaker()
        let out = URL(fileURLWithPath: outDir)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let entries = Readings.entries(fileText: nil)
        var results: [[String: Any]] = []

        // 1) WAV に書く (CER 用): 置き換え前 / 後 × seed 1〜3
        for variant in ["before", "after"] {
            for seed in 1...3 {
                s.ttsSeed = seed
                let dir = out.appendingPathComponent("\(variant)-s\(seed)")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                for (i, text) in sentences.enumerated() {
                    let input = variant == "after" ? Readings.apply(text, entries: entries, latin: .auto) : text
                    let ok = try await speaker.speak(text: input, settings: s,
                                                     outputFile: dir.appendingPathComponent("\(i + 1).wav"), volume: nil)
                    XCTAssertTrue(ok)
                }
            }
        }
        s.ttsSeed = nil

        // 2) 実時間 (音量 0): 最初の音・done・done の後に残る音
        let latencyProbe = AVAudioEngine()
        let outputLatency = latencyProbe.outputNode.presentationLatency
        for (i, text) in sentences.enumerated() {
            let input = Readings.apply(text, entries: entries, latin: .auto)
            for rep in 0..<4 {   // 1 回目はウォームアップ
                let rec = TapRecorder()
                let t0 = AVAudioTime.seconds(forHostTime: mach_absolute_time())
                let firstChunk = Box<Int>()
                let ok = try await speaker.speak(text: input, settings: s, outputFile: nil, volume: 0,
                                                 probe: { buf, when in rec.add(buf, when) },
                                                 onTiming: { stage, t in if stage == "first_audio" { firstChunk.set(t.firstChunkMs) } })
                let tDone = AVAudioTime.seconds(forHostTime: mach_absolute_time())
                XCTAssertTrue(ok)
                guard rep > 0 else { continue }
                let r = rec.summary()
                results.append([
                    "n": i + 1, "rep": rep,
                    "first_chunk_ms": firstChunk.get() ?? -1,
                    "first_voiced_heard_ms": r.firstVoiced.map { Int((($0 + outputLatency) - t0) * 1000) } ?? -1,
                    "done_ms": Int((tDone - t0) * 1000),
                    "audio_s": r.renderedSeconds,
                    // 正なら done の後にまだ声が出ていた (出力の遅れも足す)
                    "voiced_after_done_ms": r.lastVoiced.map { Int((($0 + outputLatency) - tDone) * 1000) } ?? 0,
                    "rendered_after_done_ms": r.lastRendered.map { Int((($0 + outputLatency) - tDone) * 1000) } ?? 0,
                    "output_latency_ms": Int(outputLatency * 1000),
                    "footprint_mb": footprintMB(),
                ])
            }
        }
        let data = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: out.appendingPathComponent("realtime.json"))
    }
}

final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T?
    func set(_ x: T?) { lock.lock(); v = x; lock.unlock() }
    func get() -> T? { lock.lock(); defer { lock.unlock() }; return v }
}

/// PlayerNode の出力 (描画したそのままの音) と描画の時刻を集める。
final class TapRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var firstVoiced: Double?
    private var lastVoiced: Double?
    private var lastRendered: Double?
    private var frames: Double = 0
    private var rate: Double = 48_000

    func add(_ buf: AVAudioPCMBuffer, _ when: AVAudioTime) {
        guard let ch = buf.floatChannelData, when.isHostTimeValid else { return }
        let start = AVAudioTime.seconds(forHostTime: when.hostTime)
        let sr = buf.format.sampleRate
        let n = Int(buf.frameLength)
        var first: Int?
        var last: Int?
        var lastAny: Int?
        for i in 0..<n {
            let v = abs(ch[0][i])
            if v > 500.0 / 32768 { if first == nil { first = i }; last = i }
            if v > 0 { lastAny = i }
        }
        lock.lock()
        rate = sr
        if let f = first, firstVoiced == nil { firstVoiced = start + Double(f) / sr }
        if let l = last { lastVoiced = start + Double(l + 1) / sr }
        if let a = lastAny { lastRendered = start + Double(a + 1) / sr }
        frames += Double(n)
        lock.unlock()
    }

    func summary() -> (firstVoiced: Double?, lastVoiced: Double?, lastRendered: Double?, renderedSeconds: Double) {
        lock.lock(); defer { lock.unlock() }
        return (firstVoiced, lastVoiced, lastRendered, (frames / rate * 100).rounded() / 100)
    }
}

func footprintMB() -> Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return kr == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
}

/// 本物の speech serve で claude-talk-voice の読み上げ (ReplySpeaker) を確かめる。`CLAUDE_TALK_TTS_BENCH_PORT` がある時だけ。
/// 音量 0 の実時間再生: 最後まで鳴らすと true、途中で stop() すると false ですぐ返り、聞こえた所までが文の途中になる。
final class ReplySpeakerLiveTests: XCTestCase {
    func testFinishAndInterrupt() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let port = env["CLAUDE_TALK_TTS_BENCH_PORT"].flatMap(Int.init) else {
            throw XCTSkip("CLAUDE_TALK_TTS_BENCH_PORT が無い")
        }
        for speed in [1.0, 1.3] {
            var s = DirectSettings()
            if let engine = env["CLAUDE_TALK_TTS_BENCH_ENGINE"] { s.tts = engine }
            s.ttsPort = port
            s.ttsSpeed = speed
            // 1) 最後まで
            let sw = Stopwatch()
            let a = ReplySpeaker(settings: s, turn: 1, volume: 0, dumpDir: nil, onStage: { _ in })
            a.enqueue("うん、わかりました。")
            a.enqueue("テストは全部通りました。")
            let done = await a.finish()
            XCTAssertTrue(done, "speed \(speed)")
            XCTAssertFalse(a.isSounding)
            XCTAssertGreaterThan(a.progress.playedSeconds, 1.0)
            XCTAssertGreaterThan(sw.ms, 1000)
            // 2) 割り込み
            let b = ReplySpeaker(settings: s, turn: 2, volume: 0, dumpDir: nil, onStage: { _ in })
            b.enqueue("今は macOS の標準の声で読み上げています。声を変えるときは、設定の voice を書き換えます。")
            b.enqueue("テストは全部通りました。このまま PR を作ってもいいですか？")
            try await Task.sleep(nanoseconds: 1_500_000_000)
            let heard = b.stop()
            let sw2 = Stopwatch()
            let finished = await b.finish()
            XCTAssertFalse(finished, "speed \(speed)")
            XCTAssertLessThan(sw2.ms, 300, "止めたらすぐ返る")
            XCTAssertFalse(b.isSounding)
            XCTAssertEqual(heard.sentencesStarted, 1, "\(heard)")
            XCTAssertLessThan(heard.heardText.count, 40, "\(heard)")
            print("[live] speed \(speed) full_ms \(sw.ms) heard \(heard.heardText) played_s \(heard.playedSeconds)")
        }
    }
}
