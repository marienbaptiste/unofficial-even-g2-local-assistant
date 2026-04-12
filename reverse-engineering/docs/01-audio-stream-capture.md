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

## Post-Processing Pipeline (verified from dex bytecode)

After LC3 decode, the app runs:
1. **LC3 decode** — `flutter_ezw_lc3` plugin (confirmed in `classes04.dex`)
2. **AGC + Speech Enhancement** — `flutter_ezw_audio` plugin (confirmed in `classes04.dex`)
3. **STT** — `flutter_ezw_asr` plugin (confirmed in `classes23.dex`) wrapping **Azure Cognitive Services Speech SDK**

### Confirmed from `classes04.dex`:
- `com.microsoft.cognitiveservices.speech.SpeechRecognizer` — Azure Speech SDK recognizer
- `com.microsoft.cognitiveservices.speech.audio.PushAudioInputStream` — phone pushes decoded PCM into Azure's streaming input
- `com.microsoft.cognitiveservices.speech.SpeechConfig` with `fromSubscription`, `fromEndpoint`, `fromAuthorizationToken` — Azure auth
- Audio format strings: `Audio16Khz16Bit32KbpsMonoOpus`, `Audio16Khz128KBitRateMonoMp3` etc.
- `AudioProcessingOptions` — AUDIO_INPUT_PROCESSING_DISABLE_ECHO_CANCELLATION, DISABLE_NOISE_SUPPRESSION, ENABLE_VOICE_ACTIVITY_DETECTION
- `LC3/h`, `LC3/k`, `LC3/q`, `LC3/r`, `LC3/s`, `LC3/t` — obfuscated LC3 codec classes

### Confirmed from `classes23.dex`:
- `transcribe.TranscribeEventOuterClass$TranscribeResult` — protobuf transcription result
- `android.media.AudioRecord` — Android mic recording
- `io.flutter.plugin.common.EventChannel$StreamHandler` — Flutter event streaming
- `flutter_ezw_asr_release` — ASR plugin cleanup

### NOT found in any dex file:
- No Soniox references (zero hits across all 54 dex files)
- No Whisper/SherpaOnnx references
- No local LLM or on-device model loading

### Audio is NOT encrypted at the application level
- BLE transport uses CRC16-CCITT for integrity, not encryption
- LC3 frames are codec-encoded (compression), not encrypted
- Standard BLE link-layer encryption (OS-managed pairing) protects the transport
- No application-level encryption/decryption of audio data found in any dex file

For a custom pipeline, you can skip the app's post-processing and feed raw PCM directly to Whisper or any STT.

---

## Audio Stream Management

### Timeout Handling
- `Audio data timeout! Last received <N>s` — glasses stop sending after inactivity
- `_checkAudioDataTimeout` — app monitors for gaps
- `_updateLastAudioDataTime` — tracks last received timestamp
- Keep sending heartbeats to maintain the stream

### Error Recovery
- `Audio stream controller was closed, attempting to recover...`
- `Attempting to reinitialize audio manager after resume failure...`
- On BLE disconnect: app can fall back to phone mic

---

## Implementation on Mac (CoreBluetooth)

```
1. CBCentralManager → scan for "Even G2"
2. Connect, discover services, subscribe to 5402 notify
3. Complete auth handshake on 5401/5402
4. Send AudioCtrCmd to start mic (or wait for EVEN_AI_WAKE_UP)
5. On each notification from 5402:
   a. Parse EvenBleTransport header
   b. Check service ID for audio data
   c. Extract LC3 frame from protobuf payload
   d. Decode with liblc3 → PCM
6. Feed PCM to Whisper/STT
```

---

## Decompilation Analysis (updated extract)

### Dex bytecode analysis (classes02-54.dex)
JADX decompiled 47 of 54 dex files, but all decompiled code is Android framework/Chromium/Google libraries — not Even app code. However, binary string extraction from the raw dex files revealed the actual Even app class names and SDK dependencies:

**`classes04.dex`** (3.3MB) — Azure Speech SDK + LC3 codec:
- Full `com.microsoft.cognitiveservices.speech.*` SDK (SpeechRecognizer, TranslationRecognizer, SpeechSynthesizer, PushAudioInputStream, etc.)
- `flutter_ezw_lc3_release`, `flutter_ezw_audio_release` — native Flutter plugins for LC3 and audio
- `LC3/h`, `LC3/k`, `LC3/q`, `LC3/r`, `LC3/s`, `LC3/t` — obfuscated LC3 classes
- `com.even.translate.TranslatePlugin`, `com.even.even_core.services.nls.EvNLService`

**`classes02.dex`** (7MB) — Translation pipeline:
- `com.even.translate.azure.translation.AzureTranslationRecognizer`
- `com.even.translate.azure.translation.AzureTranslationConfiguration`
- `com.even.translate.azure.basic.AzureRecognizerState`
- `com.even.translate.azure.basic.Codec` — codec enum for Azure config
- `com.even.translate.TranslationEventOuterClass` — protobuf translation events

**`classes23.dex`** (288KB) — Transcription + ASR:
- `transcribe.TranscribeEventOuterClass$TranscribeResult`
- `flutter_ezw_asr_release` — ASR plugin cleanup
- `android.media.AudioRecord` — phone mic recording
- `io.flutter.plugin.common.EventChannel$StreamHandler`

**`classes05.dex`** (25KB) — Jiagu loader:
- `/data/data/com.even.sg/lib/libjgdtc.so` — Jiagu protection library

**`classes19.dex`** (314KB) — Runtime paths:
- `com.even.sg.MainActivity` — main Flutter activity
- `libaudioeffect_jni.so`, `libmmkv.so` — native libraries
- Firebase session data paths

### BLE layer (from decompiled Java)
- **`C1940tb.java`**: `onCharacteristicChanged()` receives raw `byte[]` via `getValue()` and forwards to JNI. MTU negotiated to 517 bytes.
- Audio arrives as **continuous BLE GATT notifications** — each notification is one G2 transport packet containing one LC3 frame in protobuf.

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
