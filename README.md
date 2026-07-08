# claude-talk-mcp

macOS で **Claude と日本語の音声で会話**するための仕組み。Claude の返答を macOS の音声で読み上げ（TTS）、あなたの発話をローカルの AI モデル **Qwen3‑ASR** で認識（STT）して Claude に返します。認識はすべてローカル実行で、音声がクラウドに送られることはありません。

## アーキテクチャ

2 プロセス構成。Claude クライアントが MCP サーバーを stdio で起動し、MCP サーバーは常駐する音声アプリへ Unix ドメインソケット経由でリクエストを転送します。音声アプリは書き起こしをローカルの Qwen3‑ASR HTTP サーバーに委譲します。

```
┌──────────┐  stdio(MCP) ┌───────────────┐ Unix socket ┌─────────────────────┐
│ Claude   │ ──────────▶ │ MCP サーバー   │ ──────────▶ │ 音声アプリ (SwiftUI) │
│ (client) │ ◀────────── │ speak / listen │ ◀────────── │ TTS + 録音/VAD       │
└──────────┘             └───────────────┘             └──────────┬──────────┘
                                                    HTTP(localhost) │  マイク/スピーカー
                                                                    ▼
                                                    ┌─────────────────────────────┐
                                                    │ Qwen3‑ASR サーバー (Python)  │
                                                    │ MLX / OpenAI 互換 /transcribe │
                                                    └─────────────────────────────┘
```

- **MCP サーバー**（`MCPServer/`, Swift Package）… Claude から spawn される短命プロセス。`speak` / `listen` ツールを提供し、ソケットへ転送するだけ。
- **音声アプリ**（`claude-talk-mcp/`, SwiftUI・メニューバー常駐）… マイク権限を保持し、TTS と録音・無音検出（VAD）を担当。録音した WAV を ASR サーバーへ POST。
- **Qwen3‑ASR サーバー**（`asr/`, Python + MLX）… `Qwen/Qwen3-ASR-1.7B` をローカル実行し、OpenAI 互換の `POST /v1/audio/transcriptions` で書き起こしを返す。音声アプリ起動時に自動起動される。

## 必要環境

- **Apple Silicon** の Mac（MLX による Qwen3‑ASR 実行に必須）
- **macOS 26+**（アプリのデプロイターゲット。必要に応じて Xcode で引き下げ可）
- **Xcode 26+**
- **[uv](https://docs.astral.sh/uv/)**（ASR 用 Python 環境の構築に使用）

## ビルド / セットアップ

### 1. Qwen3‑ASR サーバー（ローカル STT）

```bash
./asr/setup.sh
```

`~/.claude-talk-mcp/asr/` に Python 仮想環境を作り、`mlx-qwen3-asr[serve]` を導入、サーバースクリプトとローカル用 API キーを配置します。初回起動時にモデル（約 3.4GB）が自動ダウンロードされます。音声アプリが自動起動するので、通常は手動起動不要です。

### 2. MCP サーバー（Swift Package）

```bash
cd MCPServer
swift build -c release
# 生成物: MCPServer/.build/release/claude-talk-mcp-server
```

### 3. 音声アプリ（メニューバー常駐）

`claude-talk-mcp.xcodeproj` を Xcode で開き、`claude-talk-mcp` スキームを **Run（⌘R）**。メニューバーに波形アイコンが常駐します。初回の音声認識時に**マイクの許可ダイアログ**が出るので「許可」してください（Hardened Runtime + `com.apple.security.device.audio-input` entitlement 済み）。

コマンドラインでビルドする場合:

```bash
xcodebuild -project claude-talk-mcp.xcodeproj -scheme claude-talk-mcp -configuration Debug build
```

## Claude への登録（MCP）

ビルドした MCP サーバーのバイナリを MCP クライアントに登録します。Claude Code の例:

```bash
claude mcp add claude-talk -- /ABSOLUTE/PATH/claude-talk-mcp/MCPServer/.build/release/claude-talk-mcp-server
```

登録後、`speak` と `listen` の 2 ツールが使えるようになります。

## 使い方

1. 音声アプリを起動しておく（メニューバーに常駐）。
2. MCP サーバーを登録した Claude クライアントから会話する。
3. 付属の `/voice` スキル（`~/.claude/skills/voice`）を使うと、読み上げ→聞き取り→また読み上げ…と往復ループになります。合図（「どうぞ」等）の直後に話し始めても、**プリロール録音**により頭から認識されます。

メニューバーのポップオーバーには現在の状態（待機中／読み上げ中／聞き取り中／音声を生成中／AIが認識中）とログが表示されます。

### 提供ツール

| ツール | 内容 |
|--------|------|
| `speak` | テキストを macOS の音声で読み上げる（完了まで待機）。`voice` / `rate` 指定可 |
| `listen` | マイク発話を認識してテキストを返す。無音約 1.2 秒 または `timeout`（既定 30 秒）で確定 |

## トラブルシューティング

- **マイク許可ダイアログが出ない / 「権限なし」になる**
  アプリは Hardened Runtime 有効なので `com.apple.security.device.audio-input` entitlement が必要（設定済み）。**Clean Build Folder すると再署名で許可が外れる**ことがある。その場合は
  `tccutil reset Microphone <アプリのbundle id>` → 再起動 → 許可し直し。通常の ⌘R では維持される。
- **Xcode に `Combine` / `@Observable` 関連の赤エラーが出る**
  SourceKit がマクロ展開に失敗したときの幽霊エラー。実ビルド（`xcodebuild ... clean build`）は通る。Clean Build Folder → 再ビルド、または Xcode 再起動で消える。
- **認識サーバーに接続できない**
  `~/.claude-talk-mcp/asr/start-server.sh` を手動実行してログを確認。`curl http://127.0.0.1:8765/health` で疎通確認。

## ライセンス

未定。
