//
//  TTSService.swift
//  claude-talk-mcp
//
//  AVSpeechSynthesizer を使ったテキスト読み上げ。読み上げ完了まで待つ。
//

import AVFoundation

@MainActor
final class TTSService {
    private let synthesizer = AVSpeechSynthesizer()
    private var delegate: SpeechSynthDelegate?

    /// テキストを読み上げ、完了（または中断）まで待機する。
    func speak(text: String, voice: String?, rate: Double?, locale: String) async {
        // 直前の読み上げが残っていれば止める。
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let utterance = AVSpeechUtterance(string: text)

            if let voice, let selected = AVSpeechSynthesisVoice(identifier: voice) {
                utterance.voice = selected
            } else {
                utterance.voice = AVSpeechSynthesisVoice(language: locale)
            }
            if let rate {
                utterance.rate = Float(rate)
            }

            let delegate = SpeechSynthDelegate { continuation.resume() }
            self.delegate = delegate
            self.synthesizer.delegate = delegate
            self.synthesizer.speak(utterance)
        }

        self.delegate = nil
    }
}

/// 読み上げ完了/中断を 1 度だけ通知するデリゲート。
/// コールバックは任意スレッドから来るため、ロックで one-shot を保証する。
private final class SpeechSynthDelegate: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var onDone: (() -> Void)?

    init(onDone: @escaping () -> Void) {
        self.onDone = onDone
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        finish()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        finish()
    }

    private func finish() {
        lock.lock()
        let done = onDone
        onDone = nil
        lock.unlock()
        done?()
    }
}
