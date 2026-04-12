# Sending Text to G2 Display

## Overview
Multiple services can display text on the G2 glasses: Teleprompter, Conversate (real-time transcription), Translate, Even AI, Quick List, and Notifications. Each has its own protobuf protocol on the same BLE transport.

---

## BLE Addresses

| UUID Suffix | Full UUID | Direction | Purpose |
|-------------|-----------|-----------|---------|
| `5401` | `00002760-08C2-11E1-9073-0E8AC72E5401` | Write | Send text commands |
| `5402` | `00002760-08C2-11E1-9073-0E8AC72E5402` | Notify | Receive acknowledgments |
| `6401`/`6402` | `...6401` / `...6402` | Write | Display rendering data |

---

## Method 1: Teleprompter (Best for Long Text)

The most documented text display protocol. Sends paginated text content.

### Service ID: `0x06-20` (from community docs)

### Protobuf Messages
- `TelepromptPageData` — page content
- `TelepromptPageDataRequest` — glasses requests a page
- `TELEPROMPT_CONTROL` — start/stop teleprompter
- `TELEPROMPT_PAGE_DATA` — send page text
- `TELEPROMPT_FILE_LIST` / `TELEPROMPT_FILE_LIST_REQUEST` — script list
- `TELEPROMPT_FILE_SELECT` — select a script
- `TELEPROMPT_HEART_BEAT` — keep-alive
- `TELEPROMPT_STATUS_NOTIFY` — status updates
- `TELEPROMPT_PAGE_AI_SYNC` — AI-triggered scroll sync
- `TELEPROMPT_PAGE_SCROLL_SYNC` — manual scroll sync
- `TELEPROMPT_COMM_RESP` — command response

### Text Display Parameters (from community docs)
- **Display width**: ~267px
- **Line height**: ~230 units
- **Lines per page**: 10 (7 visible)
- **Characters per line**: ~25 (with line wrapping)
- **Encoding**: UTF-8 with newline separators

### Protocol Flow
```
1. Send TELEPROMPT_CONTROL (init) with display settings → 5401
   - script_index, display_width, content_height, viewport_height
   - font_size, scroll_mode (0x00=manual, 0x01=AI-triggered)
2. Send TELEPROMPT_FILE_LIST → 5401
3. Send TELEPROMPT_PAGE_DATA for each page → 5401
   - page_number, line_count, text (UTF-8 bytes)
   - 10 lines per page
4. After streaming: send TELEPROMPT_COMM_RESP (complete marker)
   - start_page, total_pages, total_lines
5. Glasses display content, user scrolls via gestures
```

### Display Config (0x0E-0x20) — Sent Before Teleprompter (CONFIRMED)

The teleprompter script sends a display configuration packet before rendering text.
This configures the display widget layout with per-eye settings.

Structure: repeated `field 2` sub-messages, each representing a display widget:
- `field 1` [varint]: widget ID (2, 3, 4, 5, 6)
- `field 2` [varint]: parameter (10000, 2000, 0 — varies per widget)
- `field 3` [32-bit float]: value for one eye (or position)
- `field 4` [32-bit float]: value for other eye (or secondary axis)
- `field 5` [varint]: extra parameter
- `field 6` [varint]: extra parameter

**CONFIRMED per-eye control**: Widgets 5 and 6 have different `field 3` and `field 4` float values
(e.g., widget 5: f3=73.0, f4=81.0 — one per eye). This enables independent brightness/rendering
per eye lens.

Default values from teleprompter script:
| Widget | f3 | f4 | f2 |
|--------|------|------|------|
| 2 | 1191.0 | 0.0 | 10000 |
| 4 | 68.0 | 0.0 | 0 |
| 5 | 73.0 | 81.0 | 0 |
| 6 | 99.0 | 98.0 | 0 |

### Teleprompter Gesture Controls (CONFIRMED — working script)
Once text is displayed:
- **Swipe forward** on touchpad: Scroll down
- **Swipe back** on touchpad: Scroll up
- **Tap**: Exit teleprompter

Note: Although the gesture event packets (0x01-0x01) don't encode direction,
the glasses firmware handles scroll direction internally per display mode.
The teleprompter mode maps swipe forward = down, swipe back = up.

### Mid-Stream Marker
Required checkpoint during streaming (from community docs):
- Type `0xFF` with sub-field 1 = 0, sub-field 2 = 6
- Send after page 9, before page 10

