//
//  Speaker.swift
//  ClaudeTalkCore
//
//  direct モードの読み上げ。音声アプリの TTSService と同じ AVSpeechSynthesizer を MCP サーバーの中で使う。
//

@preconcurrency import AVFoundation
import Foundation

@MainActor
public final class Speaker {
    private let synthesizer = AVSpeechSynthesizer()
    private var delegate: SynthDelegate?
    /// テスト用: `CLAUDE_TALK_TTS_VOLUME` (0.0〜1.0)。
    private let volume: Float? = ProcessInfo.processInfo.environment["CLAUDE_TALK_TTS_VOLUME"].flatMap(Float.init)

    public init() {}

    /// 読み上げて、終わる (または止められる) まで待つ。onStart は音が出始めた時に 1 回。
    /// 戻り値: 最後まで読んだら true、止められたら false。
    public func speak(text: String, voice: String?, rate: Double?, locale: String,
                      onStart: @escaping @Sendable () -> Void) async -> Bool {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        let synth = synthesizer
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                let u = AVSpeechUtterance(string: text)
                if let voice, let v = AVSpeechSynthesisVoice(identifier: voice) {
                    u.voice = v
                } else {
                    u.voice = AVSpeechSynthesisVoice(language: locale)
                }
                if let rate { u.rate = Float(rate) }
                if let volume { u.volume = volume }
                let d = SynthDelegate(onStart: onStart) { finished in cont.resume(returning: finished) }
                self.delegate = d
                synth.delegate = d
                synth.speak(u)
            }
        } onCancel: {
            // MCP の取り消し (Esc) で止める。
            Task { @MainActor in synth.stopSpeaking(at: .immediate) }
        }
    }

    public func stop() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
    }
}

private final class SynthDelegate: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var onStart: (@Sendable () -> Void)?
    private var onDone: ((Bool) -> Void)?

    init(onStart: @escaping @Sendable () -> Void, onDone: @escaping (Bool) -> Void) {
        self.onStart = onStart
        self.onDone = onDone
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        lock.lock(); let f = onStart; onStart = nil; lock.unlock()
        f?()
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { finish(true) }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { finish(false) }

    private func finish(_ ok: Bool) {
        lock.lock(); let f = onDone; onDone = nil; lock.unlock()
        f?(ok)
    }
}
