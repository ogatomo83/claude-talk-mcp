//
//  STTService.swift
//  claude-talk-mcp
//
//  マイク発話を録音し、ローカルの Qwen3-ASR HTTP サーバ
//  (OpenAI 互換 /v1/audio/transcriptions) にまとめて投げて書き起こす。
//
//  旧実装（Apple Speech フレームワークのストリーミング認識）は日本語の
//  精度・速度がいまひとつだったため、録音 → VAD で無音確定 → AI モデルで
//  一括解析、という方式へ置き換えた。音声認識(Speech)権限は不要になり、
//  必要な権限はマイクのみ。
//

@preconcurrency import AVFoundation

/// ASR 失敗を表す軽量エラー（Result の Failure 用）。
struct ASRError: Error {
    let message: String
}

/// タップスレッドで AVAudioConverter を保持・遅延生成するための箱。
/// （Core Audio のタップは 1 コールずつ直列に呼ばれるため排他は不要）
private final class ConverterBox: @unchecked Sendable {
    var converter: AVAudioConverter?
}

@MainActor
final class STTService {
    /// listen 処理の進捗フェーズ。UI のステータス表示に使う。
    enum Phase {
        case idle         // 何もしていない（プリロール終了時など）
        case listening    // マイク録音・発話待ち（プリロール中も含む）
        case encoding     // 音声ファイル(WAV)生成中
        case transcribing // AI(Qwen3)へ送って認識中
    }

    /// フェーズが変わるたびに呼ばれる（MainActor）。
    var onPhase: (@MainActor (Phase) -> Void)?

    private let audioEngine = AVAudioEngine()
    private let client = ASRClient()

