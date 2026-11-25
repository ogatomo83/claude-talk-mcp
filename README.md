# claude-talk-mcp

Claude Code と**日本語の声で会話する** MCP サーバー (`speak` / `listen`) と `/voice` skill。
聞き取り・読み上げはすべてこの Mac の中 (speech.cpp) で動き、音声をクラウドに送らない。

- 聞き取り: Haas-ja-v1.0 F16 + Silero VAD (speech.cpp の `speech serve`、:8766)
- 読み上げ: Qwen3-TTS 0.6B の話者 serena (speech.cpp の `speech serve`、:8768)
- 読み上げ中に話すと止まる (割り込み、既定 on)。割り込んだ発話は次の `listen` が頭から受け取る
- **Caps Lock がオンの間だけマイクが入る** (既定 on)。オフの間は聞き取りも割り込みも起きず、`listen` はオンになるまで待つ。macOS の許可は増えない (下の「Caps Lock でマイクを入れる」)

この branch (`direct-mode-speechcpp`) の **direct モード**の手順を下に書く。メニューバーの音声アプリと Qwen3-ASR を使う前の作り (app モード) は末尾の「[app モード (旧)](#app-モード-旧)」。

---

## この branch で /voice を「元の Mac と同じ状態」で動かす

ここで言う「同じ状態」= speech.cpp の版・モデルのファイルと SHA-256・聞き取りの語彙・読み上げの読み・設定の既定値・MCP サーバーのビルド・登録の形が、この branch を作った Mac と一致すること。基準は [`scripts/reference.json`](scripts/reference.json) にあり、`scripts/check.py` が突き合わせる (手順 5)。

詳しい中身 (何がどこに入るか、オプション、設定項目) は [INSTALL.md](INSTALL.md)。

### 0. 前提

| もの | 要るもの | 確かめ方 |
|---|---|---|
| Mac | **Apple Silicon** (arm64)。speech.cpp の macOS 版は arm64 だけ | `uname -m` → `arm64` |
| macOS | **13 以上** (元の Mac は macOS 26.3) | `sw_vers -productVersion` |
| Xcode の Command Line Tools | Swift **6 以上** (元の Mac は Swift 6.2.4)。Xcode 本体は要らない | `swift --version`。無ければ `xcode-select --install` |
| Claude Code | `claude` が PATH にあること (元の Mac は 2.1.332) | `claude --version` |
| 空きディスク | 約 3 GB (モデル 2.4 GB + speech.cpp + ビルド) | `df -h ~` |
| メモリ | 動かしている間 約 3 GB (2 つの serve) | — |
| ネットワーク | GitHub (speech.cpp・Swift の依存) と Hugging Face (モデル) に繋がること | — |
| ポート | 127.0.0.1 の **8766 / 8768** が空いていること (確認の時だけ 18766 / 18768 も) | `lsof -nP -iTCP:8766 -iTCP:8768 -sTCP:LISTEN` が何も出さない |

Homebrew・Python の追加・uv は要らない (`/usr/bin/python3` を確認に使うだけ)。

### 1. clone

```sh
git clone -b direct-mode-speechcpp https://github.com/ogatomo83/claude-talk-mcp.git ~/claude-talk-mcp
cd ~/claude-talk-mcp
```

置き場所はどこでもよい。ただし MCP の登録はビルドしたバイナリの絶対パスを指すので、後でリポを動かしたら `scripts/install.sh --replace-mcp` を流し直す。

### 2. install.sh

```sh
scripts/install.sh --serve-test
```

何度流してもよい (済んでいるものは確かめて飛ばす)。初回は数分〜20 分 (ほとんどがモデル 2.4 GB の取得と `swift build`。速い回線なら 2 分ほど)。やること:

1. 前提の確認
2. speech.cpp **0.11.2** を `~/.local/bin/speech` に入れる (公式インストーラ、SHA256SUMS で照合。PATH・`.zshrc` は変えない)
3. `swift build -c release` (MCPServer/)
4. `speech pull haas-ja-v1.0:f16 silero-vad qwen3-tts-0.6b` (SHA-256 を照合。止まったら続きから)
5. 設定 `~/.claude-talk-mcp/` (`mode`=`direct`、`direct/settings.json`=`{}`、`direct/keywords.txt`、`direct/readings.txt`) と skill `~/.claude/skills/voice/` を置く。既にある設定は残す
6. `claude mcp add -s user claude-talk -- <ビルドした claude-talk-mcp-server>`
7. `scripts/check.py --serve-test` (音を出さない確認。下の 5. と同じもの + 別ポートで TTS→ASR を通す)

最後がこう終われば成功:

```
==> 基準との一致 (scripts/reference.json)
  ok    43 項目すべて基準と同じ (speech.cpp 0.11.2、語彙 84 語、読み 40 語、tts qwen / serena、bargeIn on、capsLock on、MCP のビルド 10f30c1)
==> serve の通し (別ポート 18766 / 18768、音は出さない)
  ok    MCP サーバーが 2 つの serve を起動 (…秒)
  ok    聞き取りの serve: Haas-ja-v1.0, silero-vad
  ok    読み上げ: 「今日は良い天気ですね。」→ WAV … KB (…秒、再生はしない)
  ok    聞き取り: 「今日はいい天気ですね」 (…秒)
  ok    テスト用の serve (pid …, :18766) を止めました
  ok    テスト用の serve (pid …, :18768) を止めました

全部通りました。マイクの許可だけは音を出さずに確かめられないので、初回の /voice で許可してください。
```

途中で `error:` や `NG` が出たら、下の「うまくいかない時」。

### 3. Claude Code を起動し直す

skill と MCP の登録は起動時に読まれる。開いている Claude Code を全部終わらせてから、もう一度 `claude` を起動する。

```sh
claude mcp list        # claude-talk: … - ✓ Connected
```

(`claude mcp list` は MCP サーバーを一度起動する。その時に :8766 / :8768 の serve が裏で立ち上がる。音は出ない)

### 4. マイクの許可

初めて `/voice` の `listen` が動いた時に、macOS がマイクの許可を聞く。**Claude Code を動かしているアプリ** (ターミナル / iTerm2 / VS Code など) を許可する。
後から直す時: システム設定 > プライバシーとセキュリティ > マイク で、そのアプリを ON。

### 5. 同じ状態になったかを確かめる

```sh
cd ~/claude-talk-mcp
/usr/bin/python3 -I scripts/check.py --strict
```

音は出さない、マイクも開けない、本番の設定・ログにも書かない。`--strict` は基準との違いを NG にする (終了コード 1)。期待される出力 (パスは Mac ごとに違う):

```
==> Mac
  ok    Apple Silicon (arm64)
  ok    macOS 26.x
==> speech.cpp とモデル
  ok    speech.cpp 0.11.2, C API 4.3
  ok    モデルの置き場所: ~/Library/Caches/speech.cpp/models
  ok    haas-ja-v1.0:f16 (1.23 GB) 取得済み
  ok    silero-vad:f32 (1.2 MB) 取得済み
  ok    qwen3-tts-0.6b:q8_0 (1.21 GB) 取得済み
==> 設定 (~/.claude-talk-mcp) と skill (~/.claude/skills)
  ok    mode = direct
  ok    direct/settings.json (JSON として読める)
  ok    direct/keywords.txt
  ok    direct/readings.txt
  ok    skill: ~/.claude/skills/voice/SKILL.md
==> MCP サーバー (stdio)
  ok    serverInfo: claude-talk-mcp 1.2.0
  ok    tools: speak, listen
==> Claude Code への登録 (~/.claude.json)
  ok    claude-talk -> ~/claude-talk-mcp/MCPServer/.build/arm64-apple-macosx/release/claude-talk-mcp-server (stdio, args [], env 無し)
==> 基準との一致 (scripts/reference.json)
  ok    43 項目すべて基準と同じ (speech.cpp 0.11.2、語彙 84 語、読み 40 語、tts qwen / serena、bargeIn on、capsLock on、MCP のビルド 10f30c1)

全部通りました。マイクの許可だけは音を出さずに確かめられないので、初回の /voice で許可してください。
```

突き合わせる値 (`scripts/reference.json`):

| 項目 | 基準の値 |
|---|---|
| speech.cpp | 0.11.2 |
| 聞き取りのモデル | `Haas-616M-ja-v1.0-F16.gguf` SHA-256 `f752e02f68c1dfff795900e40aa82e5302976fb5360080fcbd330d8b3c992cd8` |
| VAD | `silero-vad-309K-v6.2-F32.gguf` SHA-256 `2fc312514e5fc4fa4ffd02b25c76a4853fa4130e8fb9777d01502183b01238cb` |
| 読み上げのモデル | `Qwen3-TTS-12Hz-0.6B-CustomVoice-Q8_0.gguf` SHA-256 `f606ea3981aa42762b16db9a94826d2d560eb60f0b102001618f40d5a2f78cc6` |
| 聞き取りの語彙 | 84 語 (組み込み 9 語 + `keywords.txt`。Docker の読みは「ドッカー」だけ、クラウド・開発・AI のモデル名などのエンジニア用語)。中身の SHA-256 も比べる |
| 読み上げの読み | 40 語 (組み込みだけ。`readings.txt` は例のコメントのみ) |
| `settings.json` | `{}` (上書き無し = 全部コードの既定値) |
| 効いている既定値 | `tts`=qwen、`ttsModel`=qwen3-tts-0.6b、`ttsVoiceName`=serena、`ttsPort`=8768、`port`=8766、`asrModel`=haas-ja-v1.0:f16、`vadModel`=silero-vad、`silenceMs`=500、`ttsSpeed`=1、`bargeIn.enabled`=true、`bargeIn.bargeInMs`=300、`capsLock.enabled`=true |
| `mode` | direct |
| MCP サーバー | MCPServer/ の最後の commit `10f30c1` から、変更なしでビルドしたもの |
| MCP の登録 | user スコープ、stdio、args 無し、env 無し、コマンドはこのリポのビルド |
| skill | リポの `skills/voice/SKILL.md` と同じ |

モデルの SHA-256 は speech.cpp のカタログの値 (`speech pull` が取得時にファイルと照合済み)。

### 6. 声で 1 往復してみる

1. Claude Code で `/voice` と打つ
2. Claude が短く挨拶を読み上げる (serena の声)。読み終わったら合図なしで聞き取りに入るので、そのまま話す (例「今日の天気の話をしよう」)
3. 0.5 秒黙ると話し終わりとみなされ、Claude が答えを読み上げる。これで 1 往復
4. 「終わり」「ストップ」「またね」などで終わる

**割り込みの確かめ方**

1. `/voice` の中で「Swift の歴史を長めに話して」など、長い返事を頼む
2. 読み上げの途中で 0.3 秒以上話し続ける (例「ちょっと待って、短くして」)
3. 読み上げがそこで止まり、Claude が今の発話 (「短くして」) に答えれば成功。割り込んだ言葉の頭が欠けていないことも見る
4. ログでも確かめられる:

```sh
grep '"speak.done"' ~/.claude-talk-mcp/logs/timing.jsonl | tail -3
# 割り込んだ回は "interrupted":true、"finished":false
grep '"speak.recv"' ~/.claude-talk-mcp/logs/timing.jsonl | tail -1
# "barge_in":true (割り込みが有効)
```

スピーカーで使う時、Claude 自身の声で止まることがある (VPIO のエコー除去で大半は消える)。気になる時はヘッドホンにするか、`settings.json` に `{"bargeIn": {"enabled": false}}` で割り込みを切る (その時 `check.py --strict` は `bargeIn.enabled` の違いを NG にする)。

### Caps Lock でマイクを入れる

Caps Lock がオンの間だけ、マイクの音を聞き取り (`listen`) と読み上げ中の割り込みに使う。オフの間の音は送らない (0 にする)。

- オフの間の `listen`: オンになるまで待つ (`timeout` はオンの間だけ数える)。`capsLock.offMaxWaitSeconds` (既定 300 秒) たってもオフなら、1 行目が `caps_lock_off` の文を返す (skill はもう一度 `listen` を呼ぶ)
- オンにしてすぐ話しても頭は切れない (オンに気付く直前の読みの `capsLock.leadMs` = 150ms 前の音から使う)
- 話している途中でオフにしたら、そこまでの発話を返す
- 状態は 50ms ごとに読みに行く (`CGEventSource.flagsState`)。**入力監視・アクセシビリティの許可は要らない**。負荷は 1 コアの 0.02% ほど (読む処理だけ。50ms ごとに起きる分を足して 0.09% ほど)。マイクを開けている間だけ読む
- 切る: `settings.json` に `{"capsLock": {"enabled": false}}` (次の `listen` から効く。いつでも聞く、今までの動き)
- 「入力ソース」の設定で「Caps Lock キーで ABC 入力ソースを切り替える」を入れていると、Caps Lock を短く押しても入力ソースが変わるだけでロックが入らない (長押しで入る)。この使い方ではその設定を切る

ログ:

```sh
grep -E '"caps_lock.change"|"listen.caps_' ~/.claude-talk-mcp/logs/timing.jsonl | tail -5
# caps_lock.change {"on":true,"flags":true,"hid":true}  ← オン・オフに気付いた時 (2 つの読み方の値も残す)
# listen.caps_wait → listen.caps_on {"waited_ms":...}    ← オフで待ち、オンになった
```

### うまくいかない時

**ポートが埋まっている** (`127.0.0.1:8766 が使用中` / serve が立たない)

```sh
lsof -nP -iTCP:8766 -iTCP:8768 -sTCP:LISTEN
```

- 出てきたのが前に立てた `speech serve` なら、止めて立て直してよい: `kill $(cat ~/.claude-talk-mcp/direct/serve.pid) $(cat ~/.claude-talk-mcp/direct/tts-serve-qwen.pid)` (次の MCP 起動で立ち直る)
- 別のアプリなら、`~/.claude-talk-mcp/direct/settings.json` を `{"port": 8776, "ttsPort": 8778}` のように変える (呼び出しのたびに読み直すので再起動は要らない。`check.py --strict` はポートの違いを NG にするので `--strict` なしで見る)
- `--serve-test` の 18766 / 18768 が埋まっている時は `scripts/check.py --serve-test --asr-port 19766 --tts-port 19768`

**マイクの許可**

- 「マイクの許可がありません」/ 何を話しても空が返る → システム設定 > プライバシーとセキュリティ > マイク で Claude Code を動かすアプリを ON にして、そのアプリを起動し直す
- 一覧に出てこない・許可したのに効かない → `tccutil reset Microphone com.apple.Terminal` (iTerm2 は `com.googlecode.iterm2`) で許可を消し、アプリを起動し直して `/voice` で聞き直させる
- 別のアプリから Claude Code を動かしたら、そのアプリでも許可が要る

**モデルの取得の失敗** (`speech pull` が止まる・SHA-256 が合わない)

- もう一度 `scripts/install.sh` を流す (取得済みは照合だけ、途中のものは続きから)
- 1 つずつ取る: `SPEECH_NO_UPDATE_CHECK=1 ~/.local/bin/speech pull haas-ja-v1.0:f16` (`silero-vad` / `qwen3-tts-0.6b` も)
- huggingface.co に繋がるか (社内の proxy など)、空きディスク (`df -h ~`) を見る
- 置き場所を変えるなら `SPEECH_MODEL_DIR=<dir>` を付けて install.sh を流す (MCP サーバーから起動する serve にも同じ環境変数が要る)

**そのほか**

| 症状 | 見る所 |
|---|---|
| speech.cpp の取得で止まる | github.com に繋がるか。`~/.local/bin/speech --version` |
| `swift build` が失敗 | `xcode-select -p`、Command Line Tools の更新 (`softwareupdate --list`)。Swift 6 以上 |
| `claude mcp list` で claude-talk が Failed | `MCPServer/.build/arm64-apple-macosx/release/claude-talk-mcp-server` があるか。リポを動かしたなら `scripts/install.sh --replace-mcp` |
| `/voice` が出ない | Claude Code の再起動、`ls ~/.claude/skills/voice/SKILL.md` |
| 読み上げが macOS の声になる | Qwen の serve が立たず退避した。`~/.claude-talk-mcp/direct/tts-serve-qwen.log` |
| 聞き取りが立たない | `~/.claude-talk-mcp/direct/serve.log` |
| `check.py` が「基準と違う」 | 表示された項目を上の表と見比べる。自分で設定を変えたなら想定どおり。雛形に戻すなら `scripts/install.sh --replace-config` (今のものは `_backup-install-<日時>/` に退避) |

### 元の Mac と違ってよいもの (移さないもの)

| もの | 理由 |
|---|---|
| skill `/voice` の数行 | 元の Mac の `~/.claude/skills/voice/SKILL.md` には、個人のメモ (日付と人の呼び名入りの理由書き)、メニューバーのアプリ前提の確認の文、app モードの「無音約 1.2 秒」の説明が残っている。リポの版はそこを direct モード向けに直しただけで、読み上げ・聞き取り・割り込み (`interrupted`) の扱いは同じ。`check.py` は「リポの skill と同じか」を見る |
| `keywords.txt` のコメント行 | 元の Mac のものは日付入りのコメント。語彙そのもの (84 語) は同じで、`check.py` は語彙の中身で比べる |
| 元の Mac にだけあるモデル (Irodori-TTS Q5_K、Qwen3-TTS 1.7B、Haas Q8_0、Nemotron の話者分離) | 聴き比べなどで取ったもので、`/voice` の既定では使わない。Irodori を使う時は `scripts/install.sh --with-irodori` (INSTALL.md) |
| Irodori の声ファイル `direct/voices/irodori-f-low.voice.gguf` | 参照の録音から作った声のデータなので、公開のリポには入れない。既定の qwen では使わない |
| メニューバーの音声アプリ・`~/.claude-talk-mcp/asr/` | app モード用。direct モードでは使わない。`asr/api-key.txt` はその Mac で作る秘密 |
| `~/.claude-talk-mcp/_backup-*`・`logs/`・`direct/*.log` `*.pid` `*.lock`・`voice/` | その Mac の作業の控えと記録 |
| MCP の登録のパス | clone した場所を指す。違うのはパスだけで、形 (user スコープ・stdio・env 無し) は同じ |

### 基準を更新する

MCPServer/ や雛形を変えて commit したら、その Mac で `/usr/bin/python3 -I scripts/check.py --print-state > scripts/reference.json` を流して基準も commit する (`mcp_source_commit` が変わるため)。

---

## 動き方 (direct モード)

```
┌─────────────┐ stdio (MCP) ┌──────────────────────────┐  HTTP / WebSocket  ┌──────────────────────────────────┐
│ Claude Code │ ──────────▶ │ claude-talk-mcp-server    │ ─────────────────▶ │ speech serve :8766               │
│  /voice     │ ◀────────── │  speak / listen           │                    │  Haas-ja-v1.0 F16 + Silero VAD   │
└─────────────┘             │  録音・再生 (VPIO)         │ ─────────────────▶ │ speech serve :8768               │
                            │  割り込みの判定            │                    │  Qwen3-TTS 0.6B (serena)         │
                            └──────────────────────────┘                    └──────────────────────────────────┘
```

- Claude Code がセッションごとに MCP サーバーを stdio で起動する
- MCP サーバーは起動時に、動いていなければ 2 つの `speech serve` を立てる (127.0.0.1 だけ。切り離して起動するので次のセッションも使う)
- マイク・スピーカーは MCP サーバーが直接使う (VPIO でエコーを消す)。マイクは `direct/mic.lock` で 1 セッションだけ
- 設定 `~/.claude-talk-mcp/direct/settings.json` は呼び出しのたびに読み直す (項目は INSTALL.md)
- 1 往復の時間は `~/.claude-talk-mcp/logs/timing.jsonl`。表にする: `/usr/bin/python3 tools/timing-report.py`

### 提供ツール

| ツール | 内容 |
|---|---|
| `speak` | テキストを読み上げる (鳴り終わるまで待つ)。返り値の 1 行目は `done` / `interrupted` (読み上げ中に話したので止めた。読み上げた所が続く) / `stopped` |
| `listen` | 発話を書き起こして返す。無音 0.5 秒 (`silenceMs`) か `timeout` (既定 30 秒) で確定。直前の `speak` に割り込んだ発話は頭から返す |

---

## app モード (旧)

`~/.claude-talk-mcp/mode` が `app` (または無い) の時の作り。MCP サーバーはメニューバー常駐の音声アプリへ Unix ソケットで転送し、音声アプリが macOS の声で読み上げ、書き起こしをローカルの Qwen3-ASR (または speech.cpp + Haas、:8765) に頼む。direct モードでは使わない。

```
┌──────────┐  stdio(MCP) ┌───────────────┐ Unix socket ┌─────────────────────┐
│ Claude   │ ──────────▶ │ MCP サーバー   │ ──────────▶ │ 音声アプリ (SwiftUI) │
│ (client) │ ◀────────── │ speak / listen │ ◀────────── │ TTS + 録音/VAD       │
└──────────┘             └───────────────┘             └──────────┬──────────┘
                                                    HTTP(localhost) │
                                                                    ▼
                                                    ┌─────────────────────────────┐
                                                    │ Qwen3‑ASR サーバー (Python)  │
                                                    │ MLX / OpenAI 互換 /transcribe │
                                                    └─────────────────────────────┘
```

必要環境: Apple Silicon、macOS 26+、Xcode 26+、[uv](https://docs.astral.sh/uv/)。

1. Qwen3-ASR: `./asr/setup.sh` (`~/.claude-talk-mcp/asr/` に Python 環境・サーバー・ローカル用 API キーを置く。初回にモデル約 3.4 GB)。軽い代わりに `./asr/setup-speechcpp.sh` で speech.cpp + Haas (`~/.claude-talk-mcp/asr/backend` を `speechcpp` に)。切り替えは `echo qwen3 > ~/.claude-talk-mcp/asr/backend` (または `speechcpp`) → `kill $(lsof -nP -t -iTCP:8765 -sTCP:LISTEN)`
2. MCP サーバー: `cd MCPServer && swift build -c release`
3. 音声アプリ: `claude-talk-mcp.xcodeproj` を Xcode で開き `claude-talk-mcp` スキームを Run (⌘R)。初回にマイクの許可。コマンドラインなら `xcodebuild -project claude-talk-mcp.xcodeproj -scheme claude-talk-mcp -configuration Debug build`
4. 登録: `claude mcp add claude-talk -- <リポ>/MCPServer/.build/release/claude-talk-mcp-server`
5. skill: `./install-skills.sh` (環境変数 `SKILLS_DIR` / `REF` / `SKILLS`。既存と違えば `voice.bak.<日時>` に退避)

トラブルシューティング:

- マイクの許可が外れる: Clean Build Folder で再署名されると外れることがある。`tccutil reset Microphone <アプリの bundle id>` → 再起動 → 許可し直し
- Xcode に `Combine` / `@Observable` の赤エラー: SourceKit のマクロ展開の幽霊エラー。実ビルドは通る。Clean Build Folder か Xcode の再起動で消える
- 認識サーバーに繋がらない: `~/.claude-talk-mcp/asr/start-server.sh` を手で動かしてログを見る。`curl http://127.0.0.1:8765/health`
- 配布アプリ (Releases の zip) が「開発元を確認できません」で開けない: アドホック署名 (未 notarize) のため。Finder で右クリック →「開く」で一度許可すれば以後は通常起動できる

### コマンドラインでまとめてビルド (make、Xcode 本体が要る)

`make` で app モードの MCP サーバーと音声アプリを一括ビルドし、`dist/` に出す。direct モードの準備 (speech.cpp・モデル・登録) は `scripts/install.sh` が行うので、direct モードだけなら `make` は要らない。

```bash
make build      # → dist/claude-talk-mcp.app, dist/claude-talk-mcp-server
make zip        # → dist/claude-talk-mcp-app-macos.zip (配布用)
make clean      # build/ dist/ MCPServer/.build を消す (install.sh で登録したバイナリも消えるので、後で install.sh を流し直す)
```

アプリはアドホック署名 (`Signature=adhoc`) で出力され、マイク用 entitlement も埋め込まれる。

### ビルド済みのダウンロード

[Releases](../../releases) からビルド済みの `.app` (zip) と MCP サーバーのバイナリを入手できる (app モード用。direct モードは上の手順 1〜2 で clone と install.sh を使う)。

- **自動**: タグ (`v*`) を push すると GitHub Actions (`.github/workflows/release.yml`) が macOS でビルドして Release を作る。手動実行の時は Actions のアーティファクトとしてもダウンロードできる
- **手元から**: `make release VERSION=v0.1.0` (`gh` の認証が要る)

配布アプリは未 notarize なので初回は右クリック →「開く」。ASR サーバーは別に `./asr/setup.sh` が要る。CI のランナーには macOS 26 SDK / Xcode 26 が要り、未対応なら手元の `make release` を使う。

## ライセンス

未定。
