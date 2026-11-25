#!/bin/bash
#
# speech.cpp + Haas-ja-v1.0 (日本語専用の音声認識) のセットアップ。
# - speech.cpp を公式インストーラで ~/.local/bin/speech に入れる (PATH や .zshrc は変えない)
# - Haas-ja-v1.0 の F16 の重みを取得する (~/Library/Caches/speech.cpp)
# - start-server.sh を配置し、~/.claude-talk-mcp/asr/backend を speechcpp にする
#
# Qwen3-ASR に戻す: echo qwen3 > ~/.claude-talk-mcp/asr/backend して、動いているサーバを止める。
#
set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/.claude-talk-mcp/asr"
SPEECH="$HOME/.local/bin/speech"
export SPEECH_NO_UPDATE_CHECK=1

mkdir -p "$DEST"

if [ ! -x "$SPEECH" ]; then
  echo "==> speech.cpp をインストール (~/.local/bin/speech)"
  curl -fsSL https://raw.githubusercontent.com/nyosegawa/speech.cpp/main/install.sh | sh -s -- --no-modify-path
fi
"$SPEECH" --version

echo "==> Haas-ja-v1.0 (F16, 1.23 GB) を取得"
"$SPEECH" pull haas-ja-v1.0:f16

echo "==> start-server.sh を配置し、backend を speechcpp に"
cp "$SRC_DIR/start-server.sh" "$DEST/start-server.sh"
chmod +x "$DEST/start-server.sh"
echo speechcpp > "$DEST/backend"

echo "==> 完了。音声アプリが次の listen (または起動時) に $DEST/start-server.sh を起動します。"
echo "    手動で確かめる場合: $DEST/start-server.sh & 後に curl http://127.0.0.1:8765/health"
