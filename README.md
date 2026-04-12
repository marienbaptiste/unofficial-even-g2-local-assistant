![Even G2 Local AI Assistant](Header.png)

# Unofficial Even G2 Local AI Assistant

A local AI assistant for Even G2 smart glasses — no Even app required.

**Glasses mic -> Whisper STT -> Live transcription + AI responses on glasses display**

## Architecture

```
Even G2 Glasses  <--BLE-->  Flutter App  <--WebSocket-->  Voice Service  --> OpenClaw
   LC3 audio                  bridge                     LC3 + Whisper      ChatGPT
   display text               + UI                                        SOUL.md
```

## Components

### `sdk/` — Even G2 Flutter SDK

Cross-platform BLE SDK for the Even G2 glasses protocol. Handles connection, authentication, display, microphone, gestures, and settings.

```dart
final g2 = EvenG2();
await g2.connectToNearest();
await g2.display.show("Hello!");
await g2.mic.start();
```

### `app/` — Flutter Desktop App

Bridges the glasses to the voice service:

- Connects to G2 glasses via BLE
- Streams LC3 audio to the voice service via WebSocket
- Displays live transcription (partial + finalized)
- Sends transcription to the glasses display in real-time
- Shows Whisper and OpenClaw health indicators

### `server/voice/` — Voice Service (Docker)

Real-time speech-to-text with server-side LC3 decoding:

- **WhisperLive** streaming STT (faster-whisper, large-v3-turbo)
- **liblc3** decodes G2 glasses audio (16kHz, 32kbps)
- NVIDIA GPU accelerated (CUDA)

### `server/openclaw/` — AI Brain (Docker)

OpenClaw with ChatGPT Pro subscription via Codex CLI:

- Receives finalized transcriptions from the voice service
- **[`server/openclaw/SOUL.md`](server/openclaw/SOUL.md)** defines personality, response style, and when to speak vs stay silent
- Responses displayed on glasses prefixed with `[AI]`
- No per-token API costs (uses ChatGPT subscription)
- Health endpoint at `/healthz` on port 18789

## Quick Start

### Prerequisites

- Flutter SDK 3.10+
- Docker Desktop with NVIDIA GPU support
- Bluetooth 5.0+ on host machine
- NVIDIA GPU with CUDA drivers
- ChatGPT Pro subscription (for OpenClaw AI responses)

### 1. Build and start the voice service

```bash
cd server

# Build base image (first time only, ~15 min)
docker build -f voice/Dockerfile.base -t even-g2-voice-base ./voice

# Start the voice service
docker compose up -d
```

Whisper model downloads on first startup (~1-2 min).

### 2. Set up OpenClaw (AI brain)

> The onboarding wizard is interactive — run these commands in a **regular terminal** (PowerShell, cmd, or bash), not from Claude Code.

#### Step 1: First-time setup

Pull the OpenClaw image and run the onboarding wizard:

```bash
cd server
docker compose up -d openclaw
docker compose exec -it openclaw openclaw setup --wizard
```

The wizard will:
1. Ask you to accept the security notice — select **Yes**
2. Ask you to choose an LLM provider — select **OpenAI Codex (ChatGPT OAuth)**
3. Open a browser window — log in with your ChatGPT account and authorize
4. Save credentials to `~/.openclaw/`

Then set the active model:

```bash
docker compose exec openclaw openclaw models set openai-codex/gpt-5.3-codex
```

#### Step 2: Configure for Docker networking

Edit `~/.openclaw/openclaw.json` and add to the `gateway` section:

```json
{
  "gateway": {
    "bind": "lan",
    "http": {
      "endpoints": {
        "chatCompletions": { "enabled": true }
      }
    },
    "controlUi": {
      "allowInsecureAuth": true,
      "allowedOrigins": ["http://localhost:18789", "http://127.0.0.1:18789"],
      "dangerouslyAllowHostHeaderOriginFallback": true
    }
  }
}
```

Restart to apply:

```bash
docker compose restart openclaw
```

#### Step 3: SOUL.md personality

The `SOUL.md` file is automatically mounted from `server/openclaw/SOUL.md` into the container. Edit it to change how the AI behaves. See [`server/openclaw/SOUL.md`](server/openclaw/SOUL.md).

#### Step 4: Verify

```bash
# Health check (should return {"ok":true,"status":"live"})
curl http://localhost:18789/healthz

# Test a chat completion
curl -X POST http://localhost:18789/v1/chat/completions \
  -H "Authorization: Bearer $(cat ~/.openclaw/token.txt 2>/dev/null || grep token ~/.openclaw/openclaw.json | head -1 | grep -o '[a-f0-9]\{64\}')" \
  -H "Content-Type: application/json" \
  -d '{"model":"openclaw","messages":[{"role":"user","content":"Hello"}]}'
```

Copy the token from the output, then open http://localhost:18789 in your browser and paste it when prompted.

### 3. Run the Flutter app

```bash
cd app
flutter pub get
flutter run -d windows  # or macos, linux
```

### 4. Connect glasses

1. Put on your Even G2 glasses
2. Click **Connect** in the app
3. Audio streams to Whisper automatically
4. Live transcription appears in the app and on the glasses
5. Whisper and OpenClaw health indicators show green in the app bar

### 5. Stopping services

```bash
cd server
docker compose down        # stop all (voice + openclaw)
docker compose stop        # stop without removing containers
docker compose up -d       # restart everything
docker compose restart openclaw   # restart just openclaw
docker compose logs -f     # view live logs
```

## Docker Services

| Container | Port | Health endpoint | Purpose |
|---|---|---|---|
| even-g2-voice | 8081 | `/api/health` | Whisper STT + LC3 decode |
| openclaw-gateway | 18789 | `/healthz` | AI reasoning (OpenClaw + ChatGPT) |

## Voice Service API

| Endpoint | Method | Description |
|---|---|---|
| `/ws/stream` | WebSocket | Real-time LC3/PCM streaming STT |
| `/api/transcribe` | POST | Batch file transcription (debug) |
| `/api/health` | GET | Health check |

## Status

- [x] BLE connection + authentication
- [x] Text display (Conversate + Teleprompter)
- [x] Mic streaming (LC3)
- [x] Live STT with Whisper (server-side LC3 decode)
- [x] Real-time transcription on glasses display
- [x] Gesture detection
- [x] OpenClaw running with SOUL.md and ChatGPT
- [x] Voice service -> OpenClaw transcript forwarding
- [x] AI responses displayed on glasses
- [ ] Speaker diarization — identify who is speaking in multi-person conversations
- [ ] Local LLM support — port to a powerful machine with local model for sub-second latency
- [ ] AI response truncation — long answers overflow the display (~25 chars × 10 lines max)
- [ ] AI card display format (icons, multi-line) — currently falls back to plain text
- [ ] BLE connection stability (occasional disconnects on Windows)
- [ ] Dual earpiece connection (L+R redundancy)
- [ ] EvenHub container system (custom page layouts)
- [ ] IMU data streaming (head tracking)

> **Warning**: This is an early prototype and a work in progress. Expect rough edges, occasional BLE disconnects, and incomplete features. The protocol is reverse-engineered and may break with Even app firmware updates.

## License

MIT — for demonstration and educational purposes. Not affiliated with Even Realities. See [LICENSE](LICENSE).
