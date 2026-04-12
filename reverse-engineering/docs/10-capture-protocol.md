# Step-by-Step Protocol to Fill All Missing Information

## Overview

There are **100+ inferred fields** and **14+ unknown service IDs** across the reconstructed protos. This document is an ordered capture plan to systematically fill every gap using BLE traffic analysis.

---

## Prerequisites

### Hardware
- Android phone with Even app installed and paired to G2 glasses + R1 ring
- nRF52840 board (for later implementation; can also be used as BLE sniffer)
- USB cable for phone (ADB access)
- Optional: second nRF52840 with nRF Sniffer firmware for passive sniffing

### Software
- **Wireshark** (with BLE dissector)
- **ADB** (Android Debug Bridge)
- **protoc** / `protoscope` (protobuf binary decoder)
- **Python 3** with `protobuf`, `bleak` libraries
- **nRF Connect** app (on phone, for manual BLE exploration)
- **text editor** for hex analysis

### Setup: Enable Android HCI Snoop Log
This captures ALL Bluetooth traffic between phone and glasses/ring at the HCI level.

```bash
# Method 1: Developer Options
# Phone Settings → Developer Options → Enable Bluetooth HCI snoop log
# Toggle Bluetooth OFF then ON to start fresh capture

# Method 2: ADB (if Developer Options toggle doesn't work)
adb shell settings put secure bluetooth_hci_snoop_log_mode full
adb shell svc bluetooth disable
adb shell svc bluetooth enable
```

### Setup: Locate the Snoop Log
```bash
# After capturing, pull the log:
adb pull /data/misc/bluetooth/logs/btsnoop_hci.log ./captures/

# Or on newer Android:
adb bugreport bugreport.zip
# Extract bluetooth_hci.log from the bugreport
```

---

## Phase 1: Service ID Discovery (30 min)

**Goal**: Map every service to its 2-byte service ID in the transport header.

### Step 1.1 — Baseline Capture
1. Enable HCI snoop log
2. Open Even app
3. Connect to G2 glasses (let it complete auth + sync)
4. **Do nothing for 30 seconds** — capture idle heartbeats
5. Pull snoop log

### Step 1.2 — Identify Known Services
Open in Wireshark, filter to GATT writes on handle for characteristic `5401`:

```
btatt.handle == 0x???? && btatt.opcode == 0x52
```

(Find the handle by looking for the UUID `...5401` in the ATT discovery phase)

For each packet:
1. Find the `0xAA` magic byte
2. Read bytes 6-7 (service ID)
3. Correlate with the known service IDs:

```
Already confirmed: 0x80-00, 0x80-14, 0x02-14, 0x04-14, 0x06-14,
                   0x07-14, 0x0B-14, 0x0D-14, 0x0E-14, 0x81-14
```

The auth handshake and initial sync will reveal: Auth, Sync, Display Config, Display Wake, EvenHub, and possibly Dashboard/Notification service IDs in action.

### Step 1.3 — Trigger Each Service (one at a time)

For each unknown service, trigger it in the app and capture the NEW service ID that appears:

| Action in App | Expected Service | What to Look For |
|---------------|-----------------|------------------|
| Open Teleprompter, load a script | Teleprompter (0x06) | Already known — use as validation |
| Start "Conversate" (live transcription) | Conversate (0x0B) | Already known — validate |
| Say "Hey Even" (wake word) | Even AI | **NEW service ID** — the first unknown packet after wake |
| Start "Translate" feature | Translate | **NEW service ID** |
| Start "Transcribe" feature | Transcribe | **NEW service ID** |
| Open Dashboard (tilt head up) | Dashboard (0x07) | Already known — validate |
| Trigger a phone notification | Notification (0x02) | Already known — validate |
| Open Navigation (start directions) | Navigation | **NEW service ID** |
| Open Quick List | Quick List | **NEW service ID** |
| Open Health page (with ring) | Health | **NEW service ID** |
| Pair/connect R1 ring | Ring bridge | **NEW service ID** on G2 side |
| Put glasses in case | Glasses Case | **NEW service ID** |
| Change display settings | G2 Settings | **NEW service ID** |

**Capture method**: For each action:
1. Start fresh HCI snoop (toggle BT)
2. Connect glasses
3. Wait for idle (10s)
4. Perform ONE action
5. Wait 5s
6. Pull log
7. The new service ID bytes appearing after idle are your target