---

## Method 2: Conversate (Real-Time Transcription)

Displays live transcription text — ideal for streaming AI responses.

### Protobuf Messages
- `ConversateControl` — start/stop conversate session
- `ConversateTranscribeData` — transcription text
- `ConversateKeypointData` — key points
- `ConversateTagData` — tags
- `ConversateTagTrackingData` — tag tracking
- `ConversateTitleData` — title text
- `ConversateHeartBeat` — keep-alive
- `ConversateStatusNotify` — status
- `ConversateCommResp` — command response

### Command IDs
- `CONVERSATE_CONTROL` — control commands
- `CONVERSATE_TRANSCRIBE_DATA` — transcription data
- `CONVERSATE_KEYPOINT_DATA` — key points
- `CONVERSATE_TAG_DATA` — tags
- `CONVERSATE_TAG_TRACKING_DATA` — tag tracking
- `CONVERSATE_TITLE_DATA` — title
- `CONVERSATE_HEART_BEAT` — heartbeat
- `CONVERSATE_STATUS_NOTIFY` — status notification

### Confirmed Protobuf Structure (from BLE capture 2026-04-03)

Service ID: `0x0B-0x20` (phone→glasses), `0x0B-0x00` (glasses→phone ack)

**Phone → Glasses (0x0B-0x20):**
```
field 1 [varint]: message type
    1   = CONVERSATE_CONTROL (init/start session)
    6   = CONVERSATE_TRANSCRIBE_DATA (text content)
    255 = CONVERSATE_HEART_BEAT (keep-alive marker)
field 2 [varint]: sequence counter (incrementing per message)
field 3 [bytes]:  init config (when type=1)
    sub-field 1 [varint]: 1
    sub-field 2 [bytes]: session settings
        sub-field 1-5: config flags
    sub-field 4 [varint]: 0
field 8 [bytes]:  transcription data (when type=6)
    sub-field 1 [bytes]: UTF-8 text string
    sub-field 2 [varint]: 0 = partial/interim, 1 = final/committed
```

**Glasses → Phone (0x0B-0x00) ack:**
```
field 1  [varint]: 162 (0xA2) — acknowledgment marker
field 2  [varint]: sequence counter (matches the phone's seq)
field 10 [bytes]:  empty (0 bytes)
```

**Observed streaming pattern:**
- Partial results sent as text builds up ("I", "I'm talking right", "I'm talking right now.")
- Each partial has sub-field 2 = 0
- Final committed sentence has sub-field 2 = 1
- Glasses ack every packet with type 0xA2

### Flow
```
1. Send CONVERSATE_CONTROL (start) → 5401
   - type=1, seq=N, field 3 = session config
2. Stream CONVERSATE_TRANSCRIBE_DATA with text → 5401
   - type=6, seq=N+1..., field 8 = {text, is_final}
   - Glasses ack each with type=0xA2 on 5402
   - Partial results (is_final=0) update in real-time
   - Final results (is_final=1) commit the sentence
3. Send CONVERSATE_HEART_BEAT periodically
   - type=0xFF
4. Send CONVERSATE_CONTROL (stop) when done
```

---

## Method 3: Translate (Dual-Language Display)

Displays source and translated text side by side.

### Protobuf Messages
- `TranslateDataPackage` — translation data
- `TranslateResult` — translation result text
- `TranslateNotify` — notification
- `TranslateHeartBeat` — keep-alive
- `TRANSLATE_CTRL` — control
- `TRANSLATE_RESULT` — result text
- `TRANSLATE_MODE_SWITCH` — switch translation mode
- `TRANSLATE_HEARTBEAT` — heartbeat
- `TRANSLATE_NOTIFY` — notification

### Flow
```
1. Send TRANSLATE_CTRL (start, with language pair) → 5401
2. Stream TRANSLATE_RESULT with translated text → 5401
3. Send TRANSLATE_HEARTBEAT periodically
4. Send TRANSLATE_CTRL (stop) when done
```

---

## Method 4: Even AI (AI Response Display)

Displays AI assistant responses — the most relevant for a custom AI pipeline.

