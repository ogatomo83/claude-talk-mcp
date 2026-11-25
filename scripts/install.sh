#!/bin/bash
#
# /voice (claude-talk MCP の direct モード + voice skill) を、この Mac に入れる。
# 何度実行してもよい。既にあるものは確かめて飛ばし、既存の設定は上書きしない。
#
#   scripts/install.sh [options]
#
# やること:
#   1. 前提の確認 (Apple Silicon・macOS 13+・Xcode の Command Line Tools・swift 6・curl)
#   2. speech.cpp (speech) を ~/.local/bin/speech に入れる (版を固定。PATH・.zshrc は変えない)
#   3. MCP サーバーをビルド (swift build -c release)
#   4. モデルを取得 (speech pull。Hugging Face から、SHA-256 を照合)
#   5. 設定 (~/.claude-talk-mcp) と /voice skill (~/.claude/skills/voice) を置く
#   6. Claude Code に MCP サーバー claude-talk を登録 (user スコープ)
#   7. 音を出さない動作確認 (scripts/check.py)
#
# options:
#   --home DIR            設定の置き場所 (既定 ~/.claude-talk-mcp)。既定以外なら MCP の登録に CLAUDE_TALK_HOME を付ける
#   --skills-dir DIR      skill の置き場所 (既定 ~/.claude/skills)
#   --speech-version X    speech.cpp の版 (既定 0.11.2。動作を確かめた版)
#   --with-irodori        Irodori-TTS (任意の読み上げ、0.95 GB) も取得する
#   --skip-speech         speech.cpp を入れない (既にある前提)
#   --skip-build          ビルドしない
#   --skip-models         モデルを取得しない
#   --skip-mcp            Claude Code に登録しない
#   --replace-mcp         claude-talk が別のコマンドで登録済みなら、消して登録し直す (既定は触らない)
#   --replace-config      設定ファイルが雛形と違う時も雛形で置き換える (既存は _backup-install-<日時>/ に退避)
#   --serve-test          最後の確認で、別ポート (18766 / 18768) に serve を起こして TTS→ASR を通す (音は出さない)
#   --dry-run             何をするかだけ表示する
#   -h, --help
#
# 環境変数: SPEECH_MODEL_DIR (モデルの置き場所。既定 ~/Library/Caches/speech.cpp/models)
#
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
TALK_HOME="$HOME/.claude-talk-mcp"
SKILLS_DIR="$HOME/.claude/skills"
SPEECH_VERSION="0.11.2"
SPEECH_BIN="$HOME/.local/bin/speech"
WITH_IRODORI=0 SKIP_SPEECH=0 SKIP_BUILD=0 SKIP_MODELS=0 SKIP_MCP=0
REPLACE_MCP=0 REPLACE_CONFIG=0 SERVE_TEST=0 DRY=0
MODELS=(haas-ja-v1.0:f16 silero-vad qwen3-tts-0.6b)

say()  { printf '%s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
run()  { if [ "$DRY" = 1 ]; then say "  (dry-run) $*"; else "$@"; fi; }
usage() { sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [ $# -gt 0 ]; do
  case "$1" in
    --home) TALK_HOME="$2"; shift ;;
    --skills-dir) SKILLS_DIR="$2"; shift ;;
    --speech-version) SPEECH_VERSION="$2"; shift ;;
    --with-irodori) WITH_IRODORI=1 ;;
    --skip-speech) SKIP_SPEECH=1 ;;
    --skip-build) SKIP_BUILD=1 ;;
    --skip-models) SKIP_MODELS=1 ;;
    --skip-mcp) SKIP_MCP=1 ;;
    --replace-mcp) REPLACE_MCP=1 ;;
    --replace-config) REPLACE_CONFIG=1 ;;
    --serve-test) SERVE_TEST=1 ;;
    --dry-run) DRY=1 ;;
    -h|--help) usage ;;
    *) die "知らないオプション: $1 (--help)" ;;
  esac
  shift
done
TALK_HOME="${TALK_HOME%/}"
[ "$WITH_IRODORI" = 1 ] && MODELS+=(irodori-tts-mf:q5_k)
export SPEECH_NO_UPDATE_CHECK=1
STAMP="$(date +%Y%m%d-%H%M%S)"

# ------------------------------------------------------------------ 1. 前提
step "1. 前提の確認"
[ "$(uname -s)" = Darwin ] || die "macOS 専用です (VPIO・AVAudioEngine を使う)"
[ "$(uname -m)" = arm64 ] || die "Apple Silicon (arm64) 専用です (speech.cpp の macOS 版が arm64 だけ)"
macos_major="$(sw_vers -productVersion | cut -d. -f1)"
[ "$macos_major" -ge 13 ] || die "macOS 13 以上が要ります (今: $(sw_vers -productVersion))"
say "  macOS $(sw_vers -productVersion) / arm64"
if ! xcode-select -p >/dev/null 2>&1; then
  die "Xcode の Command Line Tools がありません。xcode-select --install を実行し、終わってからもう一度"
