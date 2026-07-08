//
//  AppState.swift
//  claude-talk-mcp
//
//  アプリ全体の状態。ソケットサーバーを起動し、speak/listen を TTS/STT へ振り分ける。
//

import Foundation
import Observation
internal import Combine

@MainActor
@Observable
final class AppState {

    /// 今アプリが何をしているか（メニューに表示）。
    enum Activity: String {
        case idle = "待機中"
        case speaking = "読み上げ中"
        case listening = "聞き取り中"      // マイクで発話を録音中
        case encoding = "音声を生成中"      // 録音を音声ファイルに変換中
        case transcribing = "AIが認識中"    // 音声ファイルを Qwen3 に送って認識中
    }

    private(set) var activity: Activity = .idle
    private(set) var isListening = false
    private(set) var socketError: String?
    private(set) var logs: [String] = []
    var launchAtLogin: Bool

    private let tts = TTSService()
    private let stt = STTService()
    private let server = SpeechSocketServer()

    var isListeningReady: Bool { socketError == nil }
    var socketPath: String { SpeechSocket.path }

    init() {
        launchAtLogin = LoginItemManager.isEnabled
        // listen の進捗（聞き取り→生成→認識）を状態に反映する。
        stt.onPhase = { [weak self] phase in
            switch phase {
            case .idle: self?.activity = .idle
            case .listening: self?.activity = .listening
            case .encoding: self?.activity = .encoding
            case .transcribing: self?.activity = .transcribing
            }
        }
        startServer()
        // 音声認識サーバ(Qwen3-ASR)を先に起動・モデルロードしておく。
        stt.prewarm()
        log("音声認識サーバを準備しています…")
    }

    // MARK: - Socket server

    func startServer() {
        do {
            try server.start { [weak self] request in
                guard let self else { return .failure("アプリが終了しています") }
                return await self.handle(request)
            }
            socketError = nil
            log("ソケット待受を開始しました")
        } catch {
            socketError = error.localizedDescription
            log("待受開始に失敗: \(error.localizedDescription)")
        }
    }

    private func handle(_ request: SpeechRequest) async -> SpeechResponse {
        switch request.type {
        case .speak:
            guard let text = request.text, !text.isEmpty else {
                return .failure("text がありません")
            }
            // 読み上げ中はマイクを止める（TTS 音を録音＝エコーしないため）。
            stt.stopPreroll()
            activity = .speaking
            log("🔊 \(text)")
            await tts.speak(
                text: text,
                voice: request.voice,
                rate: request.rate,
                locale: request.locale ?? "ja-JP"
            )
            activity = .idle
            // 読み上げ完了直後からマイクを先回りで回し、次の listen までの
            // 「待機中」に話し始めても頭から録れるようにする（プリロール）。
            stt.beginPreroll(locale: request.locale ?? "ja-JP")
            return .success()

        case .listen:
            activity = .listening
            isListening = true
            log("🎙️ 認識待ち…")
            let response = await stt.listen(
                timeout: request.timeout ?? 30,
                locale: request.locale ?? "ja-JP"
            )
            isListening = false
            activity = .idle
            if let text = response.text {
                log("📝 \(text.isEmpty ? "（無音）" : text)")
            } else if let error = response.error {
                log("⚠️ \(error)")
            }
            return response
        }
    }

    // MARK: - Login item

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LoginItemManager.setEnabled(enabled)
            launchAtLogin = LoginItemManager.isEnabled
        } catch {
            log("自動起動の設定に失敗: \(error.localizedDescription)")
            launchAtLogin = LoginItemManager.isEnabled
        }
    }

    // MARK: - Log

    private func log(_ message: String) {
        logs.append(message)
        if logs.count > 50 {
            logs.removeFirst(logs.count - 50)
        }
    }
}
