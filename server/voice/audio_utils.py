"""
Even G2 Voice Service — Audio utilities

Helpers for the batch /api/transcribe endpoint (file uploads).
The primary streaming path uses LC3 decoding via lc3_pipeline.py.
"""

import io
import struct
import wave
import numpy as np


def load_audio(raw_bytes: bytes, filename: str) -> tuple[np.ndarray, int]:
    """
    Load uploaded audio bytes into a float32 mono numpy array + sample rate.
    Tries LC3 first (production path), then WAV (testing fallback).
    """
    # LC3 first — production path from G2 glasses
    from lc3_pipeline import is_lc3_available, is_lc3_data, decode_lc3_frames, decode_ble_packet, G2_BLE_PACKET_SIZE, G2_FRAME_BYTES, G2_SAMPLE_RATE
    if is_lc3_available() and is_lc3_data(raw_bytes):
        if len(raw_bytes) % G2_BLE_PACKET_SIZE == 0:
            chunks = []
            for i in range(0, len(raw_bytes), G2_BLE_PACKET_SIZE):
                chunks.append(decode_ble_packet(raw_bytes[i:i + G2_BLE_PACKET_SIZE]))
            return np.concatenate(chunks), G2_SAMPLE_RATE
        elif len(raw_bytes) % G2_FRAME_BYTES == 0:
            frames = [raw_bytes[i:i + G2_FRAME_BYTES] for i in range(0, len(raw_bytes), G2_FRAME_BYTES)]
            return decode_lc3_frames(frames), G2_SAMPLE_RATE

    # WAV fallback (testing only)
    if filename.lower().endswith(".wav") or raw_bytes[:4] == b"RIFF":
        with wave.open(io.BytesIO(raw_bytes), "rb") as wf:
            sr = wf.getframerate()
            n_frames = wf.getnframes()
            n_channels = wf.getnchannels()
            sampwidth = wf.getsampwidth()
            raw_data = wf.readframes(n_frames)

        if sampwidth == 2:
            audio = np.frombuffer(raw_data, dtype=np.int16).astype(np.float32) / 32768.0
        elif sampwidth == 4:
            audio = np.frombuffer(raw_data, dtype=np.int32).astype(np.float32) / 2147483648.0
        else:
            audio = np.frombuffer(raw_data, dtype=np.int16).astype(np.float32) / 32768.0

        if n_channels > 1:
            audio = audio.reshape(-1, n_channels).mean(axis=1)
        return audio, sr

    # Last resort: raw 16-bit mono PCM at 16kHz
    samples = np.frombuffer(raw_bytes, dtype=np.int16).astype(np.float32) / 32768.0
    return samples, 16000


def resample(pcm: np.ndarray, from_rate: int, to_rate: int) -> np.ndarray:
    """Simple linear interpolation resample. Good enough for debug endpoint."""
    if from_rate == to_rate:
        return pcm
    ratio = to_rate / from_rate
    new_len = int(len(pcm) * ratio)
    indices = np.linspace(0, len(pcm) - 1, new_len)
    return np.interp(indices, np.arange(len(pcm)), pcm).astype(np.float32)