fi
command -v swift >/dev/null 2>&1 || die "swift がありません (xcode-select --install)"
swift_ver="$(swift --version 2>&1 | sed -n 's/.*Swift version \([0-9]*\)\.\([0-9]*\).*/\1.\2/p' | head -1)"
[ "${swift_ver%%.*}" -ge 6 ] 2>/dev/null || die "Swift 6 以上が要ります (今: ${swift_ver:-不明})。Command Line Tools / Xcode を更新してください"
say "  Swift $swift_ver ($(xcode-select -p))"
command -v curl >/dev/null 2>&1 || die "curl がありません"
[ -x /usr/bin/python3 ] || die "/usr/bin/python3 がありません (Command Line Tools に入っています)"
CLAUDE_BIN="$(command -v claude || true)"
if [ -z "$CLAUDE_BIN" ]; then
  say "  warn: claude (Claude Code) が PATH にありません。MCP の登録は飛ばします (入れてから --skip-speech --skip-models で再実行)"
  SKIP_MCP=1
else
  say "  Claude Code: $CLAUDE_BIN"
fi

# ------------------------------------------------------------------ 2. speech.cpp
step "2. speech.cpp $SPEECH_VERSION ($SPEECH_BIN)"
if [ "$SKIP_SPEECH" = 1 ]; then
  say "  飛ばします (--skip-speech)"
else
  have=""
  [ -x "$SPEECH_BIN" ] && have="$("$SPEECH_BIN" --version 2>/dev/null | sed -n 's/^speech.cpp \([0-9.]*\).*/\1/p')"
  if [ "$have" = "$SPEECH_VERSION" ]; then
    say "  既に $have が入っています"
  else
    [ -n "$have" ] && say "  今は $have。$SPEECH_VERSION に入れ替えます (公式インストーラが他の版を消します)"
    # 公式インストーラ: リリースの SHA256SUMS で照合して ~/.local/share/speech.cpp/<版>/ に展開し、~/.local/bin/speech をリンク
    if [ "$DRY" = 1 ]; then
      say "  (dry-run) curl -fsSL https://raw.githubusercontent.com/nyosegawa/speech.cpp/main/install.sh | sh -s -- --version $SPEECH_VERSION --no-modify-path"
    else
      curl -fsSL https://raw.githubusercontent.com/nyosegawa/speech.cpp/main/install.sh \
        | sh -s -- --version "$SPEECH_VERSION" --no-modify-path
    fi
  fi
  [ "$DRY" = 1 ] || "$SPEECH_BIN" --version
fi

# ------------------------------------------------------------------ 3. ビルド
step "3. MCP サーバーのビルド (MCPServer/)"
if [ "$SKIP_BUILD" = 1 ]; then
  say "  飛ばします (--skip-build)"
else
  run swift build -c release --package-path "$REPO/MCPServer"
fi
BIN_DIR="$(swift build -c release --show-bin-path --package-path "$REPO/MCPServer")"
MCP_BIN="$BIN_DIR/claude-talk-mcp-server"
if [ "$DRY" = 0 ]; then
  [ -x "$MCP_BIN" ] || die "$MCP_BIN がありません (ビルドに失敗?)"
fi
say "  $MCP_BIN"
say "  $BIN_DIR/claude-talk-voice (常駐の声のプロセス。/voice には要らない)"

# ------------------------------------------------------------------ 4. モデル
step "4. モデル (${MODELS[*]})"
if [ "$SKIP_MODELS" = 1 ]; then
  say "  飛ばします (--skip-models)"
else
  # 取得済みなら SHA-256 の照合だけで済む。途中で止まった取得は続きから。
  for m in "${MODELS[@]}"; do
    run "$SPEECH_BIN" pull "$m"
  done
fi

# ------------------------------------------------------------------ 5. 設定と skill
step "5. 設定 ($TALK_HOME) と skill ($SKILLS_DIR/voice)"
BACKUP="$TALK_HOME/_backup-install-$STAMP"
backup_file() { # $1 = TALK_HOME からの相対パス
  run mkdir -p "$(dirname "$BACKUP/$1")"
  run cp -p "$TALK_HOME/$1" "$BACKUP/$1"
}
place() { # $1 = 雛形からの相対パス
  local rel="$1" src="$REPO/templates/claude-talk-mcp/$1" dest="$TALK_HOME/$1"
  if [ ! -e "$dest" ]; then
    run mkdir -p "$(dirname "$dest")"
    run cp "$src" "$dest"
    say "  置きました: $rel"
  elif cmp -s "$src" "$dest"; then
    say "  同じです:   $rel"
  elif [ "$REPLACE_CONFIG" = 1 ]; then
    backup_file "$rel"
    run cp "$src" "$dest"
    say "  置き換え:   $rel (前のもの -> $BACKUP/$rel)"
  else
    say "  そのまま:   $rel (雛形と違うが、今の設定を残す。雛形にするなら --replace-config)"
  fi
}
run mkdir -p "$TALK_HOME/direct" "$TALK_HOME/logs"
for f in mode direct/settings.json direct/keywords.txt direct/readings.txt; do place "$f"; done

