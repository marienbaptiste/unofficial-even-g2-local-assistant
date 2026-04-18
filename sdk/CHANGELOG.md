## 0.4.0 (2026-04-18)

- **Dual-model AI routing** (in app layer, not SDK) — Qwen 2.5 7B local via Ollama for fast answers, ChatGPT via OpenClaw for complex questions with web access
- **Automatic fallback** between models if one fails
- **Model + timing in debug panel** — see which model answered and how long it took
- **Enforced [AI] prefix** on all responses
- **SOUL.md updated** to allow web search and tools for factual questions

## 0.3.0 (2026-04-14)

- **Dual-ear BLE connection** — connects both left (display) and right (events) ears
- **"Hey Even" wake word detection** — f4.f1=2 callback registration in auth pipe role
- **Full AI session flow** — Dashboard service 0x07: transcription, thinking, response streaming
- **14-step init sequence** matched to Even app BLE captures
- **EvenHub container system** — custom page layouts with text/image containers
- **AI card display** — rich cards with icons (link, AI, person, location, question)
- **Ring presence** — dynamic MAC registration (0x91 service)
- **Widget dashboard config** — per-eye brightness control via 0x0E service
- **Auto-reconnect** with exponential backoff
- **Debug events stream** for protocol analysis

## 0.1.0 (2026-04-03)

- Initial release
- BLE scanning, connection, and authentication (7-packet handshake with time sync)
- Conversate text display (streaming and final text)
- Teleprompter display (multi-page, word-wrapped, manual/auto scroll)
- Mic audio capture (raw LC3 frames from UUID 6402)
- Gesture event parsing (tap, double tap, scroll, long press, head tilt)
- Wear detection toggle
- Display configuration (intensity, balance)
