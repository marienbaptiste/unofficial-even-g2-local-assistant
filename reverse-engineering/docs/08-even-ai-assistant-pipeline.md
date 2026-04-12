# Building a Custom AI Assistant Pipeline

## Status: WORKING (2026-04-12)

Full pipeline confirmed and published: Glasses mic -> Whisper STT -> OpenClaw AI -> glasses display.

**Published implementation:** [github.com/marienbaptiste/unofficial-even-g2-local-assistant](https://github.com/marienbaptiste/unofficial-even-g2-local-assistant)

### Key findings:
- **Flutter SDK connects directly** — no Even app needed for the full pipeline
- **Voice service decodes LC3 server-side** — no on-device LC3 decoding required in the assistant
- **OpenClaw API** at `/v1/chat/completions` with SOUL.md system prompt for personality
- **LC3 playback** confirmed via flutter_soloud in the Flutter app

## Overview
This document describes how to build a complete custom AI assistant using the G2 glasses + R1 ring, replacing the Even cloud services with your own pipeline.

---

## Architecture

```
G2 Glasses (mic) ──BLE──► Mac Studio ──► Your AI Pipeline
     ▲                        │
     │                        │
     └────────BLE─────────────┘
          (display text/images)

R1 Ring (gestures) ──BLE──► Mac Studio
```

---

## BLE Addresses Summary

### G2 Glasses
| UUID Suffix | Purpose |
|-------------|---------|
| `5401` | Command write (all services) |
| `5402` | Response notify (all services) |
| `6401`/`6402` | Display data write |
| `7401`/`7402` | Third channel (possibly audio stream) |

Base: `00002760-08C2-11E1-9073-0E8AC72E{suffix}`

### R1 Ring
| UUID | Purpose |
|------|---------|
| `BAE80001-...` | Service |
| `BAE80012-...` | Write |
| `BAE80013-...` | Notify |

---

## Complete Pipeline Flow

### Step 1: BLE Connection
```
1. Scan for "Even G2" and "EVEN R1" devices
2. Connect to both
3. Request MTU 512 on G2
4. Enable notifications on G2 (5402, 7402) and Ring (BAE80013)
5. Authenticate with G2 (7-packet handshake on 5401/5402)
6. Start heartbeat loop
```

### Step 2: Listen for Wake Word
```
1. Glasses detect "Hey Even" on-device
2. Receive EVEN_AI_WAKE_UP event on 5402
3. Send sendWakeupResp acknowledgment on 5401
4. Transition to audio capture state
```

### Step 3: Capture Audio
```
1. Send AudioCtrCmd to start microphone streaming (if not auto-started)
2. Receive LC3-encoded audio frames on 5402 (or 7402)
3. Decode each frame:
   - Parse EvenBleTransport header
   - Extract protobuf payload
   - Get LC3 frame bytes
   - Decode with liblc3 → 16-bit PCM at 16kHz
4. Buffer PCM samples
```

### Step 4: Speech-to-Text
```
Option A: Whisper (local, recommended)
  - Feed PCM buffer to whisper.cpp or faster-whisper
  - Get transcription text

Option B: Cloud STT
  - Stream PCM to any cloud STT API

Option C: SherpaOnnx (what the app uses for on-device)
  - Use sherpa-onnx library with compatible models
```

### Step 5: AI Processing
```
1. Send transcribed text to your LLM:
   - Claude API
   - Local LLM (llama.cpp, Ollama)
   - Any other model
2. Get response text
3. Optionally: parse for commands (navigate, remind, translate, etc.)
```

### Step 6: Display Response on Glasses
```
Option A: Even AI Reply (recommended)
  - Build EvenAIReplyInfo protobuf
  - Wrap in EvenBleTransport with AI service ID
  - Send via 5401
  - Glasses display the AI response text

Option B: Conversate (for streaming)
  - Start conversate session
  - Stream ConversateTranscribeData as tokens arrive
  - Real-time text display on glasses

Option C: Image (for rich content)
  - Render response as 4-bit grayscale BMP
  - Send via display channel (6401/6402)
```

### Step 7: Handle Follow-Up Input
```
- Ring tap → confirm/dismiss/next action
- Head tilt → scroll through long responses
- Another "Hey Even" → new question
- Glasses touchpad → UI interaction
```

---

## The Even App's Pipeline (verified from dex bytecode)

The official app does:
```
1. "Hey Even" wake word → on-device detection (glasses)
2. Audio → LC3 over BLE → phone (continuous GATT notifications, 517B MTU)
3. flutter_ezw_lc3 decodes LC3 → PCM (local, on phone)
4. flutter_ezw_audio applies AGC + speech enhancement (local, on phone)
5. PushAudioInputStream → Azure Cognitive Services Speech SDK (CLOUD)
   - SpeechRecognizer for transcription
   - TranslationRecognizer for translation (com.even.translate.azure.*)
   - Auth via SpeechConfig.fromSubscription/fromEndpoint/fromAuthorizationToken
6. TranscribeResult / TranslationResult protobuf → BLE → glasses display
```

**Source:** Binary string extraction from `classes02.dex`, `classes04.dex`, `classes23.dex` in `updated extract/com.even.sg/`.

**No Soniox found** — zero hits across all 54 dex files. Azure is the sole STT/translation provider.

Your pipeline replaces steps 3-6 with local processing.

---

## Even AI Protocol Details

### Protobuf Messages (even_ai.pb.dart)

| Message | Purpose | Direction |
|---------|---------|-----------|
| `EvenAIControl` | Start/stop AI session | Phone → Glasses |
| `EvenAIConfig` | AI configuration | Phone → Glasses |
| `EvenAIAskInfo` | User question text | Phone → (Cloud) |
| `EvenAIReplyInfo` | AI response text | Phone → Glasses |
| `EvenAIAnalyseInfo` | Analysis/context info | Phone → Glasses |
| `EvenAIPromptInfo` | Prompt metadata | Phone → Glasses |
| `EvenAISkillInfo` | Skill invocation | Phone → Glasses |
| `EvenAIVADInfo` | Voice activity detection | Glasses → Phone |
| `EvenAIHeartbeat` | Keep-alive | Bidirectional |
| `EvenAIEvent` | AI events | Glasses → Phone |
| `EvenAISentiment` | Sentiment data | Phone → Glasses |

### AI Command IDs (eEvenAICommandId)
- `EVEN_AI_ENTER` — start AI session
- `EVEN_AI_EXIT` — end AI session
- `EVEN_AI_WAKE_UP` — wake word detected

### AI Skills (eEvenAISkill)
The AI can invoke built-in skills:
- `even_ai_navigate` — start navigation
- `even_ai_translate` — start translation
- `even_ai_teleprompt` — start teleprompter
- `even_ai_conversate` — start conversate
- `even_ai_save_quicklist` — save to quick list
- `even_ai_silent_mode_on` — enable silent mode

### AI States (eEvenAIStatus, eEvenAIVADStatus)
- `WakeUpState` — listening for wake word
- `AI state` — processing AI request
- VAD status for voice activity detection

---

## Transcribe Protocol (for real-time STT display)

If you want to show live transcription on the glasses:

| Message | Purpose |
|---------|---------|
| `TranscribeControl` | Start/stop transcription |
| `TranscribeResult` | Transcription text result |
| `TranscribeHeartBeat` | Keep-alive |
| `TranscribeNotify` | Status notifications |
| `TranscribeDataPackage` | Data container |
| `TRANSCRIBE_CTRL` | Control command |
| `TRANSCRIBE_RESULT` | Result text |

### Sending live transcription:
```
1. Send TranscribeControl (start) → 5401
2. As STT produces text:
   - Send TranscribeResult with partial/final text → 5401
3. Send TranscribeHeartBeat periodically
4. Send TranscribeControl (stop) when done
```

---

## Required Libraries for Mac

| Library | Purpose | Source |
|---------|---------|--------|
| CoreBluetooth | BLE communication | macOS built-in |
| liblc3 | LC3 audio decoding | github.com/google/liblc3 |
| protobuf | Protocol buffer encoding/decoding | google.github.io/proto-lens |
| whisper.cpp | Speech-to-text | github.com/ggerganov/whisper.cpp |

---

## Decompilation Analysis (updated extract — dex bytecode)

### Verified from dex binary strings
- **Azure is the STT/translation backend**: `com.microsoft.cognitiveservices.speech.*` SDK fully bundled in `classes04.dex`. Includes `SpeechRecognizer`, `TranslationRecognizer`, `SpeechSynthesizer`, `PushAudioInputStream`, `SpeechConfig`.
- **Translation uses Azure**: `com.even.translate.azure.translation.AzureTranslationRecognizer` and `AzureTranslationConfiguration` in `classes02.dex`.
- **Audio pipeline**: `flutter_ezw_lc3` (LC3 decode) → `flutter_ezw_audio` (AGC/enhancement) → `flutter_ezw_asr` (Azure STT) — all confirmed as native Flutter plugins in `classes04.dex` and `classes23.dex`.
- **Transcription protobuf**: `transcribe.TranscribeEventOuterClass$TranscribeResult` in `classes23.dex`.
- **Translation protobuf**: `com.even.translate.TranslationEventOuterClass$TranslationResult` in `classes02.dex`.
- **No Soniox**: Zero hits across all 54 dex files.
- **No local LLM**: No model loading, no on-device inference libraries.
- **Audio not encrypted**: LC3 is codec compression, not encryption. CRC16 is for integrity. BLE link-layer encryption is OS-managed.

### Key Even app classes found
- `com.even.sg.MainActivity` — main Flutter activity
- `com.even.translate.TranslatePlugin` — Flutter translation plugin
- `com.even.even_core.services.nls.EvNLService` — NLS service
- `com.even.even_core.utils.room.EvDatabase` — local Room database
- `com.even.navigate.service.BackgroundLocationReceiver` — navigation

### Dex file protection
- `classes05.dex` loads `/data/data/com.even.sg/lib/libjgdtc.so` — **Jiagu packer**
- JADX decompiles framework code successfully but Even app classes remain obfuscated
- Binary string extraction bypasses obfuscation for class/method names

---

## What Needs BLE Snoop Capture
- Exact service ID for Even AI service
- EvenAIReplyInfo protobuf field numbers
- Audio data service ID and packet format
- Full wake-up → audio → response cycle bytes
- Heartbeat timing and format
- Whether to use AI reply or conversate for best display experience
