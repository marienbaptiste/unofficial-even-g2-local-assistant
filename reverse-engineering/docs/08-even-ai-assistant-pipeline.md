# Building a Custom AI Assistant Pipeline

## Status: WORKING (2026-04-14)

Full pipeline confirmed: Glasses mic -> Whisper STT -> OpenClaw AI -> glasses display.

**Published implementation:** [github.com/marienbaptiste/unofficial-even-g2-local-assistant](https://github.com/marienbaptiste/unofficial-even-g2-local-assistant)

### Key findings:
- **Dual-ear connection required** -- left ear for display, right ear for AI wake events
- **Dashboard service 0x07** handles the full AI session (NOT service 0x01)
- **f4.f1=2 in auth pipe role** (cmd=5) registers for wake event callbacks
- **0x0E type=4 health widget** required during init for AI interface activation
- **Voice service decodes LC3 server-side** -- no on-device LC3 decoding required
- **Mic audio on UUID 6402** -- raw LC3 frames, no G2 transport wrapper

---

## Architecture

```
G2 Glasses  <--BLE (L+R ears)-->  Flutter App  <--WebSocket-->  Voice Service  --> OpenClaw
  mic LC3                          bridge                      LC3 + Whisper      AI brain
  display                          + UI                                         SOUL.md
  wake word
```

---

## Complete Pipeline Flow

### Step 1: BLE Connection (Dual-Ear)

Even G2 glasses are TWO separate BLE devices (`_L_` and `_R_`).

```
1. Scan for "Even G2" devices -- find both _L_ and _R_
2. Connect LEFT ear first (primary -- display + commands)
3. Connect RIGHT ear second (secondary -- event delivery)
4. Subscribe to 5402 notifications on BOTH ears
5. Subscribe to 7402 notifications on both (for C4/C5 data)
6. Authenticate (7-packet handshake via auth.dart)
   - Auth 2: pipe role cmd=5 with f4.f1=2 (CRITICAL for wake events)
   - Auth 6: ALSO f4.f1=2 (must not override Auth 2)
7. Run 14-step init sequence (_initServices)
8. Start heartbeat loop (EvenHub cmd=12 + DevSettings cmd=14, every 5s)
```

### Step 2: Listen for Wake Word

```
1. Glasses detect "Hey Even" on-device (firmware handles wake word)
2. RIGHT ear sends 0x07-0x01 event: type=1, state=1 (LISTENING_STARTED)
3. App receives event via onWake stream
4. App sends ack: 0x07-0x20 type=1, state=2 (LISTENING_ACTIVE)
5. App sends immediate heartbeat: 0x07-0x20 type=9
6. Glasses display "AI Listening" and start streaming mic audio
```

### Step 3: Capture Audio

```
1. Subscribe to 6402 notifications (mic.start)
2. LC3 frames arrive: 205-byte packets = 5x40B LC3 + 5B trailer
3. LC3 params: 10ms frame, 16kHz, 32kbps, mono, 160 samples/frame
4. Audio is RAW LC3 -- no G2 transport wrapper (no 0xAA header)
5. Stream to Whisper via WebSocket for real-time STT
```

### Step 4: Live Transcription on Glasses

```
1. As Whisper returns partial transcriptions, send to glasses:
   - 0x07-0x20 type=3: field5={f1=0, f2=0, f4="what is the weather"}
   - Progressive updates (full text each time, not deltas)
2. When speech ends (Whisper returns final):
   - 0x07-0x20 type=2: field4={f1=2} (VOICE_INPUT_DONE)
   - Stop mic + Whisper
```

### Step 5: AI Processing

```
1. Send transcription to AI (OpenClaw, Claude, local LLM, etc.)
2. Show thinking indicator on glasses:
   - 0x07-0x20 type=4: field6=empty (AI_THINKING)
3. Keep sending heartbeats + thinking while waiting:
   - 0x07-0x20 type=9 + type=4 every 2s
   - This prevents glasses from timing out
```

### Step 6: Stream Response to Glasses

```
1. Stream AI response text in chunks:
   - 0x07-0x20 type=5: field7={f1=0, f2=0, f4="response text", f6=0}
   - Multiple chunks for long responses
2. Signal response complete:
   - 0x07-0x20 type=5: field7={f1=0, f2=0, f4="", f6=1} (is_done)
3. Keep display alive with heartbeats (type=9) for ~8 seconds
4. End session:
   - 0x07-0x20 type=1: field3={f1=3} (BOUNDARY)
```

### Step 7: Ready for Next Session

```
1. Glasses return to dashboard/idle
2. App listens for next onWake event
3. "Hey Even" can be triggered again immediately
```

---

## BLE Service Map

| Service | Purpose |
|---------|---------|
| **0x07** | **Dashboard / AI session** -- THE primary AI channel |
| 0x01 | News/stock data push (NOT the AI session) |
| 0x0B | Conversate (real-time text display, alternative to 0x07) |
| 0x0E | Widget dashboard config (brightness, refresh rates) |
| 0x09 | Device info, battery, brightness settings |
| 0x80 | Auth, time sync, heartbeats, ring info |
| 0xE0 | EvenHub app service (containers, audio control, IMU) |
| 0x91 | Ring presence (MAC registration) |

---

## Critical Init Packets

These must be sent after authentication for the AI interface to work:

1. Auth RIGHT ear (0x80-0x00, cmd=4)
2. Pipe role (0x80-0x20, cmd=5, **f4.f1=2**)
3. Time sync (0x80-0x20, cmd=128)
4. Settings init (0x09-0x20, type=1)
5. STT config (0x03-0x20, type=0)
6. Device config (0x0D-0x20, type=0)
7. Tasks status (0x0C-0x20, type=2)
8. Dashboard init (0x07-0x20, type=10, field13={f1=0, f2=80})
9. **Display/health config (0x0E-0x20, type=4)** -- required for AI interface
10. Skip onboarding (0x10-0x20, type=1)
11. Ring presence (0x91-0x20, type=1) -- optional, only if ring connected
12. Battery query (0x09-0x20, type=2)
13. Content config (0x01-0x20, type=2)
14. EvenHub init (0x81-0x20, type=1)
15. Commit (0x20-0x20, type=0 + type=1)
16. Button mapping (0x09-0x20, type=1)
17. Display wake (0x04-0x20, type=1)
18. Widget batch (0x0E-0x20, type=2) -- 145-byte dashboard layout

---

## Audio Format

- **Codec**: LC3
- **Sample rate**: 16kHz
- **Bitrate**: 32kbps
- **Channels**: Mono
- **Frame duration**: 10ms (160 samples/frame)
- **BLE packet**: 205 bytes = 5 x 40B LC3 frames + 5B trailer
- **Trailer**: [1B value][0x00][1B status][0xFF][1B seq]
- **Characteristic**: UUID 6402 (display service notify)
- **No transport wrapper**: Raw LC3 frames directly on 6402

## Required Libraries for Custom Implementation

| Component | Recommendation |
|-----------|---------------|
| BLE | universal_ble (Flutter) or noble (Node.js) |
| LC3 decode | liblc3 (C), lc3codec (npm), or server-side |
| STT | faster-whisper, whisper.cpp, or cloud API |
| LLM | OpenClaw, Claude API, Ollama, llama.cpp |
