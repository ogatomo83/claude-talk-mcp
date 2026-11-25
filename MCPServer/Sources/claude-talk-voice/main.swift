//
//  main.swift
//  claude-talk-voice
//
//  常駐する声のプロセス (案 2。段 b でスピーカーでも使えるようにした)。ターミナル (マイクの許可があるアプリ、iTerm2 など) で動かす:
//
//    claude-talk-voice [--cwd DIR] [--model NAME] [--resume SESSION_ID] [--tools LIST]
//
//  Ctrl-C で止める。claude-talk の MCP サーバー (/voice) とは別のプロセスで、MCP サーバーの動きは変えない。
//  マイクは MCP の direct モードと同じロック (~/.claude-talk-mcp/direct/mic.lock) を取るので、同時には録らない。
//
//  設定: ~/.claude-talk-mcp/voice/settings.json (claude 側)、~/.claude-talk-mcp/direct/settings.json (録音・読み上げ)
//  ログ: ~/.claude-talk-mcp/logs/timing.jsonl (mode=voice)、~/.claude-talk-mcp/voice/transcript.log
//  テスト: CLAUDE_TALK_VOICE_TEST_SCRIPT (WAV を順に流す)、CLAUDE_TALK_VOICE_TEST_ECHO (エコーの模擬 dB@ms)、
//        CLAUDE_TALK_TTS_VOLUME=0、CLAUDE_TALK_VOICE_TTS_DUMP_DIR
//  開発用: --eval-echo-gate SPEC.json (録音済みの WAV で割り込み判定を数える。EvalEchoGate.swift)
//         --eval-speak-barge SPEC.json (MCP の speak の割り込みを通しで数える。EvalSpeakBarge.swift)
//

import ClaudeTalkCore
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

func usage() -> Never {
    print("""
    usage: claude-talk-voice [--cwd DIR] [--model NAME] [--resume SESSION_ID] [--tools LIST] [--print-args]
                             [--no-vp] [--no-shared-engine] [--no-gate] [--no-echo-filter] [--barge-in-ms N]
                             [--mic-check [SECONDS]]

      --cwd DIR        claude を動かす作業ディレクトリ (既定 ~/.claude-talk-mcp/voice/work)
      --model NAME     claude の --model (例 sonnet)
      --resume ID      前の会話の続きから (終了時に表示される session id)
      --tools LIST     使える組み込みツール (既定 Read,Glob,Grep。"" でツールなし)。確認が来たら allowTools だけ許す
      --print-args     claude に渡す引数を表示して終わる
      スピーカーで使う層 (既定は全部有効。voice/settings.json でも切れる):
      --no-vp            voice processing (エコー除去・ノイズ抑制) を使わない (ヘッドホンなら不要)
      --no-shared-engine 読み上げを録音と別の engine で鳴らす (段 a と同じ。VPIO も効かなくなる)
      --no-gate          割り込みの判定 (人の声か、読み上げの残りか) をしない
      --no-echo-filter   読み上げ文に似た書き起こしを捨てない
      --barge-in-ms N    読み上げ中に N ms 話したら止める (既定 300)
      --mic-check [S]    S 秒 (既定 6) 録音して声の大きさ (dBFS) を表示して終わる。音は出さない
    止め方: Ctrl-C
    """)
    exit(2)
}

