# Reconstructed Protobuf Definitions — Even G2 + R1

## Sources & Confidence Levels

| Tag | Meaning |
|-----|---------|
| `[CONFIRMED]` | Verified via BLE capture analysis and live testing |
| `[INFERRED]` | Field name identified from protocol analysis, tag number uses conventional ordering — needs BLE capture verification |
| `TBD` | Field exists but internal structure unknown |

## Proto Files

| File | Service | Service ID | Confidence |
|------|---------|-----------|------------|
| `g2_transport.proto` | Transport layer, packet format | N/A (binary) | HIGH — confirmed by community |
| `teleprompter.proto` | Teleprompter (paginated text) | `0x06-0x20` | HIGH — tag numbers confirmed |
| `conversate.proto` | Real-time transcription | `0x0B-0x20` | MEDIUM — service ID confirmed, some tags confirmed |
| `even_ai.proto` | AI assistant | Unknown | LOW — field names confirmed, tag numbers inferred |
| `audio.proto` | Microphone/audio control | Unknown | LOW — field names confirmed, tags inferred |
| `transcribe.proto` | Speech transcription | Unknown | MEDIUM — APK has actual `.proto` for TranscribeResult |
| `translate.proto` | Translation | Unknown | MEDIUM — APK has actual `.proto` for TranslateResult |
| `dashboard.proto` | Dashboard widgets | `0x07-0x20` | MEDIUM — some tags confirmed |
| `notification.proto` | Notifications | `0x02-0x20` | MEDIUM — some tags confirmed |
| `display.proto` | Display/image transfer | `0x04-0x20`, `0x0E-0x20` | MEDIUM — display config tags confirmed |
| `g2_setting.proto` | Settings + EvenHub + Auth | `0x81-0x20`, `0x80-0x20` | HIGH — auth tags confirmed |
| `navigation.proto` | Turn-by-turn nav | Unknown | LOW — structure inferred |
| `ring.proto` | R1 ring bridge + health | Unknown (ring is binary, not protobuf) | LOW |
| `glasses_case.proto` | Case, quick list, menu, OTA | Various | LOW |

## Known Service ID Map

```
Confirmed (inferred from code, 0x20 low byte confirmed by community teleprompter.py):
  0x80-0x00 = Sync
  0x80-0x20 = Auth / Session
  0x80-0x01 = Auth Response                [ADDED 2026-03-28]
  0x02-0x20 = Notification
  0x04-0x20 = Display Wake
  0x06-0x20 = Teleprompter
  0x07-0x20 = Dashboard
  0x0B-0x20 = Conversate
  0x0C-0x20 = Tasks                        [ADDED 2026-03-28]
  0x0D-0x20 = Config
  0x0E-0x20 = Display Config
  0x11-0x20 = Conversate (alt)             [ADDED 2026-03-28]
  0x20-0x20 = Commit                       [ADDED 2026-03-28]
  0x81-0x20 = EvenHub / Display Trigger

Need BLE capture to confirm:
  Even AI, Audio, Transcribe, Translate, Navigation,
  Health, Ring, Quick List, Menu, OTA, Logger, Onboarding
```

> **[UPDATED 2026-03-28]** Fixed all service ID low bytes from `0x14` to `0x20`. The `0x14` was a decimal/hex mixup (decimal 20 = `0x14`, but the actual wire byte is `0x20` = hex 32). Confirmed against community teleprompter.py. Added 4 service IDs inferred from code. All service IDs are inferred from code analysis — not yet BLE-capture verified.

## What's Verified vs What Needs BLE Snoop

### Fully verified (can implement now):
- Transport packet format (header, CRC)
- Teleprompter full protocol (init, pages, complete, marker)
- Auth handshake sequence
- Display config regions
- BLE UUIDs for all channels

### Partially verified (field names correct, tag numbers may differ):
- Conversate start/stop + transcribe data streaming
- Even AI wake-up event flow
- Notification metadata display

### Needs BLE snoop capture to implement:
- Exact service ID bytes for: Even AI, Audio, Transcribe, Translate, Navigation
- Audio control command protobuf structure (AudioCtrCmd)
- EvenAIReplyInfo field numbers (for sending AI responses)
- Ring binary protocol command bytes (NOT protobuf)
- File service protocol for image transfer
- LC3 codec parameters (dtUs, srHz) confirmation

## How to Use with nRF52840

1. Start with **Teleprompter** — fully confirmed, can display text immediately
2. Use the working Python example as reference: `even-g2-protocol/examples/teleprompter/`
3. For AI responses, try **Conversate** first (service ID confirmed) before Even AI
4. For audio capture, implement wake word detection flow and LC3 decoding
5. For ring input, implement the binary protocol on BAE80012/BAE80013

## Proto Modules in the Even App

The compiled Dart binary references these protobuf modules:
```
even_connect/g2/proto/generated/
├── even_ai/          — AI assistant
├── conversate/       — Real-time transcription
├── translate/        — Translation
├── transcribe/       — Speech-to-text
├── teleprompt/       — Teleprompter
├── dashboard/        — Dashboard widgets
├── notification/     — Notifications
├── navigation/       — Turn-by-turn nav
├── EvenHub/          — Event bus
├── g2_setting/       — Device settings
├── glasses_case/     — Case status
├── common/           — Shared enums
├── health/           — Health data
├── ring/             — Ring bridge
├── menu/             — Menu system
├── quicklist/        — Quick list
├── dev_config_protocol/ — Device config
├── dev_settings/     — Device settings
├── dev_pair_manager/ — Pairing
├── dev_infomation/   — Device info (typo in original)
├── efs_transmit/     — File service
├── ota_transmit/     — OTA updates
├── module_configure/ — Module config
├── logger/           — Logging
├── sync_info/        — Sync state
├── onboarding/       — Setup flow
└── service_id_def/   — Service ID definitions
```
