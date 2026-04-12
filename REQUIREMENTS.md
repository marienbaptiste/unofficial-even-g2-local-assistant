# Requirements — Unofficial Even G2 Local AI Assistant

Last updated: 2026-04-04

## 1. Project Goal

Build a fully local AI assistant for Even G2 smart glasses that requires no cloud services and no Even app. The pipeline: **Glasses mic -> Whisper STT -> Live transcription on glasses display**.

## 2. System Architecture

```
Even G2 Glasses  <--BLE-->  Flutter App (Desktop)  <--WebSocket-->  Voice Service (Docker)
   LC3 audio                   bridge + UI                        LC3 decode + Whisper STT
   display text
```

## 3. Components

### 3.1 Even G2 Flutter SDK (`sdk/`)

**Purpose:** Cross-platform BLE SDK for the Even G2 glasses protocol.

| Requirement | Status | Notes |
|---|---|---|
| BLE scanning and connection | Done | `universal_ble` for Windows |
| Auth handshake (automatic) | Done | |
| Time sync | Done | |
| Text display — Conversate mode | Done | Streaming with `showPartial`/`showFinal` |
| Text display — Teleprompter mode | Done | Multi-page, auto word-wrap |
| Heartbeat keep-alive | Done | Every 10s |
| Mic audio streaming | Done | LC3 over GATT UUID 6402 |
| Gesture events | Done | Single/double tap, scroll, long press, head tilt |
| Wear detection toggle | Done | |
| IMU data streaming | Not started | |

**Audio specs from glasses:**
- Codec: LC3 (Low Complexity Communication Codec)
- Sample rate: 16 kHz, mono
- Bitrate: 32 kbps
- Frame duration: 10 ms (160 samples/frame)
- Compressed frame size: 40 bytes
- BLE packet: 205 bytes = 5 x 40-byte LC3 frames + 5-byte trailer

### 3.2 Flutter Desktop App (`app/`)

**Purpose:** Desktop app bridging glasses to voice service.

| Requirement | Status | Notes |
|---|---|---|
| Connect to G2 glasses via BLE | Done | |
| Stream LC3 to voice service (WebSocket) | Done | Real-time forwarding |
| Display live transcription | Done | Scrollable, partials in grey |
| Send finalized text to glasses | Done | Via `showFinal`, last 3 lines |
| Send partial text to glasses | Done | Throttled to 500ms |
| Manual text input to glasses | Done | |
| Whisper health indicator | Done | |
| VU meter | Done | |
| AI assistant integration | Not started | Pending openclaw |

**Dependencies:** Flutter 3.10+, `even_g2_sdk`, `http`, `web_socket_channel`

### 3.3 Voice Service (`server/voice/`)

**Purpose:** Containerized real-time STT, accepts LC3 directly from the Flutter app.

| Requirement | Status | Notes |
|---|---|---|
| Whisper STT (faster-whisper) | Done | WhisperLive streaming, large-v3-turbo |
| Accept LC3 over WebSocket | Done | 205-byte BLE packets or 40-byte frames |
| LC3 decode server-side (liblc3) | Done | 16kHz, 32kbps, google/liblc3 |
| Accept raw PCM over WebSocket | Done | float32 or int16 fallback |
| Batch transcribe (file upload) | Done | POST /api/transcribe (debug) |
| Health check | Done | GET /api/health |
| GPU acceleration (NVIDIA CUDA) | Done | |

**WebSocket protocol (`/ws/stream`):**
- Config: `{"action": "config", "input_format": "lc3", "language": "en"}`
- Binary frames: LC3 (205-byte BLE packets or 40-byte frames) or raw PCM
- Response: `{"segments": [...], "partial": bool}`

**Docker setup:**
- Base: `nvidia/cuda:12.6.3-runtime-ubuntu22.04`
- WhisperLive (Collabora), faster-whisper, liblc3
- FastAPI + uvicorn on port 8081

### 3.4 OpenClaw — AI Brain (`server/openclaw/`) [PLANNED]

**Purpose:** ChatGPT-powered AI that listens to conversation transcripts and responds through the glasses when appropriate.

**It's not a custom service — just:**
1. **Codex CLI** running in Docker (uses ChatGPT Pro subscription, no per-token cost)
2. **soul.md** — system prompt defining personality and behavior
3. Voice service pipes finalized transcripts in, gets responses back