### Step 1.4 — Record Results

Fill in this table:

```
Service          | svc_hi | svc_lo | Confirmed?
-----------------+--------+--------+-----------
Sync             | 0x80   | 0x00   | YES
Auth             | 0x80   | 0x14   | YES
Notification     | 0x02   | 0x14   | YES
Display Wake     | 0x04   | 0x14   | YES
Teleprompter     | 0x06   | 0x14   | YES
Dashboard        | 0x07   | 0x14   | YES
Conversate       | 0x0B   | 0x14   | YES
Config           | 0x0D   | 0x14   | YES
Display Config   | 0x0E   | 0x14   | YES
EvenHub          | 0x81   | 0x14   | YES
Even AI          | 0x??   | 0x??   | CAPTURE
Transcribe       | 0x??   | 0x??   | CAPTURE
Translate        | 0x??   | 0x??   | CAPTURE
Navigation       | 0x??   | 0x??   | CAPTURE
Quick List       | 0x??   | 0x??   | CAPTURE
Health           | 0x??   | 0x??   | CAPTURE
Ring             | 0x??   | 0x??   | CAPTURE
G2 Settings      | 0x??   | 0x??   | CAPTURE
Glasses Case     | 0x??   | 0x??   | CAPTURE
Audio Control    | 0x??   | 0x??   | CAPTURE
```

---

## Phase 2: Even AI Protocol (1-2 hours) — HIGHEST PRIORITY

**Goal**: Fully decode the Even AI wake-up → audio → reply cycle.

### Step 2.1 — Capture Wake Word Event

1. Start HCI snoop
2. Connect glasses via Even app
3. Wait for idle (10s)
4. Say **"Hey Even"** clearly
5. Wait for the AI prompt to appear on glasses
6. Say a simple question: **"What time is it?"**
7. Wait for AI response to display on glasses
8. Wait 10s more
9. Pull snoop log

### Step 2.2 — Decode Wake-Up Sequence

In the capture, look for packets on 5402 (glasses → phone) immediately after the wake word. This is `EVEN_AI_WAKE_UP`:

1. Find the packet — note the service ID bytes (this gives you the Even AI service ID)
2. Strip the 8-byte transport header and 2-byte CRC
3. Decode the remaining bytes as protobuf:

```bash
# Using protoscope (install: go install github.com/protocolbuffers/protoscope/cmd/protoscope@latest)
echo "<hex bytes>" | xxd -r -p | protoscope

# Or using Python:
python3 -c "
import sys
from google.protobuf.internal.decoder import _DecodeVarint
data = bytes.fromhex('<hex>')
# Manual protobuf decode: each field is (tag << 3 | wire_type)
pos = 0
while pos < len(data):
    tag_byte, new_pos = _DecodeVarint(data, pos)
    field_num = tag_byte >> 3
    wire_type = tag_byte & 0x7
    print(f'Field {field_num}, wire type {wire_type}')
    pos = new_pos
    if wire_type == 0:  # varint
        val, pos = _DecodeVarint(data, pos)
        print(f'  Value: {val}')
    elif wire_type == 2:  # length-delimited
        length, pos = _DecodeVarint(data, pos)
        print(f'  Bytes[{length}]: {data[pos:pos+length].hex()}')
        pos += length
    elif wire_type == 5:  # 32-bit
        print(f'  Fixed32: {data[pos:pos+4].hex()}')
        pos += 4
    elif wire_type == 1:  # 64-bit
        print(f'  Fixed64: {data[pos:pos+8].hex()}')
        pos += 8
"
```

4. Record every field number and its value — this gives you the ACTUAL tag numbers for `EvenAIDataPackage` and `EvenAIControl`

### Step 2.3 — Decode Wakeup Response

Look for the NEXT packet on 5401 (phone → glasses) with the SAME service ID. This is `sendWakeupResp`:

1. Decode the protobuf payload
2. Record all field numbers — this is the acknowledgment structure

### Step 2.4 — Capture Audio Stream

After the wakeup ack, audio frames start arriving. Look for:

1. Rapid succession of packets on 5402 (or check 7402!)
2. They may have a DIFFERENT service ID than Even AI — this would be the Audio service ID
3. Each packet contains an LC3 frame in the protobuf payload
4. Decode one frame's protobuf to find which field number holds the raw LC3 bytes
5. Note the frame size in bytes — this confirms LC3 parameters

