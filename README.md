![Even G2 Local AI Assistant](Header.png)

# Unofficial Even G2 Local AI Assistant

A local AI assistant for Even G2 smart glasses — no Even app required.

**Glasses mic -> Whisper STT -> Live transcription + AI responses on glasses display**

---

### What's New (2026-04-19)

**Dual-model AI routing via OpenClaw** — Qwen 2.5 7B runs locally on Ollama and is registered as the **primary** model in OpenClaw. ChatGPT via OpenAI Codex is configured as **fallback #1** for thinking / when Qwen can't handle a request. The Flutter app talks to OpenClaw's single `/v1/chat/completions` endpoint and OpenClaw picks the model — no app-side routing logic needed.

### What's New (2026-04-14)

**"Hey Even" AI Assistant** — Full voice assistant flow working locally. Say "Hey Even", ask a question, see the AI response streamed directly to your glasses display. Uses the Dashboard service (0x07) with dual-ear BLE connection, wake word detection, live transcription, and response streaming — all reverse-engineered from the official protocol.

**BLE Capture & Analysis Tool** — Web-based tool for reverse-engineering new features. Captures HCI snoop logs from an Android phone, decodes G2 transport packets, and shows protobuf field trees with service filtering and capture comparison. Everything you need to extend the SDK.

---

## Architecture

```
Even G2 Glasses  <--BLE-->  Flutter App  <--WebSocket-->  Voice Service  (Whisper STT)
   LC3 audio                  bridge                           |
   display text               + AI card         ──────┬──> Qwen 2.5 7B (Ollama, local)
                                                    └──> OpenClaw --> ChatGPT (web)
```

The Flutter app sends every question to OpenClaw's single `/v1/chat/completions` endpoint. OpenClaw routes internally: Qwen as primary (fast, local), GPT via OpenAI Codex as fallback #1 (when Qwen fails). The glasses display shows both the unaltered conversation response and a dedicated AI card with the model name next to a lightbulb icon.

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

Bridges the glasses to the AI pipeline:

- Connects to G2 glasses via BLE (dual-ear)
- Streams LC3 audio to the voice service via WebSocket
- Displays live transcription on the glasses (partial + finalized)
- Sends every question to OpenClaw (OpenClaw handles model routing internally)
- Enforces `[AI]` prefix on every response
- Renders each AI response as both a conversation message and an AI card (lightbulb icon + model name)
- Shows Whisper and OpenClaw health indicators
- Debug panel logs which model answered and timing

### `server/voice/` — Voice Service (Docker)

Real-time speech-to-text with server-side LC3 decoding:

- **WhisperLive** streaming STT (faster-whisper, large-v3-turbo)
- **liblc3** decodes G2 glasses audio (16kHz, 32kbps)
- NVIDIA GPU accelerated (CUDA)

### `server/openclaw/` — ChatGPT Brain (Docker)

OpenClaw with ChatGPT Pro subscription via Codex CLI. Used for complex questions needing reasoning or web search:

- Receives finalized transcriptions from the Flutter app
- **[`server/openclaw/SOUL.md`](server/openclaw/SOUL.md)** defines personality, response style, and when to speak vs stay silent (with web tool access enabled)
- Health endpoint at `/healthz` on port 18789

### `server/ollama/` — Local LLM (Docker)

Ollama runs Qwen 2.5 7B (~5GB VRAM Q4_K_M) for fast local answers:

- OpenAI-compatible API on port 11434
- NVIDIA GPU accelerated
- Used for simple/conversational questions — sub-second responses
- Zero cost per request

## Quick Start

### Prerequisites

- Flutter SDK 3.10+
- Docker Desktop with NVIDIA GPU support
- Bluetooth 5.0+ on host machine
- NVIDIA GPU with CUDA drivers
- ChatGPT Pro subscription (for OpenClaw AI responses)

### 1. Build and start all services

```bash
cd server

# Build base image (first time only, ~15 min)
docker build -f voice/Dockerfile.base -t even-g2-voice-base ./voice

# Start all services (voice + openclaw + ollama)
docker compose up -d
```

Whisper model downloads on first startup (~1-2 min). Ollama image pulls automatically.

### 1b. Pull Qwen 2.5 7B into Ollama

```bash
docker exec even-g2-ollama ollama pull qwen2.5:7b
```

This is a one-time ~5GB download. Used for fast local answers.

### 1c. Configure OpenClaw to use Qwen as primary, ChatGPT as fallback

