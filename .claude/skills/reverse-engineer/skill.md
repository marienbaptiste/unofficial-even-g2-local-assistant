---
name: reverse-engineer
description: Start a reverse engineering session for the Even G2 glasses BLE protocol. Takes a description of what feature/service to investigate, loads current progress, and guides through capture, analysis, protobuf decode, and documentation.
argument-hint: "[what to investigate — e.g. 'translate feature', 'notification flow', 'EvenHub image push']"
allowed-tools: "Bash Read Write Edit Grep Glob Agent"
---

# Even G2 BLE Reverse Engineering Session

You are guiding a reverse engineering session for the Even G2 smart glasses BLE protocol.

## Goal

The user wants to investigate: **$ARGUMENTS**

## Step 1: Launch the Capture Server IMMEDIATELY

**This is always the first action — no reading old files, no analysis, no planning first.**

Start the capture server in the background so the user can begin capturing right away:

```bash
cd reverse-engineering/tools
python capture_server.py
```

If port 8642 is already in use, the server is already running — just tell the user it's ready.

Tell the user the UI is at **http://localhost:8642** and remind them to click "Done - Tell Claude" when the capture is complete.

## Step 2: Wait for the User's Signal (Ralph Wiggum Loop)

Do NOT read old captures, progress.json, docs, or proto files while waiting. The user will signal when the capture is done via the web UI.

**CRITICAL: To activate the polling loop, you MUST output a short message like "Waiting..." after telling the user the UI is ready.** This triggers the Stop hook (`check-signal.sh`) which polls `signal.json` every ~5 seconds. If the signal is not "done" yet, the hook returns `ok: false` which forces you to respond again — keeping the loop alive. When the signal says "done", the hook injects analysis instructions into your context.

Do NOT use ScheduleWakeup or `/loop` — the Stop hook handles the polling. Just say one short word each turn to keep the loop spinning.

## Step 3: Load Context and Analyze (AFTER capture is done)

Only after the user signals "done" or explicitly asks for analysis:

1. **First, read `reverse-engineering/progress.json`** to load all existing knowledge — discovered services, known protobuf patterns, previous capture notes. This is essential context for interpreting new packets.
2. Read the capture results JSON from `reverse-engineering/tools/results/` matching the capture_id from the signal (or the latest result file).
3. Cross-reference with relevant docs in `reverse-engineering/docs/` and proto files in `reverse-engineering/proto/` as needed.

### Web UI workflow (at http://localhost:8642)
1. **Check connection**: The status bar shows ADB connection, phone model, BT status, and snoop mode
2. **Describe the capture**: Type a description in the text area (e.g. "multiline AI cards in Conversate")
3. **Click "Start Capture"**: This automatically enables HCI snoop logging and restarts Bluetooth
4. **Perform the action**: Wait for glasses to reconnect, then do the target action on the Even app
5. **Click "Stop & Analyze"**: Pulls the btsnoop log (tries direct pull, falls back to bugreport), runs the analyzer, and displays results

### Web UI features
- **Services tab**: Shows all discovered service IDs with packet counts and directions
- **Packets tab**: Browse decoded packets with protobuf field trees, filterable by service and direction
- **Handles tab**: ATT handle map
- **Delta tab**: Compare with previous capture to see new/changed services
- **Capture History**: View and reload any past capture
- **Retry Analysis**: Button appears automatically when Stop & Analyze fails — retries without restarting the capture
- **Notes & Signal to Claude**: Card below the capture card with:
  - **Notes textarea**: User writes observations about what they saw on the glasses
  - **"Done - Tell Claude"**: Writes a signal file so Claude knows the capture is ready for analysis
  - **"Retrying Capture"**: Signals Claude that the user is re-doing the capture
  - **"Save Notes Only"**: Attaches notes to the capture result without signaling

Results are saved as JSON in `reverse-engineering/tools/results/` and capture logs in `reverse-engineering/tools/captures/`.

### Signal file (Claude ↔ User communication)

The web UI writes `reverse-engineering/tools/signal.json` when the user clicks Done or Retry.
Claude should read this file to check the user's status:

```python
# signal.json format:
{
  "status": "done" | "retry",   # user's current state
  "capture_id": "...",          # which capture to analyze
  "notes": "...",               # user's observations
  "timestamp": "..."
}
```

After reading the signal, Claude should proceed accordingly:
- `"done"` → read the capture results and user notes, begin analysis
- `"retry"` → wait for the user to signal done again

### Alternative: Direct analyzer (for existing capture files)

If you already have a btsnoop log file and want to analyze it without the web UI:

```bash
cd reverse-engineering/tools
python -c "
import json
from analyzer import analyze_capture, diff_captures

result = analyze_capture('../captures/EXISTING_FILE.log')
print(json.dumps(result, indent=2, default=str))
"
```

## Step 4: Decode and Analyze

Key things to extract from the capture results:
- **New service IDs** not seen in baseline (marked "NEW" in the Delta tab)
- **Packet counts per service** — spikes indicate the active feature
- **Protobuf field values** — shown as expandable field trees in the Packets tab
- **Multi-packet messages** — reassembled packets are marked with fragment count

For protobuf decoding, cross-reference with existing `.proto` files in `reverse-engineering/proto/` and look for:
- **String fields**: Usually text content, names, JSON
- **Varint fields**: Sequence numbers, types, flags, enums
- **Nested messages**: Sub-structures with their own field trees
- **Float/double fields**: Settings values, coordinates

## Step 5: Document Findings

Update these files with discoveries:

### progress.json
- Add new entries to `discovered_services` if new services found
- Add the capture to `captures` array with label, file, packet count, notes
- Add key findings to `notes` array
- Mark completed steps in `completed_steps`
- Update `remaining_captures` status for the investigated feature

### Proto files
- If a new service is decoded, create or update the `.proto` file in `reverse-engineering/proto/`
- Use field numbers from the raw decoder output
- Mark confidence: `// CONFIRMED via capture` or `// INFERRED from code`

### Docs
- Update or create a doc in `reverse-engineering/docs/` if the feature warrants it
- Follow the existing naming convention: `NN-feature-name.md`

## Important Context

### BLE Channel Map
- **5401/5402** (handles 0x0842/0x0844): Main command/response — all G2 transport services
- **6401/6402** (handles 0x0882/0x0884): Display data write/notify
- **7402** (handle 0x0864): Mic audio — raw LC3 frames, NO G2 transport wrapper

### Transport Header Format
```
[0xAA] [type] [seq] [len] [pkt_total] [pkt_serial] [svc_hi] [svc_lo] [payload...] [crc16_le]
```
- type: 0x21 = phone->glasses, 0x12 = glasses->phone
- Sub-service: 0x00 = response, 0x01 = event, 0x20 = command

### Audio Format
- LC3 codec: 16kHz, 32kbps, mono, 10ms frames
- 5 x 40-byte LC3 frames per 205-byte BLE packet + 5-byte trailer
- Streams on UUID 6402 notification subscribe — no explicit start command

### Known Protobuf Patterns
- Conversate: field1=type(1=init, 6=data, 0xFF=marker), field8.1=text, field8.2=is_final
- AI cards: field7.1=icon, field7.2=title, field7.3=body, field7.4=done
- Settings: multiple services (0x09, 0x0D, 0x0E) with nested field structures
- EvenHub (0xE0): type=0 createPage, type=3 imageUpdate, type=5 textUpdate, type=9 audioControl

## Tone

Be methodical and precise. Use hex values for service IDs and field numbers. When uncertain, say so and suggest what capture would confirm. Always update progress.json with findings so nothing is lost between sessions.