**Important**: Check BOTH channels:
- Characteristic 5402 (main notify)
- Characteristic 7402 (third channel notify)

Audio data might be on the third channel to avoid blocking command responses.

### Step 2.5 — Decode AI Reply

After you speak and the AI responds, look for a packet on 5401 (phone → glasses) with the Even AI service ID. This is `EvenAIReplyInfo`:

1. Decode the protobuf
2. You should see a string field containing the AI's response text
3. Record the field number for the text field
4. Check if there's an `is_final` boolean and `sequence` number
5. If the response is long, there may be multiple packets — check for streaming

### Step 2.6 — Decode AI Exit

After the conversation ends, look for the exit packet on 5401:

1. Decode — this is `EVEN_AI_EXIT`
2. Record the command_id value that means EXIT

### Step 2.7 — Update Proto File

With all captures decoded, update `findings/proto/even_ai.proto` with confirmed tag numbers.

---

## Phase 3: Audio Protocol Details (30 min)

**Goal**: Confirm audio control commands and LC3 parameters.

### Step 3.1 — App-Initiated Audio

1. Start HCI snoop
2. Connect glasses
3. In Even app, start Conversate (which uses the microphone)
4. Speak for 10 seconds
5. Stop Conversate
6. Pull snoop log

### Step 3.2 — Identify Audio Control

Look for `AudioCtrCmd` — a packet sent right before audio data starts flowing:

1. It will be on 5401, with a service ID you haven't seen yet (or possibly the same as Even AI)
2. Decode the protobuf — record the `cmd` field value for "start" (likely `AUD_CMD_OPEN = 1`)
3. Look for `AudioResCmd` on 5402 — the glasses' acknowledgment
4. Find the "stop" command at the end of the session

### Step 3.3 — Confirm LC3 Parameters

From the audio data packets:

1. Measure the time between consecutive audio packets (should be ~10ms for 10ms frames)
2. Count the payload bytes per frame (standard LC3 at 16kHz/10ms produces ~40 bytes encoded)
3. If you have a working LC3 decoder, try decoding with dtUs=10000, srHz=16000
4. If that fails, try dtUs=7500 (7.5ms frames) or srHz=32000

### Step 3.4 — Determine Audio Channel

Check definitively whether audio data arrives on:
- 5402 (main notify) — same as commands
- 7402 (third channel) — dedicated audio channel

Look at the GATT handle values in Wireshark to distinguish.

---

## Phase 4: Conversate Protocol (30 min)

**Goal**: Confirm all Conversate field numbers for real-time text streaming.

### Step 4.1 — Capture Conversate Session

1. Start HCI snoop
2. Connect glasses
3. Open Conversate feature in Even app
4. Speak several sentences, wait for transcription to appear
5. Wait for key points to generate
6. Stop session
7. Pull snoop log

### Step 4.2 — Decode Control Messages

Filter to service ID 0x0B-0x14 on 5401:

1. First packet = `CONVERSATE_CONTROL` (start) — decode to get:
   - `command_id` field number and value for CONTROL
   - `control` sub-message field number
   - `cmd` field number and value for START
2. Last packet = `CONVERSATE_CONTROL` (stop) — decode to get:
   - `cmd` value for STOP

### Step 4.3 — Decode Transcribe Data

Filter to service ID 0x0B-0x14 on 5401 (mid-session):

1. Find packets with transcription text
2. Decode to get:
   - `command_id` value for TRANSCRIBE_DATA
   - `transcribe_data` sub-message field number
   - `text` field number (expected: 1)
   - `is_final` field number (expected: 2)
   - Whether `speaker` and `id` fields exist

### Step 4.4 — Decode Heartbeat

Look for periodic small packets during the session:
1. Decode to get heartbeat structure and interval timing

### Step 4.5 — Update Proto File

Update `findings/proto/conversate.proto` with confirmed values.

---

## Phase 5: Translate & Transcribe (30 min)

**Goal**: Confirm service IDs and wrapper message tag numbers.

### Step 5.1 — Capture Translate Session

1. Start HCI snoop
2. Open Translate feature, set language pair (e.g., English → French)
3. Speak several sentences
4. Stop
5. Pull log

### Step 5.2 — Capture Transcribe Session

1. Start HCI snoop
2. Open Transcribe feature
3. Speak several sentences
4. Stop
5. Pull log

### Step 5.3 — Decode Both

