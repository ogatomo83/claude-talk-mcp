# /voice を別の Mac に入れる

Claude Code の `/voice` (claude-talk MCP の `speak` / `listen`、読み上げ中の割り込みつき) を新しい Mac に入れる手順。
ここで入れるのは **direct モード** (MCP サーバー自身が録音・読み上げし、ローカルの speech.cpp に流す)。メニューバーの音声アプリ (`claude-talk-mcp.xcodeproj`) と Qwen3-ASR (`asr/`) は要らない。

## 前提

- **Apple Silicon の Mac** (arm64)。speech.cpp の macOS 版は arm64 だけで、録音・読み上げは macOS の VPIO (Voice Processing I/O) と AVAudioEngine を使う
- **macOS 13 以上** (確かめたのは macOS 26.3)
- **Xcode の Command Line Tools** (Swift 6 以上)。Xcode 本体は要らない。無ければ `xcode-select --install`
- **Claude Code** (`claude` が PATH にあること)
- Homebrew・Python の追加・uv は要らない (`/usr/bin/python3` は Command Line Tools のものを確認に使うだけ)
- ネットワーク: GitHub (speech.cpp のリリース、Swift の依存 swift-sdk) と Hugging Face (モデル) に繋がること
- 空き容量: 約 3 GB (Irodori も入れるなら約 4 GB)、メモリ: 動かしている間 約 3 GB

## 要るもの