var (voice, voiceWarning) = VoiceSettings.load()
let (direct, directWarning) = DirectSettings.load()
var resume: String?
var printArgs = false
var micCheckSeconds: Double?
var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let a = args.removeFirst()
    func value() -> String {
        if args.isEmpty { usage() }
        return args.removeFirst()
    }
    switch a {
    case "--cwd": voice.cwd = value()
    case "--model": voice.model = value()
    case "--resume": resume = value()
    case "--tools":
        voice.tools = value()
        voice.allowTools = voice.tools.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    case "--print-args": printArgs = true
    case "--no-vp": voice.voiceProcessing = false
    case "--no-shared-engine": voice.sharedEngine = false
    case "--no-gate": voice.echoGate.enabled = false
    case "--no-echo-filter": voice.echoFilter = false
    case "--barge-in-ms": voice.bargeInMs = Int(value()) ?? voice.bargeInMs
    case "--mic-check":
        micCheckSeconds = 6
        if let n = args.first, let v = Double(n) { micCheckSeconds = v; args.removeFirst() }
    case "--eval-echo-gate":
        // 開発用: 音を出さずに割り込み判定を数える (EvalEchoGate.swift)
        do { try EchoGateEval.run(specPath: value()); exit(0) } catch { print("eval: \(error)"); exit(1) }
    case "--eval-speak-live":
        // 開発用: MCP の speak (本物の読み上げ、音量は CLAUDE_TALK_TTS_VOLUME) → 割り込まれたら listen、を 1 回
        let text = value()
        Task {
            let e = DirectEngine.shared
            do {
                let o = try await e.speakOutcome(text: text, voice: nil, rate: nil, locale: "ja-JP")
                print("speak: \(o.toolText.replacingOccurrences(of: "\n", with: " / ")) played_s \(o.playedSeconds)")
                if o.interrupted || o.userStartedNearEnd {
                    let heard = try await e.listen(timeout: 8, locale: "ja-JP")
                    print("listen: \(heard)")
                }
                await e.closeMic(reason: "eval")
                exit(0)
            } catch { print("eval: \(error)"); exit(1) }
        }
        dispatchMain()
    case "--eval-speak-barge":
        // 開発用: MCP の speak の割り込みを音を出さずに通しで数える (EvalSpeakBarge.swift)
        let spec = value()
        Task {
            do { try await SpeakBargeEval.run(specPath: spec); exit(0) } catch { print("eval: \(error)"); exit(1) }
        }
        dispatchMain()
    case "-h", "--help": usage()
    default:
        print("知らない引数: \(a)")
        usage()
    }
}
for w in [voiceWarning, directWarning].compactMap({ $0 }) { print("[警告] \(w)") }

if printArgs {
    print(([voice.claudeBin] + voice.claudeArguments(sessionId: "<new>", resume: resume)).joined(separator: " "))
    print("cwd: \(voice.cwdPath)")
    exit(0)
}

if let secs = micCheckSeconds {
    MicCheck.run(seconds: secs, options: voice.audioOptions)
}

let input: AudioInput
do {
    var test: AudioInput?
    var scripted: ScriptedWavInput?
    if let s = try ScriptedWavInput.fromEnvironment() {
        test = s
        scripted = s
    } else if let w = try WavFileInput.fromEnvironment() {
        test = w
    }
    if voice.sharedEngine {
        // 層 1: 録音と読み上げを 1 つの engine で (VPIO はマイクの時だけ)
        let engine = VoiceAudioEngine(options: voice.audioOptions, testInput: test)
        if let s = scripted, let e = ScriptedWavInput.parseEcho(ProcessInfo.processInfo.environment["CLAUDE_TALK_VOICE_TEST_ECHO"]) {
            s.echo = (engine.reference, e.gainDb, e.delayMs)
        }
        input = engine
    } else {
        input = test ?? MicInput()
    }
} catch {
    print("入力を用意できません: \(error.localizedDescription)")
    exit(1)
}

let session = VoiceSession(voice: voice, direct: direct, resume: resume, input: input) { line in
    print(line)
}

// Ctrl-C / SIGTERM で片付けてから終わる。
signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM] {
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler {
        Task { await session.shutdown(reason: sig == SIGINT ? "sigint" : "sigterm") }
    }
    src.resume()
    signalSources.append(src)
}

Task {
    do {
        try await session.run()
        exit(0)
    } catch {
        print("起動できません: \(error.localizedDescription)")
        await session.shutdown(reason: "error")
        exit(1)
    }
}
dispatchMain()