For each:
1. Identify service ID (new bytes in header)
2. Decode the DataPackage wrapper — get `command_id` field number
3. Decode the control start/stop messages
4. Decode the result messages — cross-reference with the CONFIRMED tag numbers from APK protos:
   - `TranscribeResult`: text=1, reason=2, is_final=3, session_id=4, id=5
   - `TranslateResult`: original=1, target=2, reason=3, is_final=4, session_id=5, id=6, offset=7, duration=8
5. Check if the DataPackage wrapper's field numbers for `result` match your inference

---

## Phase 6: Display & Images (1 hour)

**Goal**: Decode image transfer protocol for sending custom images.

### Step 6.1 — Capture Dashboard with Widgets

1. Start HCI snoop
2. Connect glasses, head-tilt to trigger dashboard
3. Wait for widgets to render
4. Pull log

### Step 6.2 — Capture Navigation

1. Start HCI snoop
2. Start navigation in the app (Google Maps → Even app bridge)
3. Follow at least 2 turns
4. Pull log

### Step 6.3 — Decode Display Pipeline

In the captures, look for traffic on 6401 and 6402 characteristics:

1. These are the display data channels
2. Check if they use the same `0xAA` transport header or a different format
3. If different, document the raw byte structure
4. Look for BMP file headers (`0x42 0x4D` = "BM") in the payload
5. If found, extract the full BMP to verify dimensions and bit depth

### Step 6.4 — Decode Page Lifecycle

Look for packets on 5401 that correspond to page management:

1. `APP_REQUEST_CREATE_STARTUP_PAGE_PACKET` — before image data
2. `APP_REQUEST_REBUILD_PAGE_PACKET` — during updates
3. `APP_REQUEST_SHUTDOWN_PAGE_PACKET` — when clearing

Decode each to get their protobuf structures.

### Step 6.5 — Decode File Service

For large images, look for the file service transfer sequence on 6401:

1. `EVEN_FILE_SERVICE_CMD_SEND_START` — initiation packet
2. `EVEN_FILE_SERVICE_CMD_SEND_DATA` — data chunks (many packets)
3. `EVEN_FILE_SERVICE_CMD_SEND_RESULT_CHECK` — verification

Decode each to get:
- Command field numbers
- Chunk sizes
- CRC field format
- Offset tracking

### Step 6.6 — Determine Image Compression

Compare the raw display data bytes with a standard 4-bit BMP:

1. If starts with `0x42 0x4D` (BM) — uncompressed BMP
2. If doesn't — there's a compression layer (`compressBmpData`)
3. Try common compression: zlib, LZ4, RLE
4. Check if the first few bytes match any known compression magic

### Step 6.7 — Confirm Display Dimensions

From the BMP header in captured data:
- Width (bytes 18-21 of BMP)
- Height (bytes 22-25 of BMP)
- Bits per pixel (bytes 28-29 of BMP)
- This confirms the exact display resolution

---

## Phase 7: Gestures & EvenHub (30 min)

**Goal**: Decode head tilt, touchpad gestures, and event routing.

### Step 7.1 — Capture Head Tilt Events

1. Start HCI snoop
2. Connect glasses
3. Tilt head up sharply (to trigger dashboard)
4. Tilt head down
5. Repeat 5 times with varying angles
6. Pull log

### Step 7.2 — Capture Touch Gestures

1. Start HCI snoop
2. Single tap right touchpad
3. Wait 3s
4. Double tap right touchpad
5. Wait 3s
6. Long press right touchpad
7. Wait 3s
8. Tap both touchpads simultaneously
9. Pull log

### Step 7.3 — Decode Events

Filter to 5402 (glasses → phone). For each gesture:

1. Identify the service ID — should be EvenHub (0x81-0x14)
2. Decode protobuf to get:
   - Event type field number and values for each gesture
   - Head-up angle value and format (degrees or raw)
   - Whether there's a separate event for each gesture type
3. Check if events also appear on 7402

### Step 7.4 — Decode Gesture Config

Look for gesture configuration sent from phone → glasses on 5401:

1. This is `APP_Send_Gesture_Control` / `APP_Send_Gesture_Control_List`
2. Decode to get:
   - Gesture type enum values
   - Action mapping field numbers
   - How the app maps gesture → function

---

## Phase 8: R1 Ring Binary Protocol (1-2 hours) — COMPLEX

**Goal**: Reverse engineer the ring's custom binary protocol.

