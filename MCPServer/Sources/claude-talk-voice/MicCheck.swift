//
//  MicCheck.swift
//  claude-talk-voice
//
//  --mic-check: 録音だけして (音は出さない)、マイクに入る声の大きさを表示する。
//  割り込みの判定 (echoGate.minVoiceDb、既定 -50 dBFS) が自分の声に合っているかを確かめる。
//

import ClaudeTalkCore
import Foundation

enum MicCheck {
    static func run(seconds: Double, options: VoiceAudioEngine.Options) -> Never {
        let lock = FileLock(url: TalkPaths.micLock)
        guard lock.tryLock() else {
            print("マイクを使っているプロセスがあります (/voice か claude-talk-voice)。止めてからやり直してください")
            exit(1)
        }
        let ring = AudioRing(retainSeconds: max(seconds + 2, 15))
        let engine = VoiceAudioEngine(options: options)
        do {
            try engine.start(into: ring)
        } catch {
            print("録音を開始できません: \(error.localizedDescription)")
            exit(1)
        }
        print("[\(Int(seconds)) 秒録音します。いつもの声の大きさで、何か話してください (VPIO \(engine.voiceProcessingActive ? "有効" : "無効"))]")
        let t0 = PCM.now()
        Thread.sleep(forTimeInterval: seconds)
        let s = ring.samples(from: t0, to: PCM.now())
        engine.stop()
        lock.unlock()
        let f = EchoGate.frameDb(s).sorted()
        guard !f.isEmpty else { print("音が届きませんでした (マイクの許可を確かめてください)"); exit(1) }
        func p(_ q: Double) -> Double { f[min(f.count - 1, Int(Double(f.count - 1) * q))] }
        let def = EchoGateConfig()
        print(String(format: "部屋の音 (下から 1 割): %.1f dBFS / 中央: %.1f / 声の大きい所 (上から 1 割): %.1f / 最大: %.1f",
                     p(0.1), p(0.5), p(0.9), p(1)))
        let voiced = f.filter { $0 >= def.minVoiceDb }.count
        print(String(format: "割り込みの下限 minVoiceDb %.0f dBFS を超えた 10ms: %d / %d (%.0f%%)",
                     def.minVoiceDb, voiced, f.count, Double(voiced) * 100 / Double(f.count)))
        if p(1) - p(0.5) < 12 {
            print("→ 話し声が入っていないようです (部屋の音だけ)。話しながらもう一度試してください")
        } else if p(0.9) < def.minVoiceDb + 6 {
            let suggest = max(Int(p(0.9) - 8), Int(p(0.5) + 10))
            print("→ 声が小さめです。割り込みで止まりにくい時は voice/settings.json の \"echoGate\": {\"minVoiceDb\": \(suggest)} を試してください")
        } else {
            print("→ 既定の minVoiceDb で割り込みが効く大きさです")
        }
        exit(0)
    }
}
