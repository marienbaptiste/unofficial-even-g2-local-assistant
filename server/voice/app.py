"""
Even G2 Voice Service — FastAPI backend (WhisperLive streaming STT)

Endpoints:
  WS   /ws/stream          Real-time: LC3/PCM in -> transcription segments out
  POST /api/transcribe      Batch: upload file -> transcription (debug)
  GET  /api/health          Health check
"""

import os
import sys
import time
import json
import asyncio
import logging
from concurrent.futures import ThreadPoolExecutor

import numpy as np
from fastapi import FastAPI, File, UploadFile, WebSocket, WebSocketDisconnect
from fastapi.responses import JSONResponse
from starlette.websockets import WebSocketState

from audio_utils import load_audio, resample
from lc3_pipeline import (
    decode_lc3_frames, decode_ble_packet,
    G2_BLE_PACKET_SIZE, G2_FRAME_BYTES,
)
from streaming_stt import StreamingSTT

logging.basicConfig(level=logging.INFO, stream=sys.stdout)
logger = logging.getLogger("even-g2-voice")

app = FastAPI(title="Even G2 Voice Service — Streaming STT")

MODEL_SIZE = os.environ.get("WHISPER_MODEL", "large-v3")
DEVICE = os.environ.get("WHISPER_DEVICE", "auto")
COMPUTE_TYPE = os.environ.get("WHISPER_COMPUTE_TYPE", "float16")

_executor = ThreadPoolExecutor(max_workers=4)
_stt_engine: StreamingSTT | None = None


@app.on_event("startup")
async def startup_load_model():
    global _stt_engine
    loop = asyncio.get_event_loop()
    logger.info("Pre-loading StreamingSTT...")
    _stt_engine = await loop.run_in_executor(
        _executor,
        lambda: StreamingSTT(model_size=MODEL_SIZE, device=DEVICE, compute_type=COMPUTE_TYPE),
    )
    logger.info("StreamingSTT ready")


def get_stt() -> StreamingSTT:
    return _stt_engine


# -- Health --

@app.get("/api/health")
async def health():
    return {
        "backend": "ok",
        "engine": "whisper-live + faster-whisper",
        "model": MODEL_SIZE,
        "device": DEVICE,
        "model_loaded": _stt_engine is not None,
    }


# -- WebSocket streaming STT --

@app.websocket("/ws/stream")
async def ws_stream(ws: WebSocket):
    await ws.accept()
    logger.info("WebSocket connected")

    stt = get_stt()
    if stt is None:
        await ws.send_json({"error": "Model still loading, try again"})
        await ws.close()
        return

    loop = asyncio.get_event_loop()
    client = None
    input_format = "pcm"
    language = None
    alive = True

    async def poll_results():
        while alive:
            await asyncio.sleep(0.1)
            if not alive:
                break
            try:
                if client is None:
                    continue
                messages = client.get_messages()
                for msg in messages:
                    if ws.client_state != WebSocketState.CONNECTED:
                        break

                    if "segments" in msg:
                        segments = msg["segments"]
                        await ws.send_json({
                            "segments": segments,
                            "partial": not all(s.get("completed", False) for s in segments),
                        })

                    elif "message" in msg:
                        if msg["message"] == "SERVER_READY":
                            logger.info("WhisperLive client ready")
                        elif "language" in msg:
                            logger.info(f"Language detected: {msg.get('language')}")
            except Exception as e:
                if alive:
                    logger.error(f"Poll error: {e}")

    poll_task = asyncio.create_task(poll_results())

    try:
        while True:
            msg = await ws.receive()

            if "text" in msg:
                try:
                    ctrl = json.loads(msg["text"])
                except json.JSONDecodeError:
                    continue

                action = ctrl.get("action", "")
                if action == "reset":
                    await ws.send_json({"status": "reset"})
                elif action == "config":
                    input_format = ctrl.get("input_format", "pcm")
                    language = ctrl.get("language")
                    if client is None:
                        client = await loop.run_in_executor(
                            _executor, lambda: stt.create_client(language=language))
                        logger.info(f"Client created, language={language or 'auto'}, format={input_format}")
                    await ws.send_json({"status": "configured", "input_format": input_format})
                elif action == "flush":
                    pass
                continue

            if "bytes" in msg:
                raw = msg["bytes"]
                if len(raw) == 0:
                    continue

                if input_format == "lc3":
                    if len(raw) % G2_BLE_PACKET_SIZE == 0:
                        chunks = []
                        for offset in range(0, len(raw), G2_BLE_PACKET_SIZE):
                            chunks.append(decode_ble_packet(raw[offset:offset + G2_BLE_PACKET_SIZE]))
                        pcm = np.concatenate(chunks)
                    elif len(raw) % G2_FRAME_BYTES == 0:
                        frames = [raw[i:i + G2_FRAME_BYTES] for i in range(0, len(raw), G2_FRAME_BYTES)]
                        pcm = decode_lc3_frames(frames)
                    else:
                        logger.warning(f"Unexpected LC3 packet size: {len(raw)} bytes, skipping")
                        continue
                else:
                    if len(raw) % 4 == 0:
                        pcm = np.frombuffer(raw, dtype=np.float32).copy()
                    else:
                        pcm = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0

                if client:
                    client.add_frames(pcm)

    except WebSocketDisconnect:
        logger.info("WebSocket disconnected")
    except RuntimeError as e:
        if "disconnect" in str(e).lower():
            logger.info("WebSocket disconnected (runtime)")
        else:
            logger.error(f"WebSocket error: {e}")
    finally:
        alive = False
        poll_task.cancel()
        if client:
            client.cleanup()


# -- Batch transcribe (file upload, debug only) --

@app.post("/api/transcribe")
async def transcribe(
    file: UploadFile = File(...),
):
    t_start = time.perf_counter()
    raw_bytes = await file.read()

    pcm, sr = load_audio(raw_bytes, file.filename or "audio.wav")

    pipeline_info = {
        "original_sample_rate": sr,
        "original_duration_s": round(len(pcm) / sr, 3),
    }

    pcm_16k = resample(pcm, sr, 16000)

    stt = get_stt()
    if stt is None:
        return JSONResponse(status_code=503, content={"error": "Model loading"})

    loop = asyncio.get_event_loop()
    t_stt = time.perf_counter()

    def do_transcribe():
        client = stt.create_client()
        segments_iter, info = client.wl_client.transcriber.transcribe(
            pcm_16k, beam_size=1, vad_filter=True)
        segs = []
        texts = []
        for seg in segments_iter:
            segs.append({"start": round(seg.start, 2), "end": round(seg.end, 2), "text": seg.text.strip()})
            texts.append(seg.text.strip())
        if client:
            client.cleanup()
        return segs, texts, info

    segs, texts, info = await loop.run_in_executor(_executor, do_transcribe)

    pipeline_info.update({
        "language": info.language,
        "stt_ms": round((time.perf_counter() - t_stt) * 1000),
        "total_ms": round((time.perf_counter() - t_start) * 1000),
    })

    return {"text": " ".join(texts), "segments": segs, "pipeline_info": pipeline_info}
