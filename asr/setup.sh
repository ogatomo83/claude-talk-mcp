#!/bin/bash
#
# Qwen3-ASR ローカルサーバのセットアップ。
# ~/.claude-talk-mcp/asr/ に venv を作り、モデル実行に必要な依存を入れ、
# サーバスクリプトと起動スクリプトを配置し、ローカル用 API キーを生成する。
# 音声アプリ(claude-talk-mcp)はこの場所を前提に自動起動する。
#
# 必要: uv (https://docs.astral.sh/uv/), Apple Silicon, macOS
#
set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/.claude-talk-mcp/asr"

echo "==> セットアップ先: $DEST"
mkdir -p "$DEST"

echo "==> venv 作成 (Python 3.12)"
uv venv --python 3.12 "$DEST/.venv"

echo "==> 依存インストール (mlx-qwen3-asr[serve])"
uv pip install --python "$DEST/.venv/bin/python" "mlx-qwen3-asr[serve]"

echo "==> スクリプト配置"
cp "$SRC_DIR/asr_server.py" "$DEST/asr_server.py"
cp "$SRC_DIR/start-server.sh" "$DEST/start-server.sh"
chmod +x "$DEST/start-server.sh"

if [ ! -f "$DEST/api-key.txt" ]; then
  echo "==> ローカル用 API キー生成"
  uuidgen | tr -d '\n' > "$DEST/api-key.txt"
fi

echo "==> 完了。初回はモデル(Qwen/Qwen3-ASR-1.7B, 約3.4GB)を起動時に自動DLします。"
echo "    手動起動して確認する場合: $DEST/start-server.sh"
