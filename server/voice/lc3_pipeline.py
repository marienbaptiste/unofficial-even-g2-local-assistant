"""
Even G2 Voice Service — LC3 decoder for G2 glasses audio

Even G2 glasses stream LC3-encoded audio over BLE:
  - 16 kHz, mono, 32 kbps
  - 10ms frames = 160 samples = 40 bytes compressed
  - BLE packets: 205 bytes = 5 x 40-byte LC3 frames + 5-byte trailer

This module decodes LC3 frames to PCM for Whisper STT.
Requires google/liblc3 Python bindings.
"""

import logging
import numpy as np

logger = logging.getLogger("even-g2-voice")

# Even G2 glasses LC3 constants
G2_SAMPLE_RATE = 16000
G2_CHANNELS = 1
G2_FRAME_US = 10000         # 10ms
G2_FRAME_SAMPLES = 160      # G2_SAMPLE_RATE / 100
G2_BITRATE = 32000          # 32 kbps
G2_FRAME_BYTES = 40         # G2_BITRATE / 8 / 100

# BLE packet layout
G2_BLE_PACKET_SIZE = 205    # 5 frames + trailer
G2_FRAMES_PER_PACKET = 5
G2_TRAILER_SIZE = 5         # [value:1B][0x00:1B][status:1B][0xFF:1B][seq:1B]

# Try to import lc3 Python bindings (built from google/liblc3)
_lc3_available = False
_decoder = None
try:
    import lc3
    _decoder = lc3.Decoder(G2_FRAME_US, G2_SAMPLE_RATE, G2_CHANNELS)
    _lc3_available = True
    logger.info("LC3 decoder initialized (16kHz, 10ms, 32kbps)")
except ImportError:
    logger.warning("liblc3 not available — LC3 decoding disabled. "
                   "Install from https://github.com/google/liblc3")


def is_lc3_available() -> bool:
    return _lc3_available


def decode_lc3_frame(frame: bytes) -> np.ndarray:
    """
    Decode a single 40-byte LC3 frame to 160 float32 PCM samples at 16kHz.
    """
    if not _lc3_available:
        raise RuntimeError("liblc3 not available")
    decoded = _decoder.decode(frame)
    return np.array(decoded, dtype=np.float32)


def decode_lc3_frames(frames: list[bytes]) -> np.ndarray:
    """
    Decode multiple LC3 frames and concatenate into a single PCM array.
    """
    if not _lc3_available:
        raise RuntimeError("liblc3 not available")
    chunks = []
    for frame in frames:
        decoded = _decoder.decode(frame)
        chunks.append(np.array(decoded, dtype=np.float32))
    return np.concatenate(chunks) if chunks else np.array([], dtype=np.float32)


def parse_ble_packet(packet: bytes) -> list[bytes]:
    """
    Parse a 205-byte Even G2 BLE audio packet into individual LC3 frames.

    Packet format: [5 x 40-byte LC3 frames][5-byte trailer]
    Trailer: [value:1B][0x00:1B][status:1B][0xFF:1B][seq_counter:1B]

    Returns list of 5 LC3 frames (40 bytes each).
    """
    if len(packet) != G2_BLE_PACKET_SIZE:
        raise ValueError(f"Expected {G2_BLE_PACKET_SIZE}-byte BLE packet, got {len(packet)}")

    frames = []
    for i in range(G2_FRAMES_PER_PACKET):
        start = i * G2_FRAME_BYTES
        end = start + G2_FRAME_BYTES
        frames.append(packet[start:end])
    return frames


def decode_ble_packet(packet: bytes) -> np.ndarray:
    """
    Parse and decode a 205-byte BLE packet to PCM.
    Returns 800 float32 samples (5 frames x 160 samples = 50ms at 16kHz).
    """
    frames = parse_ble_packet(packet)
    return decode_lc3_frames(frames)


def is_lc3_data(raw: bytes) -> bool:
    """
    Heuristic to detect if incoming bytes are LC3 rather than raw PCM.

    - 205 bytes = single G2 BLE packet
    - Multiple of 40 bytes = raw LC3 frames
    - Multiple of 205 bytes = multiple BLE packets
    """
    length = len(raw)
    if length == G2_BLE_PACKET_SIZE:
        return True
    if length % G2_BLE_PACKET_SIZE == 0:
        return True
    if length % G2_FRAME_BYTES == 0 and length < 1000:
        return True
    return False