| もの | 取得元 | 大きさ | 置き場所 |
|---|---|---|---|
| speech.cpp 0.11.2 (`speech`) | [nyosegawa/speech.cpp](https://github.com/nyosegawa/speech.cpp) のリリース (公式 `install.sh`、SHA256SUMS で照合) | 21 MB | `~/.local/share/speech.cpp/0.11.2/`、`~/.local/bin/speech` |
| 聞き取り: Haas-ja-v1.0 F16 (`haas-ja-v1.0:f16`) | [sakasegawa/Haas-ja-v1.0-GGUF](https://huggingface.co/sakasegawa/Haas-ja-v1.0-GGUF) | 1.23 GB | `~/Library/Caches/speech.cpp/models/` (`SPEECH_MODEL_DIR` で変更可) |
| 話し始め・終わりの検出: Silero VAD (`silero-vad`) | [sakasegawa/silero-vad-GGUF](https://huggingface.co/sakasegawa/silero-vad-GGUF) | 1.2 MB | 同上 |
| 読み上げ: Qwen3-TTS 0.6B Q8_0 (`qwen3-tts-0.6b`、話者 serena) | [sakasegawa/Qwen3-TTS-12Hz-0.6B-CustomVoice-GGUF](https://huggingface.co/sakasegawa/Qwen3-TTS-12Hz-0.6B-CustomVoice-GGUF) | 1.21 GB | 同上 |
| (任意) 読み上げ: Irodori-TTS Q5_K (`irodori-tts-mf:q5_k`) | [sakasegawa/Irodori-TTS-v4.1-Small-MF-GGUF](https://huggingface.co/sakasegawa/Irodori-TTS-v4.1-Small-MF-GGUF) | 0.95 GB | 同上 |
| MCP サーバー `claude-talk-mcp-server` | このリポの `MCPServer/` を `swift build -c release` | 10 MB | `MCPServer/.build/arm64-apple-macosx/release/` |
| Swift の依存 swift-sdk (0.9 以上) | [modelcontextprotocol/swift-sdk](https://github.com/modelcontextprotocol/swift-sdk) (ビルド時に SwiftPM が取得) | 数 MB | SwiftPM のキャッシュ |
| 設定の雛形 | このリポの `templates/claude-talk-mcp/` | 数 KB | `~/.claude-talk-mcp/` |
| `/voice` skill | このリポの `skills/voice/SKILL.md` | 6 KB | `~/.claude/skills/voice/` |

モデルはリポに入れない。`speech pull <名前>` が speech.cpp のカタログ (版ごとに固定の revision と SHA-256) どおりに Hugging Face から取る。変換の手順は要らない (GGUF に変換済みのものを取る)。

## 手順

```sh
xcode-select --install            # 入っていなければ。終わるまで待つ
git clone <このリポ> ~/claude-talk-mcp
cd ~/claude-talk-mcp
git checkout direct-mode-speechcpp   # direct モードが main に入るまで
scripts/install.sh --serve-test
```

`install.sh` がやること (どれも、済んでいれば確かめて飛ばす。何度実行してもよい):

1. 前提の確認 (arm64・macOS 13+・Command Line Tools・Swift 6・curl・claude)
2. speech.cpp 0.11.2 を公式インストーラで入れる (`--no-modify-path`。PATH・`.zshrc` は変えない。違う版が入っていれば 0.11.2 に入れ替える)
3. `swift build -c release` (初回は数分)
4. `speech pull haas-ja-v1.0:f16 silero-vad qwen3-tts-0.6b` (取得済みなら照合だけ。止まった取得は続きから)
5. 設定と skill を置く
   - `~/.claude-talk-mcp/mode` (`direct`)、`direct/settings.json` (`{}` = 全部既定値)、`direct/keywords.txt` (聞き取りの語彙)、`direct/readings.txt` (読み上げの読み)
   - 無ければ置く。あって中身が同じなら何もしない。**違えば今のものを残す** (`--replace-config` の時だけ `~/.claude-talk-mcp/_backup-install-<日時>/` に退避してから置き換える)
   - skill は、違えば `~/.claude/skills/voice.bak.<日時>` に退避してから置き換える
6. `claude mcp add -s user claude-talk -- <ビルドした claude-talk-mcp-server>`。既に**別のコマンド**で登録されていれば触らない (`--replace-mcp` で登録し直す)
7. `scripts/check.py` で音を出さずに確かめる。`--serve-test` を付けると、別のポート (18766 / 18768) で MCP サーバーを direct モードで起動し、MCP サーバー自身に 2 つの speech serve を立てさせ、読み上げの serve で作った WAV (再生しない) を聞き取りの serve で書き起こす。終わったら立てた serve を止める

終わったら:

1. Claude Code を起動し直す
2. `/voice` と打つ。初回の `listen` / `speak` で**マイクの許可**を聞かれるので、Claude Code を動かしているアプリ (ターミナル・iTerm2 など) を許可する (システム設定 > プライバシーとセキュリティ > マイク)

### よく使うオプション

| オプション | 内容 |
|---|---|
| `--with-irodori` | Irodori-TTS のモデルも取る (`settings.json` に `"tts": "irodori"` で使う。声ファイルは下記) |
| `--home DIR` / `--skills-dir DIR` | 設定・skill の置き場所を変える。`--home` が既定でなければ MCP の登録に `CLAUDE_TALK_HOME` を付ける |
| `--skip-speech` / `--skip-build` / `--skip-models` / `--skip-mcp` | その段を飛ばす |
| `--dry-run` | 何をするかだけ表示 |

確認だけをやり直す: `/usr/bin/python3 -I scripts/check.py [--serve-test]`

`check.py` の登録の確認 (`claude mcp get`) は Claude Code が MCP サーバーを一度起動するので、serve (:8766 / :8768) がまだ無ければその時に立ち上がる (音は出ない。メモリを約 3 GB 使う)。

## 動き方 (誰が何を起動するか)

- Claude Code が MCP サーバー `claude-talk-mcp-server` を stdio で起動する (セッションごと)
- `~/.claude-talk-mcp/mode` が `direct` なら、MCP サーバーは起動した時に、動いていなければ次の 2 つを立てる (127.0.0.1 だけ、`setsid` で切り離すので MCP サーバーが終わっても残り、次のセッションも使う)
  - 聞き取り: `speech serve haas-ja-v1.0:f16 silero-vad --port 8766 --language ja` (ログ `direct/serve.log`、pid `direct/serve.pid`)
  - 読み上げ: `speech serve qwen3-tts-0.6b --port 8768 --language ja` (ログ `direct/tts-serve-qwen.log`、pid `direct/tts-serve-qwen.pid`)
  - Irodori を選んだ時は `:8767` (`direct/tts-serve.*`)
- 録音・再生・割り込みの判定は MCP サーバーの中 (VPIO でエコーを消す)。マイクは `direct/mic.lock` で 1 セッションだけが使う
- 時間のログは `~/.claude-talk-mcp/logs/timing.jsonl`
- serve を止める: `kill $(cat ~/.claude-talk-mcp/direct/serve.pid) $(cat ~/.claude-talk-mcp/direct/tts-serve-qwen.pid)` (次の MCP 起動でまた立つ)

## 設定

`~/.claude-talk-mcp/direct/settings.json` は全部省略可 (`{}` で既定)。呼び出しのたびに読み直すので再起動は要らない。主な項目:

| 項目 | 既定 | 内容 |
|---|---|---|
| `port` / `ttsPort` | 8766 / 8768 | serve のポート (ぶつかる時に変える) |
| `speechBin` | `~/.local/bin/speech` | speech.cpp の場所 |
| `tts` | `qwen` | `qwen` / `irodori` / `avspeech` (macOS の声) |
| `ttsSpeed` | 1 | 読み上げの速さ (0.5〜2) |
| `silenceMs` | 500 | 話し終わりとみなす無音 |
| `bargeIn.enabled` | true | 読み上げ中に話したら止める |

`keywords.txt` は聞き取り (Haas) の語彙 (`表記=読み,読み`、`-表記` で組み込みから外す)、`readings.txt` は読み上げ前の読み替え (`表記=読み`)。

### Irodori の声ファイル (任意)

Irodori は `--add-voice` で声ファイル (`*.voice.gguf`) を足して使う。既定の `irodori-f-low` の声ファイル (`direct/voices/irodori-f-low.voice.gguf`、36 KB) は元の Mac で参照録音から作ったもので、このリポには入れていない。使うなら元の Mac から `~/.claude-talk-mcp/direct/voices/` に写すか、`speech voice` で作り直す。

## 移さないもの

- `~/.claude-talk-mcp/_backup-*`、`logs/`、`direct/*.log` `*.pid` `*.lock`、`voice/` (claude-talk-voice の記録)
- `~/.claude-talk-mcp/asr/` (メニューバーの音声アプリ用。`api-key.txt` はその場で作る秘密なので写さない)
- `~/.claude-talk-mcp/src/speech.cpp` (参照用の checkout。動かすのには使わない)

## うまくいかない時

- `serve が立ちません` → `direct/serve.log` / `tts-serve-qwen.log`。ポートが使われていれば `settings.json` の `port` / `ttsPort` を変える
- `マイクの許可がありません` → 上のマイクの許可。Claude Code を動かすアプリを変えたら、そのアプリでも許可が要る
- `/voice` が出ない → Claude Code の再起動、`ls ~/.claude/skills/voice/SKILL.md`
- `claude mcp list` で claude-talk が `Failed` → `MCPServer/.build/.../claude-talk-mcp-server` があるか (リポを動かしたら `scripts/install.sh --replace-mcp`)