    /// 16kHz mono Int16(LE) に変換した録音データ。
    private var pcm16 = Data()
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: true
    )!

    private var continuation: CheckedContinuation<SpeechResponse, Never>?

    /// listen 呼び出しごとに増やす世代トークン。古い遅延処理を無効化する。
    private var generation = 0
    /// 無音タイマーのトークン。発話が続くたび更新する。
    private var silenceToken = 0

    /// 発話を検知済みか（無音確定は発話開始後のみ有効にする）。
    private var hasSpeech = false

    /// マイクを回して録音している最中か（プリロール／listen 共通）。
    private var isCapturing = false
    /// listen が採用済みか（false＝プリロール中で確定処理は動かさない）。
    private var listenActive = false
    /// 現在の録音のロケール。
    private var captureLocale = "ja-JP"

    /// 発話終了とみなす無音の長さ。
    private let silenceInterval: TimeInterval = 1.2
    /// これを超える RMS を発話とみなす（0.0〜1.0 のリニア振幅）。
    private let speechRMSThreshold: Float = 0.008
    /// 書き起こし前に先頭へ足す無音（頭切れ・頭欠け対策の「のりしろ」）。
    private let leadingPadSeconds: Double = 0.12
    /// listen が来ないままプリロールを回し続ける上限（秒）。
    private let prerollMaxSeconds: Double = 6.0
    /// プリロール中に保持する音声の上限バイト数（約12秒のリングバッファ）。
    private let prerollMaxBytes = 16_000 * 2 * 12

    /// マイクからの発話を録音し、Qwen3-ASR で書き起こしたテキストを返す。
    func listen(timeout: Double, locale: String) async -> SpeechResponse {
        guard await Self.requestMicrophoneAuthorization() else {
            return .failure("マイクの権限がありません")
        }
        // サーバ未起動なら起動して待つ（初回はモデルロードで数秒かかる）。
        guard await client.ensureServerRunning() else {
            return .failure("音声認識サーバに接続できません (~/.claude-talk-mcp/asr)")
        }

        return await withCheckedContinuation { (cont: CheckedContinuation<SpeechResponse, Never>) in
            self.continuation = cont
            if self.isCapturing {
                self.adoptPreroll(timeout: timeout)
            } else {
                self.beginRecording(timeout: timeout, locale: locale)
            }
        }
    }

    /// 読み上げ完了直後などに呼び、listen が来る前からマイクを先回りで回しておく。
    /// これで「待機中」に話し始めても頭から録れる。
    ///
    /// 同期的に完結させる（Task を使わない）ことで、speak 直後に listen が来ても
    /// 「プリロール起動」と「listen の録音開始」が競合しないようにする。
    /// 権限プロンプトはここでは出さず、権限がある時だけ即プリロールする
    /// （未許可なら listen 側の requestMicrophoneAuthorization に任せる）。
    func beginPreroll(locale: String) {
        guard !isCapturing, continuation == nil else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        beginCapture(locale: locale, preroll: true)
    }

    /// プリロールを止める（読み上げ開始前などに呼び、TTS 音の録音＝エコーを防ぐ）。
    func stopPreroll() {
        guard isCapturing, !listenActive else { return }
        generation += 1 // 進行中のタップ／タイマーを無効化
        stopEngine()
        onPhase?(.idle)
    }

    /// 進行中のプリロール録音を listen として採用し、確定処理を仕掛ける。
    private func adoptPreroll(timeout: Double) {
        listenActive = true
        let gen = generation
        onPhase?(.listening)
        // 全体タイムアウト。
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, self.generation == gen else { return }
            self.finalizeAndTranscribe(gen: gen)
        }
        // プリロール中に既に話し終えている場合に備え、無音確定を仕掛ける。
        if hasSpeech {
            scheduleSilenceFinalize(gen: gen)
        }
    }

    /// アプリ起動時などに呼び、サーバ起動とモデルロードを先に済ませておく。
    func prewarm() {
        Task { _ = await client.ensureServerRunning() }
    }

    // MARK: - Recording

    private func beginRecording(timeout: Double, locale: String) {
        beginCapture(locale: locale, preroll: false)
        guard isCapturing else { return } // セットアップ失敗時は finish 済み
        let gen = generation
        // 全体タイムアウト（RunLoop 非依存の GCD タイマー）。
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, self.generation == gen else { return }
            self.finalizeAndTranscribe(gen: gen)
        }
    }

    /// マイク録音を開始する。preroll=true のときは確定処理を仕掛けず、
    /// リングバッファとして音声を貯めるだけ（listen が来たら adoptPreroll で採用）。
    private func beginCapture(locale: String, preroll: Bool) {
        // 二重起動防止（競合で beginCapture が重なっても被害を出さない）。
        guard !isCapturing else { return }
        pcm16.removeAll(keepingCapacity: true)
        hasSpeech = false
        captureLocale = locale
        generation += 1
        let gen = generation

        let inputNode = audioEngine.inputNode
        let outFmt = outputFormat
        // 変換器はタップに届く実バッファのフォーマットから生成する。
        let box = ConverterBox()

        inputNode.removeTap(onBus: 0) // 二重挿入によるクラッシュを防ぐ
        // format は nil を渡し、入力ノードの実フォーマットをそのまま採用する。
        // （固定フォーマットを渡すと "Failed to create tap due to format mismatch"
        //   で ObjC 例外→クラッシュするため。デバイスやサンプルレート変更にも強い）
        inputNode.installTap(onBus: 0, bufferSize: 2048, format: nil) { [weak self] buffer, _ in
            guard let self else { return }
            if box.converter == nil || box.converter?.inputFormat != buffer.format {
                box.converter = AVAudioConverter(from: buffer.format, to: outFmt)
            }
            guard let conv = box.converter else { return }
            let rms = STTService.rms(of: buffer)
            let converted = STTService.convertToPCM16(buffer, using: conv, to: outFmt)
            // タップは任意スレッドから来るため、状態更新はメインへ。
            DispatchQueue.main.async {
                guard self.generation == gen else { return }
                if let converted { self.pcm16.append(converted) }
                // プリロール中は古い音声を捨ててリングバッファ化（際限ない録音を防ぐ）。
                if !self.listenActive, self.pcm16.count > self.prerollMaxBytes {
                    self.pcm16.removeFirst(self.pcm16.count - self.prerollMaxBytes)
                }
                if rms >= self.speechRMSThreshold {
                    self.hasSpeech = true
                    self.scheduleSilenceFinalize(gen: gen)
                }
            }
        }

        if !audioEngine.isRunning {
            audioEngine.prepare()
            do {
                try audioEngine.start()
            } catch {
                finish(.failure("録音を開始できません: \(error.localizedDescription)"), gen: gen)
                return
            }
        }
        isCapturing = true
        listenActive = !preroll
        onPhase?(.listening)

        if preroll {
            // listen が来ないままなら一定時間で止める。
            DispatchQueue.main.asyncAfter(deadline: .now() + prerollMaxSeconds) { [weak self] in
                guard let self, self.generation == gen, !self.listenActive else { return }
                self.stopEngine()
                self.onPhase?(.idle)
            }
        }
    }

    /// 無音が silenceInterval 続いたら確定。発話のたびに呼び直して延長する。
    /// listen 採用前（プリロール中）は finalizeAndTranscribe が continuation を見て
    /// 何もしないので、無音タイマーが空振りするだけで害はない。
    private func scheduleSilenceFinalize(gen: Int) {
        silenceToken += 1
        let token = silenceToken
        DispatchQueue.main.asyncAfter(deadline: .now() + silenceInterval) { [weak self] in
            guard let self, self.generation == gen, self.silenceToken == token else { return }
            self.finalizeAndTranscribe(gen: gen)
        }
    }

    /// 録音を止め、溜めた音声をサーバへ投げてテキストを返す。
    private func finalizeAndTranscribe(gen: Int) {
        guard gen == generation, continuation != nil else { return }
        stopEngine()

        // 発話が無い / 極端に短い場合は無音扱い（空文字）で即返す。
        let minBytes = 16_000 * 2 / 5 // 0.2 秒未満は無視
        guard hasSpeech, pcm16.count >= minBytes else {
            finish(.success(text: ""), gen: gen)
            return
        }

        // 音声ファイル(WAV)生成フェーズ。
        onPhase?(.encoding)
        // 先頭に短い無音を足して、認識モデルの頭欠けを防ぐ（のりしろ）。
        let padBytes = Int(leadingPadSeconds * 16_000) * MemoryLayout<Int16>.size
        var padded = Data(count: padBytes)
        padded.append(pcm16)
        let wav = STTService.wavData(fromPCM16: padded)
        let language = Self.asrLanguage(for: captureLocale)
        // AI へ送って認識するフェーズ。
        onPhase?(.transcribing)
        Task { [weak self] in
            guard let self else { return }
            let result = await self.client.transcribe(wav: wav, language: language)
            guard self.generation == gen else { return }
            switch result {
            case .success(let text):
                self.finish(.success(text: text), gen: gen)
            case .failure(let error):
                self.finish(.failure(error.message), gen: gen)
            }
        }
    }

    private func stopEngine() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        isCapturing = false
        listenActive = false
    }

    private func finish(_ response: SpeechResponse, gen: Int) {
        guard gen == generation, let cont = continuation else { return }
        continuation = nil
        stopEngine()
        cont.resume(returning: response)
    }

    // MARK: - Audio helpers

    /// 入力バッファ（float32）を 16kHz mono Int16(LE) に変換して Data で返す。
    /// タップスレッドから呼ぶため nonisolated static。
    nonisolated private static func convertToPCM16(
        _ buffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        to outputFormat: AVAudioFormat
    ) -> Data? {
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return nil
        }

        var consumed = false
        var convError: NSError?
        let status = converter.convert(to: out, error: &convError) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, let channel = out.int16ChannelData else { return nil }
        let count = Int(out.frameLength)
        guard count > 0 else { return nil }
        // Apple Silicon はリトルエンディアンなので Int16 の生バイトをそのまま WAV に使える。
        return Data(bytes: channel[0], count: count * MemoryLayout<Int16>.size)
    }

    /// バッファの RMS（0.0〜1.0）。VAD 用。
    private static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        let samples = channelData[0]
        var sum: Float = 0
        for i in 0..<frames {
            let v = samples[i]
            sum += v * v
        }
        return (sum / Float(frames)).squareRoot()
    }

    /// 16bit PCM mono 16kHz の WAV バイト列を組み立てる。
    private static func wavData(fromPCM16 pcm: Data) -> Data {
        let sampleRate: UInt32 = 16_000
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let dataSize = UInt32(pcm.count)
        let riffSize = 36 + dataSize

        var header = Data()
        func append(_ string: String) { header.append(contentsOf: string.utf8) }
        func append(le32 value: UInt32) { withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) } }
        func append(le16 value: UInt16) { withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) } }

        append("RIFF"); append(le32: riffSize); append("WAVE")
        append("fmt "); append(le32: 16); append(le16: 1) // PCM
        append(le16: channels); append(le32: sampleRate); append(le32: byteRate)
        append(le16: blockAlign); append(le16: bitsPerSample)
        append("data"); append(le32: dataSize)

        return header + pcm
    }

    /// ロケール(ja-JP) → Qwen3-ASR の language 名(Japanese)。
    private static func asrLanguage(for locale: String) -> String {
        let lower = locale.lowercased()
        if lower.hasPrefix("ja") { return "Japanese" }
        if lower.hasPrefix("en") { return "English" }
        if lower.hasPrefix("zh") { return "Chinese" }
        if lower.hasPrefix("ko") { return "Korean" }
        return "Japanese"
    }

    // MARK: - Authorization

    private static func requestMicrophoneAuthorization() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { cont in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    cont.resume(returning: granted)
                }
            }
        default:
            return false
        }
    }
}