#### Setup Steps

**Step 1: Install Codex CLI in Docker**
- Base image: `openai/codex-universal` or build from Node.js base
- Install: `npm install -g @openai/codex`
- Auth: run `codex login --device-auth` once on host, then mount `~/.codex/auth.json` into container
- Or use `OPENAI_API_KEY` env var if you have one

**Step 2: Create soul.md**
- Place in `server/openclaw/soul.md`
- Codex reads it as instructions via `--config experimental_instructions_file=soul.md`

soul.md should define:
- Response style: concise, max 2-3 short sentences (glasses display = 25 chars/line, ~10 lines)
- When to respond vs stay silent (not every sentence needs a reply)
- Context awareness: meeting mode, conversation mode, note-taking mode
- Proactive behaviors: summarize after silence, flag action items
- Language matching: respond in the same language as the speaker
- Prefix all responses with `[AI]`

**Step 3: Wire it up**
- Voice service sends finalized transcripts to Codex via `codex exec` (stdin pipe, JSON output)
- Or use ChatMock (`github.com/RayBytes/ChatMock`) as a local OpenAI-compatible HTTP API proxy — voice service calls `POST /v1/chat/completions` on the Docker network
- Responses come back through the voice service WebSocket as `{"type": "ai_response", "text": "[AI] ..."}`
- Flutter app displays them on glasses via `showFinal`

**Integration:**
- Voice service pipes finalized transcripts to `codex exec` via stdin
- `codex exec "transcript text" --json` returns structured response
- Streams progress to stderr, final output to stdout
- Response sent back through voice service WebSocket as `{"type": "ai_response", "text": "[AI] ..."}`

```yaml
# docker-compose addition
openclaw:
  image: openai/codex-universal
  container_name: even-g2-openclaw
  volumes:
    - codex-auth:/root/.codex          # auth token (from host login)
    - ./openclaw/soul.md:/app/soul.md  # personality
  restart: unless-stopped
```

| Requirement | Status |
|---|---|
| Codex CLI or ChatMock in Docker | Not started |
| soul.md personality definition | Not started |
| Auth flow (device code or token mount) | Not started |
| Voice service -> openclaw pipe/HTTP | Not started |
| Response routing back to glasses as `[AI]` | Not started |
| Conversation history / context window | Not started |
| Mode switching (meeting, conversation, notes) | Not started |

### 3.5 Docker Services

| Container | Port | Purpose |
|---|---|---|
| even-g2-voice | 8081 | Whisper STT + LC3 decode |
| even-g2-openclaw | 8000 | AI reasoning (ChatGPT) [PLANNED] |

## 4. End-to-End Pipeline

### Current (STT only)
```
1. G2 glasses mic captures audio (LC3 encoded)
2. 205-byte BLE packets sent to Flutter app
3. Flutter app forwards LC3 packets via WebSocket to voice service
4. Voice service decodes LC3 -> PCM, runs Whisper STT
5. Partial transcription streamed back to Flutter app
6. Partials shown in app UI (grey) and on glasses (throttled)
7. Finalized sentences shown on glasses display (last 3 lines)
```

### Target (with AI)
```
1-7. Same as above
8. Voice service forwards finalized transcript to openclaw
9. OpenClaw evaluates whether to respond (soul.md rules)
10. If responding: sends context to ChatGPT, gets response
11. Response sent back through voice service WebSocket as {"type": "ai_response"}
12. Flutter app displays "[AI] response" on glasses
```

## 5. Non-Functional Requirements

| Requirement | Target |
|---|---|
| Cloud dependency | None for STT; ChatGPT subscription for AI responses |
| STT latency | < 500ms end-to-end |
| AI response latency | < 3s from finalized transcript |
| Supported platforms | Windows (primary), macOS, Linux |
| GPU requirement | NVIDIA GPU with CUDA |
| BLE requirement | Bluetooth 5.0+ |

## 6. External Dependencies & Licenses

| Dependency | License |
|---|---|
| WhisperLive (Collabora) | Apache 2.0 |
| faster-whisper | MIT |
| liblc3 (Google) | Apache 2.0 |
| universal_ble | BSD-3 |

## 7. Planned

- OpenClaw AI assistant with soul.md and Codex CLI