if [ -f "$TALK_HOME/direct/settings.json" ]; then
  /usr/bin/python3 -I -c 'import json,sys; json.load(open(sys.argv[1]))' "$TALK_HOME/direct/settings.json" \
    || die "$TALK_HOME/direct/settings.json が JSON として読めません"
fi

skill_src="$REPO/skills/voice" skill_dest="$SKILLS_DIR/voice"
if [ -e "$skill_dest" ] && diff -qr "$skill_src" "$skill_dest" >/dev/null 2>&1; then
  say "  同じです:   skill voice"
else
  if [ -e "$skill_dest" ]; then
    run mv "$skill_dest" "$skill_dest.bak.$STAMP"
    say "  退避:       $skill_dest -> $skill_dest.bak.$STAMP"
  fi
  run mkdir -p "$skill_dest"
  run cp -R "$skill_src/." "$skill_dest/"
  say "  置きました: skill voice -> $skill_dest"
fi

# ------------------------------------------------------------------ 6. MCP 登録
step "6. Claude Code への登録 (claude-talk、user スコープ)"
MCP_ENV=()
if [ "$TALK_HOME" != "$HOME/.claude-talk-mcp" ]; then MCP_ENV=(-e "CLAUDE_TALK_HOME=$TALK_HOME"); fi
if [ "$SKIP_MCP" = 1 ]; then
  say "  飛ばします"
  say "  手で登録する: claude mcp add -s user claude-talk ${MCP_ENV[*]+${MCP_ENV[*]} }-- $MCP_BIN"
else
  current="" current_home=""
  want_home=""
  [ "$TALK_HOME" != "$HOME/.claude-talk-mcp" ] && want_home="$TALK_HOME"
  # 今の登録は Claude Code の設定ファイルから読む (`claude mcp get` は MCP サーバーを一度起動してしまうため使わない)
  cfg="${CLAUDE_CONFIG_DIR:+$CLAUDE_CONFIG_DIR/.claude.json}"; cfg="${cfg:-$HOME/.claude.json}"
  if [ -f "$cfg" ]; then
    out="$(/usr/bin/python3 -I -c '
import json, sys
try:
    r = (json.load(open(sys.argv[1])).get("mcpServers") or {}).get("claude-talk") or {}
except ValueError:
    r = {}
print(r.get("command", "")); print((r.get("env") or {}).get("CLAUDE_TALK_HOME", ""))
' "$cfg")"
    current="$(printf '%s\n' "$out" | sed -n 1p)"
    current_home="$(printf '%s\n' "$out" | sed -n 2p)"
  fi
  if [ -z "$current" ]; then
    run "$CLAUDE_BIN" mcp add -s user claude-talk ${MCP_ENV[@]+"${MCP_ENV[@]}"} -- "$MCP_BIN"
    say "  登録しました: $MCP_BIN"
  elif [ "$current" = "$MCP_BIN" ] && [ "$current_home" = "$want_home" ]; then
    say "  登録済みです: $current${current_home:+ (CLAUDE_TALK_HOME=$current_home)}"
  elif [ "$REPLACE_MCP" = 1 ]; then
    say "  前の登録: $current${current_home:+ (CLAUDE_TALK_HOME=$current_home)}"
    run "$CLAUDE_BIN" mcp remove claude-talk -s user
    run "$CLAUDE_BIN" mcp add -s user claude-talk ${MCP_ENV[@]+"${MCP_ENV[@]}"} -- "$MCP_BIN"
    say "  登録し直しました: $MCP_BIN"
  else
    say "  別のコマンド・設定で登録済みなので触りません: $current${current_home:+ (CLAUDE_TALK_HOME=$current_home)}"
    say "  このビルドに向けるなら --replace-mcp を付けて再実行"
  fi
fi

# ------------------------------------------------------------------ 7. 確認
step "7. 音を出さない確認 (scripts/check.py)"
if [ "$DRY" = 1 ]; then
  say "  (dry-run) 飛ばします"
  exit 0
fi
check_args=(--home "$TALK_HOME" --skills-dir "$SKILLS_DIR" --speech-bin "$SPEECH_BIN" --mcp-bin "$MCP_BIN")
[ "$WITH_IRODORI" = 1 ] && check_args+=(--with-irodori)
[ "$SKIP_MCP" = 1 ] && check_args+=(--no-claude)
[ "$SERVE_TEST" = 1 ] && check_args+=(--serve-test)
/usr/bin/python3 -I "$REPO/scripts/check.py" "${check_args[@]}"

cat <<EOF

完了。次にやること:
  1. Claude Code を起動し直す (skill と MCP を読み直すため。動いている claude を全部終わらせてから)
  2. /voice と打つ。初回はマイクの許可を聞かれるので、Claude Code を動かしているアプリ (ターミナル / iTerm2 など) を許可
     (システム設定 > プライバシーとセキュリティ > マイク)
  聞き取りの serve (:8766) と読み上げの serve (:8768) は、MCP サーバーが初めて起動した時に自分で立ち上げます。
EOF
