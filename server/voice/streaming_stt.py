"""
Even G2 Voice Service — Streaming STT (WhisperLive)

Real-time speech-to-text using faster-whisper via WhisperLive.
"""

import os
import json
import time
import queue
import logging
import numpy as np

logger = logging.getLogger("even-g2-voice")
SAMPLE_RATE = 16000


class WebSocketAdapter:
    """Adapts a queue to look like a websocket for WhisperLive."""
    def __init__(self):
        self.outbox = queue.Queue()

    def send(self, data: str):
        self.outbox.put_nowait(data)

    def close(self):
        pass


class StreamingSTT:
    """Real-time streaming STT via WhisperLive + faster-whisper."""

    def __init__(self, model_size="large-v3", device="auto", compute_type="float16"):
        self.model_size = model_size
        self.device = device
        self.compute_type = compute_type
        self._fw_client_class = None

        from faster_whisper import WhisperModel
        logger.info(f"Loading faster-whisper '{model_size}'...")
        self.model = WhisperModel(model_size, device=device, compute_type=compute_type)
        logger.info("Whisper model loaded")

        logger.info("Importing WhisperLive ServeClientFasterWhisper...")
        try:
            from whisper_live.backend.faster_whisper_backend import ServeClientFasterWhisper
            self._fw_client_class = ServeClientFasterWhisper
            logger.info("WhisperLive backend loaded")
        except ImportError as e:
            logger.error(f"WhisperLive not installed: {e}")
            raise

    def create_client(self, language=None) -> "WhisperLiveClient":
        """Create a new WhisperLive client session."""
        adapter = WebSocketAdapter()
        client = self._fw_client_class(
            websocket=adapter,
            task="transcribe",
            language=language,
            client_uid=f"even-g2-{time.time_ns()}",
            model=self.model_size,
            use_vad=True,
            single_model=True,
            send_last_n_segments=10,
            no_speech_thresh=0.45,
            clip_audio=True,
            same_output_threshold=7,
        )
        return WhisperLiveClient(client, adapter, self)


class WhisperLiveClient:
    """Wraps a WhisperLive ServeClientFasterWhisper with our adapter."""

    def __init__(self, wl_client, adapter: WebSocketAdapter, stt: StreamingSTT):
        self.wl_client = wl_client
        self.adapter = adapter
        self.stt = stt

    def add_frames(self, pcm: np.ndarray):
        """Feed audio to WhisperLive. Float32, 16kHz."""
        self.wl_client.add_frames(pcm)

    def get_messages(self) -> list[dict]:
        """Non-blocking: drain all pending messages from WhisperLive."""
        messages = []
        while True:
            try:
                raw = self.adapter.outbox.get_nowait()
                msg = json.loads(raw) if isinstance(raw, str) else raw
                messages.append(msg)
            except queue.Empty:
                break
        return messages

    def cleanup(self):
        self.wl_client.cleanup()