### Step 8.1 — Capture Ring Connection

1. Start HCI snoop
2. Turn on ring (put on finger)
3. Open Even app, let it connect to ring
4. Wait for initial handshake to complete
5. Pull log

### Step 8.2 — Isolate Ring Traffic

Filter to the ring BLE service UUID `BAE80001`:
- Writes to `BAE80012` = phone → ring commands
- Notifications from `BAE80013` = ring → phone data

### Step 8.3 — Decode Pairing Handshake

Look at the first packets after connection:

1. Phone sends commands on BAE80012
2. Ring responds on BAE80013
3. Document the byte sequence — this is the pairing/init protocol
4. Note packet sizes and any patterns (fixed headers, length prefixes)

### Step 8.4 — Identify Command Structure

Analyze multiple command/response pairs:

1. Look for common header bytes across all commands
2. Identify: magic byte, command type byte, length, payload, checksum
3. Map the structure:
   ```
   [magic?] [cmd_type] [length?] [payload...] [checksum?]
   ```

### Step 8.5 — Capture Gesture Events

1. Start fresh HCI snoop
2. Ensure ring is connected
3. Single tap ring
4. Wait 5s
5. Double tap ring
6. Wait 5s
7. Swipe on ring surface (if supported)
8. Wait 5s
9. Pull log

### Step 8.6 — Differentiate Gestures vs Health

Compare notification packets from Step 8.5 (gestures) with idle notifications (health data):

1. During idle, ring sends periodic health points every few seconds
2. Gesture events should appear as extra packets when you tap
3. The command type byte should differ between health and gesture
4. Document the command type byte for each:
   - Health point data: cmd = 0x??
   - Single tap: cmd = 0x??
   - Double tap: cmd = 0x??
   - Swipe: cmd = 0x??

### Step 8.7 — Decode Health Points

From idle health data (BAE80013 notifications):

1. Collect 20+ consecutive health point packets
2. Compare byte-by-byte to find:
   - Which bytes change (real-time values: HR, steps)
   - Which bytes are constant (identifiers)
   - Which bytes increment (counters, timestamps)
3. Cross-reference with the app's display — if HR shows 72bpm, find `0x48` in the packet
4. Map each field position:
   ```
   Byte 0-1: Header/command
   Byte 2-3: Steps? (uint16 LE)
   Byte 4: Heart rate? (uint8)
   Byte 5: SpO2? (uint8)
   ...
   ```

### Step 8.8 — Capture Daily Data Sync

1. Start HCI snoop
2. Open Health tab in Even app (triggers `getDailyData`)
3. Wait for sync to complete
4. Pull log

This reveals the daily summary protocol — larger packets with sleep, HRV, etc.

### Step 8.9 — Ring → Glasses Bridge

After identifying ring gesture events:

1. Check if the phone forwards them to glasses
2. Look for a packet on G2's 5401 with the Ring service ID
3. This packet IS protobuf (the G2 bridge layer)
4. Decode to get `RingDataPackage` field numbers

---

## Phase 9: Settings & Minor Services (30 min)

**Goal**: Fill remaining gaps for less critical services.

### Step 9.1 — Capture Settings Changes

1. Start HCI snoop
2. In Even app, change display brightness
3. Change head-up angle
4. Change gesture mappings
5. Pull log

Decode packets to fill `G2SettingPackage` and `G2Settings` field numbers.

### Step 9.2 — Capture Quick List

1. Start HCI snoop
2. Create a quick list with 3 items
3. Send to glasses
4. Pull log

### Step 9.3 — Capture Glasses Case

1. Start HCI snoop
2. Put glasses in charging case
3. Take out
4. Pull log

### Step 9.4 — Capture Device Info

During connection, device info exchange happens automatically. Look for it in any Phase 1 capture.

---

## Phase 10: Validation & Proto Finalization (1 hour)

**Goal**: Verify everything works end-to-end.

### Step 10.1 — Build Validation Tool

Create a Python script using `bleak` that:

1. Connects to G2 glasses
2. Completes auth handshake (confirmed bytes from Phase 1)
3. Sends a Teleprompter message (fully confirmed proto)
4. Verifies text appears on glasses