### Protobuf Messages
- `EvenAIControl` — control AI session
- `EvenAIReplyInfo` — AI text reply to display
- `EvenAIAskInfo` — user's question
- `EvenAIAnalyseInfo` — analysis info
- `EvenAIPromptInfo` — prompt info
- `EvenAISkillInfo` — skill info (navigate, translate, etc.)
- `EvenAIVADInfo` — voice activity detection
- `EvenAIConfig` — AI configuration
- `EvenAIHeartbeat` — keep-alive
- `EvenAIEvent` — AI events
- `EvenAISentiment` — sentiment data

### Command IDs
- `EVEN_AI_ENTER` — start AI session
- `EVEN_AI_EXIT` — end AI session
- `EVEN_AI_WAKE_UP` — wake word detected (glasses → phone)

### AI Response Flow
```
1. Receive EVEN_AI_WAKE_UP from glasses on 5402
2. Send sendWakeupResp acknowledgment → 5401
3. Capture audio, run STT
4. Process with your AI
5. Send EvenAIReplyInfo with response text → 5401
   - ProtoAiExt|sendAIReplay
6. Glasses display the AI response
7. Send EVEN_AI_EXIT when conversation ends
```

---

## Method 5: Quick List

Display task/note items.

### Flow
```
1. _createQuickListDataPackage with items
2. Send to glasses → 5401
3. User scrolls through items with gestures
```

---

## Method 6: Notifications

Display notification metadata (app name + count, not full text).

### Protobuf Messages
- `NotificationDataPackage`
- `NotificationWhitelistCtrl` — control which apps show notifications
- `NotificationIOS` — iOS-specific notification handling
- `NOTIFICATION_CTRL` — control commands
- `NOTIFICATION_JSON_WHITELIST` — whitelist config

---

## Method 7: Dashboard

Display widgets (calendar, weather, stocks, etc.).

### Protobuf Messages
- Dashboard data via `_createDashboardDataPackage`
- Widget types: calendar, stocks, news, weather
- `Dashboard_Receive` / `Dashboard_Respond`

---

## Recommended Approach for Custom AI Assistant

**Use the Even AI protocol** (`EvenAIReplyInfo` / `sendAIReplay`):

```
1. Connect + authenticate
2. Listen for EVEN_AI_WAKE_UP on 5402
3. Send wakeup response
4. Capture audio → STT (Whisper)
5. Process with your LLM
6. Send AI reply text via EvenAIReplyInfo → 5401
7. Glasses display your response
```

Or **use Conversate** for streaming real-time text:
```
1. Start conversate session
2. Stream text updates as they arrive from your AI
3. Glasses show text in real-time
```

---

## What Has Been Confirmed (2026-04-03/04)
- **Teleprompter** (0x06-0x20): Fully working script, tested with live text display
- **Conversate** (0x0B-0x20): Full protobuf decoded, text streaming with partial/final markers confirmed
- **Mic audio capture**: Works on UUID 6402 (display notify channel), LC3 decoded live, 10s recording tested
- **Display config** (0x0E-0x20): Per-eye float values, widget layout structure decoded
- **Gesture controls**: Swipe forward/back and tap confirmed in teleprompter mode

## Conversate Message Types (Decoded 2026-04-12)

Beyond the basic type=1 (init), type=6 (transcription data), and type=0xFF (heartbeat), the Conversate service (0x0B) supports additional message types for AI interaction:

### Type=5: AI Response Card (with icons)
Displays a rich AI response card on the glasses.
```
field 7:
  field 1 [varint]: icon type (1=link, 2=AI/doc, 3=person)
  field 2 [string]: title string
  field 3 [string]: body string
  field 4 [varint]: done flag (0=partial/streaming, 1=final)
```

### Type=7: User Prompt Display
Shows the user's spoken text (transcription) on the glasses display.
```
field 13:
  field 1 [varint]: 0
  field 2 [string]: user's spoken text (transcribed)
```

### Type=1 with Title
Init message can include a title for the session:
```
field 3:
  field 3:
    field 1 [string]: "title text"
    field 2 [varint]: 1
```

### Type=1 Stop Session
To stop a Conversate session:
```
field 3:
  field 1 [varint]: 2 (stop session)
```

---

## What Still Needs Work
- EvenAIReplyInfo protobuf field numbers and format (service 0x01-0x20 carries AI text but exact fields TBD)
- How the glasses handle text wrapping and scrolling internally
- Maximum text length per packet
- Widget ID to setting name mapping (which widget = intensity vs height vs distance)
- Translate and Transcribe text display protocols