// MARK: - Qwen3-ASR HTTP クライアント

/// `~/.claude-talk-mcp/asr` のローカル Qwen3-ASR サーバと話すクライアント。
///
/// OpenAI 互換の `POST /v1/audio/transcriptions`（multipart）へ WAV を送り、
/// `{"text": "..."}` を受け取る。未起動なら start-server.sh を起動して待つ。
struct ASRClient {
    let baseURL = URL(string: "http://127.0.0.1:8765")!

    private var asrDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude-talk-mcp/asr", isDirectory: true)
    }
    private var apiKeyURL: URL { asrDirectory.appendingPathComponent("api-key.txt") }
    private var startScriptURL: URL { asrDirectory.appendingPathComponent("start-server.sh") }

    private var apiKey: String? {
        (try? String(contentsOf: apiKeyURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Health / lifecycle

    func isHealthy() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("health"))
        request.timeoutInterval = 3
        guard
            let (_, response) = try? await URLSession.shared.data(for: request),
            let http = response as? HTTPURLResponse
        else { return false }
        return http.statusCode == 200
    }

    /// サーバが応答しなければ start-server.sh を起動し、health が通るまで待つ。
    func ensureServerRunning() async -> Bool {
        if await isHealthy() { return true }

        let script = startScriptURL
        guard FileManager.default.fileExists(atPath: script.path) else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path]
        do {
            try process.run()
        } catch {
            return false
        }

        // 初回はモデルロードで時間がかかる。最大 90 秒待つ。
        for _ in 0..<45 {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if await isHealthy() { return true }
        }
        return false
    }

    // MARK: Transcription

    func transcribe(wav: Data, language: String) async -> Result<String, ASRError> {
        let boundary = "claude-talk-\(UInt64.random(in: 0..<UInt64.max))"
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/audio/transcriptions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = Self.multipartBody(boundary: boundary, wav: wav, language: language)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(ASRError(message: "音声認識サーバの応答が不正です"))
            }
            guard http.statusCode == 200 else {
                let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?
                    .flatMap { ($0["detail"] as? String) ?? ($0["error"] as? [String: Any])?["message"] as? String }
                return .failure(ASRError(message: "音声認識に失敗しました (HTTP \(http.statusCode)): \(detail ?? "")"))
            }
            guard
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let text = object["text"] as? String
            else {
                return .failure(ASRError(message: "音声認識結果を解釈できません"))
            }
            return .success(text.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            return .failure(ASRError(message: "音声認識サーバに接続できません: \(error.localizedDescription)"))
        }
    }

    private static func multipartBody(boundary: String, wav: Data, language: String) -> Data {
        var body = Data()
        func appendString(_ string: String) { body.append(contentsOf: string.utf8) }

        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"language\"\r\n\r\n")
        appendString("\(language)\r\n")

        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n")
        appendString("json\r\n")

        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"file\"; filename=\"speech.wav\"\r\n")
        appendString("Content-Type: audio/wav\r\n\r\n")
        body.append(wav)
        appendString("\r\n")

        appendString("--\(boundary)--\r\n")
        return body
    }
}