```python
# validation_tool.py — skeleton
import asyncio
from bleak import BleakClient
import struct

G2_UUID_BASE = "00002760-08C2-11E1-9073-0E8AC72E"
CHAR_WRITE = G2_UUID_BASE + "5401"
CHAR_NOTIFY = G2_UUID_BASE + "5402"

def build_packet(service_hi, service_lo, payload, seq=0):
    header = bytes([0xAA, 0x21, seq, len(payload), 0x01, 0x01, service_hi, service_lo])
    crc = crc16_ccitt(payload)
    return header + payload + struct.pack('<H', crc)

def crc16_ccitt(data, init=0xFFFF):
    crc = init
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            if crc & 0x8000:
                crc = (crc << 1) ^ 0x1021
            else:
                crc <<= 1
            crc &= 0xFFFF
    return crc

async def main():
    # ... connect, auth, send teleprompter text
    pass

asyncio.run(main())
```

### Step 10.2 — Test Each Service

After confirming tag numbers, test each service one at a time:

1. **Teleprompter** — send paginated text (should work immediately)
2. **Conversate** — send streaming transcription text
3. **Even AI** — send wake-up ack, then AI reply text
4. **Audio** — send audio start command, verify LC3 frames arrive
5. **Notification** — send notification metadata
6. **Dashboard** — send widget data

### Step 10.3 — Finalize Proto Files

For each confirmed field, change `[INFERRED]` to `[CONFIRMED]` in the proto files.

---

## Quick Reference: Decode Cheatsheet

### Protobuf Wire Types
```
0 = Varint (int32, int64, uint32, uint64, bool, enum)
1 = 64-bit (fixed64, sfixed64, double)
2 = Length-delimited (string, bytes, embedded messages, repeated)
5 = 32-bit (fixed32, sfixed32, float)
```

### Reading a Field Tag
```
First byte(s) of each field: (field_number << 3) | wire_type

Examples:
  0x08 = field 1, varint      (1 << 3 | 0)
  0x10 = field 2, varint      (2 << 3 | 0)
  0x12 = field 2, length-del  (2 << 3 | 2)
  0x18 = field 3, varint      (3 << 3 | 0)
  0x1A = field 3, length-del  (3 << 3 | 2)
  0x20 = field 4, varint      (4 << 3 | 0)
  0x6A = field 13, length-del (13 << 3 | 2)
  0x82 0x01 = field 16, length-del (multi-byte field number)
```

### Transport Header Quick Parse
```
Byte 0: 0xAA (magic)
Byte 1: 0x21 (phone→glasses) or 0x12 (glasses→phone)
Byte 2: sequence number
Byte 3: payload length
Byte 4: total packets (usually 0x01)
Byte 5: packet serial (usually 0x01)
Byte 6: service ID high byte
Byte 7: service ID low byte
Bytes 8..N-2: protobuf payload
Bytes N-1..N: CRC-16 little-endian
```

### Quick Protobuf Decode (command line)

```bash
# Extract payload from a captured packet (hex string)
# Skip first 8 bytes (header), drop last 2 bytes (CRC)
PACKET="aa2100120101061408011002..."
PAYLOAD="${PACKET:16:-4}"

# Decode with protoscope
echo "$PAYLOAD" | xxd -r -p | protoscope

# Or with protoc (needs a .proto file)
echo "$PAYLOAD" | xxd -r -p | protoc --decode_raw
```

---

## Estimated Timeline

| Phase | Time | Priority | Fills |
|-------|------|----------|-------|
| 1. Service ID Discovery | 30 min | CRITICAL | 14 unknown service IDs |
| 2. Even AI Protocol | 1-2 hr | CRITICAL | AI wake/reply cycle, ~15 fields |
| 3. Audio Protocol | 30 min | HIGH | Audio control + LC3 confirmation |
| 4. Conversate Protocol | 30 min | HIGH | Streaming text display, ~10 fields |
| 5. Translate & Transcribe | 30 min | MEDIUM | Service IDs + wrapper fields |
| 6. Display & Images | 1 hr | MEDIUM | Image transfer + file service |
| 7. Gestures & EvenHub | 30 min | MEDIUM | Gesture events, ~8 fields |
| 8. R1 Ring Protocol | 1-2 hr | LOW | Entire binary protocol |
| 9. Minor Services | 30 min | LOW | Settings, case, quick list |
| 10. Validation | 1 hr | — | End-to-end confirmation |

**Total: ~7-9 hours for complete protocol documentation**

**Minimum viable (AI assistant only): Phases 1 + 2 + 3 + 4 = ~3 hours**
