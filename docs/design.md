# claude-talk-mcp 設計書

Claude と音声でやりとりするための macOS 向け Swift プロジェクト。
Claude が話した内容を読み上げ（TTS）、ユーザーの発話を認識（STT）して Claude に返す。

- 対象 OS: macOS 13+
- 言語: Swift 6 / 全て Swift で実装
- MCP SDK: [modelcontextprotocol/swift-sdk](https://github.com/modelcontextprotocol/swift-sdk) 0.12.1

---

## 1. 全体アーキテクチャ

2 プロセス構成。Claude クライアントが MCP サーバーを stdio で起動し、MCP サーバーは
常駐する音声アプリへ Unix ドメインソケット経由でリクエストを転送する。

```
┌──────────────┐   stdio    ┌─────────────────┐  Unix socket  ┌──────────────────────┐
│ Claude       │ ─────────▶ │ MCP サーバー     │ ────────────▶ │ 音声アプリ (macOS)    │
│ (client)     │  MCP/JSON  │ (headless, SPM) │  改行区切JSON  │ 常駐 / SwiftUI       │
│              │ ◀───────── │  speak / listen │ ◀──────────── │  TTS + STT           │
└──────────────┘            └─────────────────┘               └──────────────────────┘
                                                                  ▲          │
                                                          マイク入力      スピーカー出力
```

### なぜ 2 プロセスに分けるか

- **MCP サーバー**はセッション毎に Claude から spawn される短命プロセス。マイク・音声認識の
  TCC 権限を持たせたくない（毎回の権限付与や隔離の問題）。
- **音声アプリ**は常駐アプリバンドルとして TCC 権限（マイク・音声認識）を保持し続ける。
  macOS ではマイクアクセスにアプリバンドルが必要なため、音声処理はここに集約する。
- TTS・STT はアプリ内の独立したサービス（モジュール）として実装するが、権限とプロセスライフ
  サイクルの都合上、別プロセスには分けず 1 つのアプリ内に置く。

---

## 2. コンポーネント

### 2.1 MCP サーバー（`MCPServer/`）

- SPM の executable target `claude-talk-mcp-server`。
- `StdioTransport` で Claude と接続。
- 公開ツール:
  - `speak` — テキストを音声アプリに送り読み上げさせる。完了まで待つ。
  - `listen` — 音声アプリにマイク入力の認識を依頼し、認識テキストを返す。
- 音声アプリへは Unix ソケットクライアントとして接続。アプリが未起動・未接続なら
  ツールはエラー（`isError: true`）を返す。

### 2.2 音声アプリ（`claude-talk-mcp/` Xcode プロジェクト）

- SwiftUI の常駐アプリ。UI は接続状態・直近の発話/認識ログを表示（メニューバー常駐も検討）。
- **Unix ソケットサーバー**: `speech.sock` を listen し、複数リクエストを逐次処理。
- **TTS サービス**: `AVSpeechSynthesizer`。読み上げ完了を delegate で検知して応答。
- **STT サービス**: `Speech` フレームワーク（`SFSpeechRecognizer` + `AVAudioEngine`）。
  マイクから録音し、無音区間 or タイムアウトで確定して認識テキストを返す。
- 権限: `NSMicrophoneUsageDescription`、`NSSpeechRecognitionUsageDescription` を Info.plist に。
  App Sandbox はローカル開発ツールとして無効化（`/Users/<user>/.claude-talk-mcp/` へアクセスするため）。

---

## 3. IPC プロトコル

### 3.1 ソケット

- パス: `~/.claude-talk-mcp/speech.sock`（両プロセスとも `HOME` から算出）
- ディレクトリは音声アプリ起動時に作成。既存の stale なソケットファイルは起動時に unlink。

### 3.2 メッセージ形式

改行区切り JSON（NDJSON）。1 リクエスト = 1 行、1 レスポンス = 1 行。

**リクエスト（MCP → アプリ）**

```json
{ "type": "speak",  "text": "こんにちは" }
{ "type": "listen", "timeout": 30, "locale": "ja-JP" }
```

**レスポンス（アプリ → MCP）**

```json
{ "ok": true }                              // speak 完了
{ "ok": true, "text": "認識されたテキスト" }   // listen 成功
{ "ok": false, "error": "説明メッセージ" }     // 失敗（権限拒否・タイムアウト等）
```

### 3.3 フィールド

| メッセージ | フィールド   | 型     | 必須 | 説明                                    |
|-----------|-------------|--------|------|-----------------------------------------|
| speak     | `text`      | string | ✓    | 読み上げるテキスト                        |
| speak     | `voice`     | string |      | 音声識別子（未指定はシステム既定）          |
| speak     | `rate`      | number |      | 読み上げ速度                              |
| listen    | `timeout`   | number |      | 最大待機秒数（既定 30）                    |
| listen    | `locale`    | string |      | 認識ロケール（既定 `ja-JP`）              |

---

## 4. MCP ツール仕様

### `speak`

- 説明: 与えられたテキストを音声で読み上げる。
- 入力: `{ "text": string (required), "voice"?: string, "rate"?: number }`
- 動作: アプリに `speak` を送信 → 読み上げ完了の応答を待って `content: [.text("done")]` を返す。

### `listen`

- 説明: マイクからユーザーの発話を認識してテキストを返す。
- 入力: `{ "timeout"?: number, "locale"?: string }`
- 動作: アプリに `listen` を送信 → 認識テキストを `content: [.text(認識結果)]` で返す。
  タイムアウト・無音時は空文字またはエラー。

---

## 5. エラーハンドリング

- アプリ未起動 / ソケット接続失敗: MCP ツールが「音声アプリが起動していません」を `isError` で返す。
- 権限拒否（マイク・音声認識）: アプリが `{ok:false, error:"permission denied"}` を返し、MCP が伝播。
- タイムアウト: `listen` が既定 30 秒で確定。無音なら空結果。
- 排他制御: TTS 再生中の `listen`、STT 録音中の `speak` を避けるためアプリ側でキュー管理。

---

## 6. ディレクトリ構成

```
claude-talk-mcp/
├── docs/
│   └── design.md                     # 本書
├── MCPServer/                         # MCP サーバー (SPM)
│   ├── Package.swift
│   └── Sources/claude-talk-mcp-server/
│       ├── main.swift                # サーバー起動・ツール登録
│       └── SpeechSocketClient.swift  # Unix ソケットクライアント
├── claude-talk-mcp/                   # 音声アプリ (Xcode / SwiftUI)
│   ├── claude_talk_mcpApp.swift
│   ├── ContentView.swift             # 状態表示 UI
│   ├── SpeechSocketServer.swift      # Unix ソケットサーバー
│   ├── TTSService.swift              # AVSpeechSynthesizer ラッパー
│   └── STTService.swift              # SFSpeechRecognizer ラッパー
└── claude-talk-mcp.xcodeproj
```

---

## 7. 実装ステップ

1. **共通**: ソケットパスと NDJSON メッセージ型を両側で共有できる形に定義。
2. **MCP サーバー**: `main.swift` でツール登録 + `SpeechSocketClient` を実装（アプリ無しでも `swift build` で検証可能）。
3. **音声アプリ**: Unix ソケットサーバー → TTS → STT の順に実装。
4. **結合**: アプリ起動 → Claude から MCP 経由で `speak` / `listen` を実行して疎通確認。
5. **登録**: Claude の MCP 設定にサーバーを登録（stdio, ビルド済みバイナリのパス）。

---

## 8. 決定事項（確定）

- プロセス構成: **MCP サーバー + 音声アプリ 1 つ**（TTS/STT はアプリ内の独立サービス）。
- エンジン: **Apple 純正**（TTS = `AVSpeechSynthesizer` / STT = `Speech` フレームワーク）。
- IPC: **Unix ドメインソケット + 改行区切り JSON**。

## 9. 未決事項 / 今後の検討

- 常駐形態: 通常ウィンドウ or メニューバー常駐（`MenuBarExtra`）。
- STT の確定条件: 無音検出の閾値、部分認識結果のストリーミング可否。
- 音声・言語の既定値と切り替え UI。
- アプリ未起動時に MCP から自動起動するか（`open -a` など）。
