#!/bin/bash
# claude-talk-mcp: ローカル音声認識 HTTP サーバの起動スクリプト。
# 音声アプリ (STTService.swift の ASRClient) が 127.0.0.1:8765 に応答が無い時に起動する。
#
# 使うエンジンは設定ファイル $ASR_DIR/backend の 1 語で切り替える (無ければ qwen3):
#   speechcpp … speech.cpp の `speech serve` で Haas-ja-v1.0 (日本語専用、既定は F16 の重み)
#   qwen3     … 自作 FastAPI ラッパ (asr_server.py) で Qwen3-ASR-1.7B (MLX)
# 音声アプリも同じファイルを読んで、送る language の形 (ja / Japanese) を合わせる。
# 切り替えたら、動いているサーバを止める (lsof -nP -iTCP:8765 -sTCP:LISTEN で PID を見て kill)。
# 次の listen で音声アプリがこのスクリプトを起動し直す。
#
# どちらも 127.0.0.1 だけで待ち受ける (0.0.0.0 にしない)。
ASR_DIR="$HOME/.claude-talk-mcp/asr"
HOST=127.0.0.1
PORT=8765

BACKEND="$(tr -d '[:space:]' < "$ASR_DIR/backend" 2>/dev/null)"
BACKEND="${BACKEND:-qwen3}"

case "$BACKEND" in
  speechcpp)
    # speech.cpp: 公式インストーラ (install.sh) が ~/.local/bin/speech に置く。
    SPEECH_BIN="$HOME/.local/bin/speech"
    # 重み: NAME[:TYPE]。初回だけ Hugging Face から取得し、以後は ~/Library/Caches/speech.cpp を使う。
    SPEECH_ASR_MODEL="haas-ja-v1.0:f16"
    export SPEECH_NO_UPDATE_CHECK=1
    echo "[asr] $(date '+%F %T') backend=speechcpp model=$SPEECH_ASR_MODEL" >> "$ASR_DIR/server.log"
    exec "$SPEECH_BIN" serve "$SPEECH_ASR_MODEL" --host "$HOST" --port "$PORT" --language ja \
      >> "$ASR_DIR/server.log" 2>&1
    ;;
  qwen3)
    # Qwen3-ASR ローカル HTTP サーバ（自作 OpenAI 互換ラッパ）
    export MLX_ASR_HOST="$HOST"
    export MLX_ASR_PORT="$PORT"
    export MLX_ASR_MODEL="Qwen/Qwen3-ASR-1.7B"
    export MLX_ASR_LANGUAGE=Japanese
    export MLX_ASR_API_KEY="$(cat "$ASR_DIR/api-key.txt")"
    echo "[asr] $(date '+%F %T') backend=qwen3 model=$MLX_ASR_MODEL" >> "$ASR_DIR/server.log"
    exec "$ASR_DIR/.venv/bin/python" "$ASR_DIR/asr_server.py" >> "$ASR_DIR/server.log" 2>&1
    ;;
  *)
    echo "[asr] $(date '+%F %T') unknown backend '$BACKEND' in $ASR_DIR/backend (speechcpp | qwen3)" >> "$ASR_DIR/server.log"
    exit 1
    ;;
esac
