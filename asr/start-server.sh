#!/bin/bash
# claude-talk-mcp: Qwen3-ASR ローカル HTTP サーバ（自作 OpenAI 互換ラッパ）
ASR_DIR="$HOME/.claude-talk-mcp/asr"
export MLX_ASR_HOST=127.0.0.1
export MLX_ASR_PORT=8765
export MLX_ASR_MODEL="Qwen/Qwen3-ASR-1.7B"
export MLX_ASR_LANGUAGE=Japanese
export MLX_ASR_API_KEY="$(cat "$ASR_DIR/api-key.txt")"
exec "$ASR_DIR/.venv/bin/python" "$ASR_DIR/asr_server.py" >> "$ASR_DIR/server.log" 2>&1
