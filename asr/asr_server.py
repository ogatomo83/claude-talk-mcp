#!/usr/bin/env python3
"""claude-talk-mcp 用 Qwen3-ASR ローカル HTTP サーバ。

同梱の `mlx-qwen3-asr serve` は推論をスレッドプールへ逃がすため MLX の
GPU ストリームがワーカースレッドに無く "There is no Stream(gpu, 1)" で失敗する。
ここではモデルをメインスレッドでロードし、推論も async ハンドラ内で同期実行
（＝イベントループ＝メインスレッド）することで、その問題を回避する。

OpenAI 互換エンドポイント:
  POST /v1/audio/transcriptions   (multipart: file, language, response_format)
  GET  /health
"""
from __future__ import annotations

import os
import tempfile
from pathlib import Path
from typing import Optional

from fastapi import FastAPI, File, Form, Header, HTTPException, UploadFile
from fastapi.responses import JSONResponse, PlainTextResponse
import uvicorn

from mlx_qwen3_asr import Session

MODEL_ID = os.environ.get("MLX_ASR_MODEL", "Qwen/Qwen3-ASR-1.7B")
HOST = os.environ.get("MLX_ASR_HOST", "127.0.0.1")
PORT = int(os.environ.get("MLX_ASR_PORT", "8765"))
API_KEY = os.environ.get("MLX_ASR_API_KEY", "")
DEFAULT_LANGUAGE = os.environ.get("MLX_ASR_LANGUAGE", "Japanese")

# メインスレッドでモデルをロード（推論も同一スレッドで行う）。
print(f"[asr] loading model {MODEL_ID} ...", flush=True)
SESSION = Session(model=MODEL_ID)
print("[asr] model ready", flush=True)

app = FastAPI()


def _check_auth(authorization: Optional[str]) -> None:
    if not API_KEY:
        return
    expected = f"Bearer {API_KEY}"
    if authorization != expected:
        raise HTTPException(status_code=401, detail="invalid api key")


@app.get("/health")
async def health() -> dict:
    return {"status": "ok", "model": MODEL_ID}


@app.post("/v1/audio/transcriptions")
async def transcriptions(
    file: UploadFile = File(...),
    language: Optional[str] = Form(None),
    prompt: Optional[str] = Form(None),
    response_format: Optional[str] = Form("json"),
    authorization: Optional[str] = Header(None),
):
    _check_auth(authorization)

    contents = await file.read()
    suffix = Path(file.filename or "upload.wav").suffix or ".wav"
    tmp = tempfile.NamedTemporaryFile(suffix=suffix, delete=False, prefix="asr_")
    try:
        tmp.write(contents)
        tmp.flush()
        tmp.close()
        # 同期呼び出し = イベントループ(メイン)スレッドで実行 -> GPU stream OK
        result = SESSION.transcribe(
            tmp.name,
            language=language or DEFAULT_LANGUAGE,
            context=prompt or "",
        )
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(status_code=500, detail=str(exc))
    finally:
        Path(tmp.name).unlink(missing_ok=True)

    text = getattr(result, "text", None)
    if text is None:
        text = str(result)
    text = text.strip()

    fmt = (response_format or "json").strip().lower()
    if fmt == "text":
        return PlainTextResponse(text)
    return JSONResponse({"text": text})


if __name__ == "__main__":
    # 単一ワーカー・単一ループ。async ハンドラで同期推論するので実質シリアル。
    uvicorn.run(app, host=HOST, port=PORT, workers=1, log_level="warning")
