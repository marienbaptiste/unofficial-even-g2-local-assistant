# Audio Stream Capture (G2 Microphone)

## Overview
Capture audio from the G2 glasses' built-in microphone, decode the LC3 stream, and get raw PCM audio for processing (STT, AI assistant, etc.).

---

## BLE Addresses

| UUID Suffix | Direction | Purpose |
|-------------|-----------|---------|
| `5401` | Write | Send commands (phone → glasses) |
| `6402` | **Notify** | **Mic audio stream** (CONFIRMED — LC3 frames arrive here) |
| `5402` | Notify | Responses/acks (glasses → phone) |

Full base: `00002760-08C2-11E1-9073-0E8AC72E{suffix}`

**CONFIRMED (2026-04-04):** Mic audio arrives on UUID `6402` (display notify channel),
NOT `7402` as initially assumed. Subscribing to `6402` notifications immediately starts
receiving 205-byte LC3 packets. No explicit audio start command needed — the mic streams
as soon as the notification subscription is active.

Successfully captured 10s of live voice audio via direct BLE connection (no Even app).

---

## Protocol Flow

### Method 1: Wake Word Trigger ("Hey Even")

1. **Subscribe** to notifications on characteristic `5402`
2. **Wait** for glasses to detect wake word "Hey Even" on-device
3. **Receive** `EVEN_AI_WAKE_UP` event on `5402`
4. **Respond** with wake-up acknowledgment: `sendWakeupResp` via `5401`
5. **Audio stream begins** — LC3-encoded frames arrive on `5402`
6. **Decode** each frame with LC3 decoder
7. **Process** PCM audio (feed to Whisper, etc.)

### Method 2: App-Initiated Audio Control

1. **Send** `AudioCtrCmd` (audio control command) to `5401`
   - Packet type: `APP_REQUEST_AUDIO_CTR_PACKET`
   - Wrapped in EvenBleTransport with appropriate service ID
2. **Receive** `OS_RESPONSE_AUDIO_CTR_PACKET` on `5402` confirming start
   - Success: `APP_REQUEST_AUDIO_CTR_SUCCESS`
   - Failure: `APP_REQUEST_AUDIO_CTR_FAILED`
3. **Audio stream begins** — LC3 frames on `5402`
4. **Decode** and **process**

### Audio Control Commands

| Class | Direction | Description |
|-------|-----------|-------------|
| `AudioCtrCmd` / `AudioCtrCommand` | Phone → Glasses | Start/stop/configure mic |
| `AudioResCmd` / `AudioResCommand` | Glasses → Phone | Status/acknowledgment |

### Audio Sources
The app supports two audio input modes:
- **Bluetooth** (`ble_audio_input_source`) — glasses microphone (what we want)
- **Microphone** (`mic_audio_input_source`) — phone's own mic

Setting key: `ble_audio_input_source`

---

## LC3 Codec