Edit `~/.openclaw/openclaw.json` (after the OpenClaw onboarding wizard has created it) and merge in these keys:

```json
{
  "models": {
    "providers": {
      "ollama": {
        "baseUrl": "http://even-g2-ollama:11434",
        "apiKey": "ollama-local",
        "api": "ollama",
        "models": [
          { "id": "qwen2.5:7b", "name": "qwen2.5:7b", "contextWindow": 32768 }
        ]
      }
    }
  },
  "agents": {
    "defaults": {
      "model": {
        "primary": "ollama/qwen2.5:7b",
        "fallbacks": ["openai-codex/gpt-5.4"]
      }
    }
  }
}
```

Then restart OpenClaw:

```bash
docker compose restart openclaw
docker exec even-g2-openclaw openclaw models list  # verify
```

You should see `ollama/qwen2.5:7b` with tag `default` and `openai-codex/gpt-5.4` with tag `fallback#1`.

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
| even-g2-openclaw | 18789 | `/healthz` | ChatGPT reasoning + web search |
| even-g2-ollama | 11434 | `/api/tags` | Qwen 2.5 7B local LLM |

## Voice Service API

| Endpoint | Method | Description |
|---|---|---|
| `/ws/stream` | WebSocket | Real-time LC3/PCM streaming STT |
| `/api/transcribe` | POST | Batch file transcription (debug) |
| `/api/health` | GET | Health check |

## Two Modes

### Conversate Mode
Always-on mic streaming. Audio goes to Whisper, live transcription appears on glasses. AI responds to relevant speech via OpenClaw.

### Even AI Mode
Wake-word activated. Say **"Hey Even"** and the glasses activate the AI listening interface. Speak your question, the app transcribes via Whisper, sends to OpenClaw, and streams the response back to the glasses display — just like the official Even AI, but running locally.

## Status

### Working
- [x] Dual-ear BLE connection (left=display, right=events)
- [x] Full authentication + 14-step init sequence
- [x] "Hey Even" wake word detection + AI session flow
- [x] Live transcription on glasses (Dashboard service 0x07)
- [x] AI thinking indicator + response streaming
- [x] Text display (Conversate + Teleprompter + AI cards)
- [x] Mic streaming (LC3, 16kHz/32kbps/mono)
- [x] Whisper STT with server-side LC3 decode
- [x] **Local LLM (Qwen 2.5 7B via Ollama) for fast answers**
- [x] **ChatGPT via OpenClaw for complex questions + web search**
- [x] **Smart model routing with automatic fallback**
- [x] **Model + timing indicator in debug panel**
- [x] Gesture detection (tap, double-tap, scroll, head tilt)
- [x] EvenHub container system (custom page layouts)
- [x] AI card display (icons + title + body)
- [x] Auto-reconnect on BLE disconnect
- [x] Ring presence registration (dynamic MAC)

### Not Yet Implemented
- [ ] Speaker diarization
- [ ] AI response truncation for long answers
- [ ] IMU data streaming (head tracking)
- [ ] Notification forwarding (0xC5 whitelist decoded but not used)
- [ ] Navigation display
- [ ] Ring gesture integration

> **Warning**: This is an early prototype. The protocol is reverse-engineered and may break with Even app firmware updates.

## Extending the SDK — BLE Capture Tool

A web-based BLE capture and analysis tool is included for reverse-engineering new features.

### Setup

Requires an Android phone with ADB connected and Developer Options > Bluetooth HCI Snoop Log enabled.

```bash
cd reverse-engineering/tools
pip install -r requirements.txt
python capture_server.py
```

Open **http://localhost:8642** in your browser.

### Capture Workflow

1. **Describe** what you're about to capture (e.g. "Hey Even AI session")
2. **Start Capture** — automatically enables HCI snoop logging and restarts Bluetooth
3. **Perform the action** on the Even app while glasses are connected to the phone
4. **Stop & Analyze** — pulls the btsnoop log, decodes G2 transport packets, and shows results

### Analysis Features

- **Services tab**: All discovered service IDs with packet counts
- **Packets tab**: Decoded protobuf field trees, filterable by service and direction
- **Handles tab**: ATT handle map
- **Delta tab**: Compare with previous capture to find new/changed services
- **Capture History**: Reload any past capture

Results are saved as JSON in `reverse-engineering/tools/results/`. Protocol documentation is in `reverse-engineering/docs/` and protobuf definitions in `reverse-engineering/proto/`.

## License

MIT — for demonstration and educational purposes. Not affiliated with Even Realities. See [LICENSE](LICENSE).