### Library
- Native library: `liblc3.so` (172KB, ARM64)
- Open-source LC3 implementation available: [liblc3](https://github.com/google/liblc3)
- For Mac: compile from source or use the reference implementation

### Decoder Configuration
```
Lc3DecoderConfig(dtUs: <frame_duration_us>, srHz: <sample_rate_hz>)
```

**Likely parameters** (standard LC3 for speech):
- `dtUs` = `10000` (10ms frame duration) — standard LC3 frame size
- `srHz` = `16000` (16kHz sample rate) — optimal for speech
- Bits per sample: 16-bit PCM output
- Channels: 1 (mono, single right-side mic)

### FFI Functions Used by the App
```c
// Get decoder memory requirements
int lc3_decoder_size(int dt_us, int sr_hz);

// Initialize decoder
void* lc3_setup_decoder(int dt_us, int sr_hz, int sr_pcm_hz, void* mem);

// Get number of PCM samples per frame
int lc3_frame_samples(int dt_us, int sr_hz);

// Decode one frame
int lc3_decode(void* decoder, const void* in, int nbytes,
               enum lc3_pcm_format fmt, void* pcm, int stride);
```

### Decoding Flow
```
1. Receive LC3 frame bytes from BLE notification
2. Strip EvenBleTransport header (8 bytes) and CRC (2 bytes)
3. Extract protobuf payload → get raw LC3 frame data
4. lc3_decode(decoder, frame_data, frame_bytes, LC3_PCM_FORMAT_S16, pcm_buffer, 1)
5. Output: 16-bit signed PCM samples at 16kHz
```

### High-Resolution Mode
The `liblc3.so` also exports `lc3_hr_*` functions (high-resolution LC3 Plus), but the glasses likely use standard LC3 for battery efficiency.

---

## Post-Processing Pipeline (inferred from BLE captures)

After LC3 decode, the Even app likely runs:
1. **LC3 decode** — native LC3 codec (liblc3)
2. **AGC + Speech Enhancement** — audio processing before STT
3. **STT** — cloud-based speech recognition (Azure Cognitive Services observed in BLE traffic patterns)

### Audio is NOT encrypted at the application level
- BLE transport uses CRC16-CCITT for integrity, not encryption
- LC3 frames are codec-encoded (compression), not encrypted
- Standard BLE link-layer encryption (OS-managed pairing) protects the transport
- Raw LC3 frames are fully decodable from BLE captures

For a custom pipeline, feed raw PCM directly to Whisper or any STT engine.

---

## Audio Stream Management

### Timeout Handling
- Glasses stop sending audio after inactivity
- Keep sending heartbeats to maintain the stream
- Dashboard heartbeat (0x07 type=9) every 1.5s during AI sessions

### Error Recovery
- On BLE disconnect: reconnect and re-authenticate
- Audio stream restarts on 6402 notification re-subscribe

---

## Implementation

```
1. Scan for "Even G2" devices (both _L_ and _R_)
2. Connect both ears, discover services, subscribe to 5402 + 6402 notify
3. Complete auth handshake (7 packets, f4.f1=2 for wake events)
4. Run init sequence (14 steps)
5. Wait for "Hey Even" wake event on 0x07-0x01 (from RIGHT ear)
6. Ack wake, start mic (subscribe to 6402)
7. LC3 packets arrive on 6402 (205 bytes = 5x40B frames + 5B trailer)
8. Decode with liblc3 or stream to server-side decoder
9. Feed PCM to Whisper/STT
```

---

## Confirmed Audio Findings (from captures 2026-04-03)

All items previously listed as "needs capture" have been resolved:

- **Audio data handle**: Handle `0x0864` in snoop = handle `0x0863` via direct BLE = UUID `6402` (display notify channel) -- CONFIRMED
- **CORRECTED**: Mic is on UUID `6402`, NOT `7402` as initially assumed. Subscribing to `6402` immediately starts mic streaming -- no explicit audio start command needed.
- **NOT wrapped in G2 transport**: No `0xAA` header on audio packets. Raw LC3 data sent directly.
- **Packet format**: 205-byte BLE packets containing 5 x 40-byte LC3 frames + 5-byte trailer
- **Trailer format**: `[1B value][0x00][1B status][0xFF][1B sequential counter]`
- **LC3 codec confirmed**:
  - Frame duration: 10ms (10000 us)
  - Sample rate: 16kHz
  - Bits per sample: 16-bit signed PCM (mono)
  - Bitrate: 32kbps
  - Samples per frame: 160
- **Successfully decoded** 82 seconds of mic audio using the `lc3codec` npm package
- **All audio over BLE custom profile** -- zero SCO/classic Bluetooth packets observed in captures
- **Data is NOT encrypted** in snoop captures -- was initially suspected but confirmed fully decodable as raw LC3
- **Audio control service**: 0xC4-0x00, on secondary channel handles 0x0882/0x0884 (NOT on the audio data handle)

### Additional Findings (2026-04-12)
- **Conversate init required**: Sending 0x0B type=1 (CONVERSATE_CONTROL init) is required before mic streams will activate
- **0xE0 EvenHub service**: Has type=9 audioControl for EvenHub apps — this is the mic enable/disable command used by EvenHub-based apps
- **LC3 playback confirmed**: flutter_soloud used in Flutter app for LC3 audio playback
- **0xC4 correction**: Service 0xC4 is File Transfer (notify_whitelist.json), NOT audio control as initially suspected
