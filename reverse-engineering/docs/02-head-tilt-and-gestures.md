# Head Tilt & Gesture Capture (G2 Glasses)

## Overview
The G2 glasses have an IMU (accelerometer/gyroscope) and capacitive touchpads that generate events. These can be captured over BLE to detect head tilts, nods, and touch gestures.

---

## BLE Addresses

| UUID Suffix | Full UUID | Direction | Purpose |
|-------------|-----------|-----------|---------|
| `5401` | `00002760-08C2-11E1-9073-0E8AC72E5401` | Write | Configure gesture settings |
| `5402` | `00002760-08C2-11E1-9073-0E8AC72E5402` | Notify | Receive gesture/motion events |

---

## Head Tilt / Head-Up Angle

### What It Does
The glasses detect when you tilt your head up (look up) and use this as a trigger for the dashboard or other actions.

### Relevant App Data
- `headUpAngle` — the angle threshold for head-up detection
- `headUpTriggerDashboard` — head-up triggers dashboard display
- `DEVICE_WAKEUP_ANGLE` — configurable wake-up angle
- `wakeupAngle` — the angle value

### Configuration
Sent via the **G2 Settings** service:
- `BleG2CmdProtoExt|_createG2SettingDataPackage`
- Protobuf definition: `g2_setting.pb.dart`
- Settings include `headUpAngle` and `headUpTriggerDashboard`

### Events
Head tilt events likely arrive as part of the **EvenHub** event system:
- `BleG2CmdProtoExt|_createEvenHubDataPackage`
- Protobuf: `EvenHub.pb.dart` / `EvenHub.pbenum.dart`

---

## Touch Gestures (Touchpads)

### Hardware
The G2 has capacitive touchpads on both temple arms.

### Gesture Types
From the app's gesture control system:
- `APP_Send_Gesture_Control` — protobuf message for gesture config
- `APP_Send_Gesture_Control_List` — list of gesture mappings

Supported gestures (from UI strings):
- **Single tap** — touchpad tap
- **Double tap** — quick double tap
- **Long press** — hold touchpad ("Beide Touchpads lange drücken" = "Long press both touchpads")
- **Simultaneous tap** — tap both sides at once ("Appuyer simultanément" = "Press simultaneously")

### Gesture Configuration
Gestures are configurable — the app sends mappings of gesture → action:
- Service: G2 Settings (`_createG2SettingDataPackage`)
- Protobuf: `g2_setting.pb.dart`

---

## Silent Mode

The glasses have a silent mode triggered by gesture:
- `isInSilentMode` — current silent mode state
- `even_ai_silent_mode_on` — triggered by specific gesture
- Likely activated by long-pressing both touchpads

---

## Scroll Events

Used for scrolling through content (teleprompter, dashboard):
- `EVENT_SCROLL` — scroll event type
- `EVENT_NONE` — no event
- `EVENT_STREAM_COMPLETE` — end of event stream
- Head tilt controls scrolling in teleprompter (manual scroll mode)

---

## EvenHub Events

The **EvenHub** service is the central event bus for device-generated events:

### Protobuf
- `even_connect/g2/proto/generated/EvenHub/EvenHub.pb.dart`
- `even_connect/g2/proto/generated/EvenHub/EvenHub.pbenum.dart`

### Event Types
Events from glasses → phone include:
- Head-up angle triggers
- Touchpad gestures
- Wake word detection
- Silent mode toggle
- Scroll events
- Device status changes

---

## Protocol Flow

### Receiving Gesture/Motion Events

1. **Connect** and authenticate (see `00-ble-connection-and-authentication.md`)
2. **Subscribe** to notifications on `5402`
3. **Parse** incoming EvenBleTransport packets
4. **Filter** by service ID for EvenHub or G2 Settings responses
5. **Decode** protobuf payload to get event type and data

### Configuring Gesture Mappings

1. Build `APP_Send_Gesture_Control` protobuf message
2. Wrap in EvenBleTransport with G2 Settings service ID
3. Write to characteristic `5401`
4. Glasses acknowledge on `5402`

---

## Implementation Notes

### Head Tilt for Custom Actions
```
1. Subscribe to 5402 notifications
2. Filter for EvenHub service ID packets
3. Decode protobuf → check for head-up angle events
4. Trigger custom action when angle exceeds threshold
```

### Touchpad Gesture Capture
```
1. Subscribe to 5402 notifications
2. Filter for gesture event packets
3. Decode protobuf → get gesture type (single tap, double tap, long press, etc.)
4. Map to custom actions in your pipeline
```

---

## Confirmed BLE Protocol (CORRECTED from live Flutter app testing 2026-04-04)

**Previous capture-based gesture map was incorrect.** Live testing with the Flutter test app
revealed that the protobuf sub-fields encode **dashboard position and item index**, not gesture types.

Gesture events travel through **service 0x01-0x01** and **service 0x0C**.

### Packet Structure (0x01-0x01)

- `field1` = 3 (type: gesture)
- `field2` = 305419896 (constant, hex `0x12345678`)
- `field6` = gesture data with:
  - `field6.1` = sequence counter (incrementing)
  - `field6.5` = gesture/position event (see below)
  - `field6.3` = STATE event (head tilt position)

### Dashboard Scroll (Swipe) — Position Reports

Swipe gestures report the **target position** on the dashboard, NOT the gesture type.
The sub-fields encode the current position number:

| Hex signature | Meaning |
|--------------|---------|
| `2a06 0801 1202 10 01` | Scrolled to **position 1** |
| `2a08 0801 1204 08 01 10 02` | Scrolled to **position 2** (from 1) |
| `2a08 0801 1204 08 02 10 03` | Scrolled to **position 3** (from 2) |
| `2a08 0801 1204 08 03 10 04` | Scrolled to **position 4** (from 3) |

Pattern: `sub1` = previous position, `sub2` = new position. Direction = compare old vs new.

### Dashboard Tap — Item Selection

Tapping a dashboard item sends `field6.5` with `f1` = the **item index**:

| Hex signature | Meaning |
|--------------|---------|
| `2a04 0803 2200` | Tap **item 3** |
| `2a04 0804 2a00` | Tap **item 4** |
| `2a04 0805 3200` | Tap **item 5** |
| `2a04 0806 3a00` | Tap **item 6** |

Tap on **item 1** uses a different service: `0x0C` with payload `080c10017200`.

### Dashboard Item Enter/Exit (Service 0x0C)

| Hex pattern | Meaning |
|------------|---------|
| `080c 1001 7200` | Enter/open item 1 |
| `080c 1001 7202 0801` | Exit/close item |

### Head Tilt — STATE Events

| Hex pattern | Meaning |
|------------|---------|
| `1a XX 0a XX 08 {pos} 12 00` | Head tilt, dashboard at position `{pos}` |
| `1a04 0a00 1200` | State change (no position) |

### Key Observations (CORRECTED)

- **No left/right touchpad distinction** — both sides produce identical events
- **Teleprompter scroll sends NO BLE events** — the firmware handles scrolling internally. Only dashboard mode sends position events over BLE
- **Display on/off** tracked via `0x0D-0x01`: `field3.1=1` = on, empty = off
- **The gesture "type" is actually the item/position index**, not a tap/scroll/longpress enum as initially assumed
- Dashboard is cached in firmware — works without the Even app

---

## Head Tilt via Direct BLE (CONFIRMED 2026-04-04)

Head tilt generates BLE events when connected directly (no Even app needed):

- **STATE event on 0x01-0x01**: position value indicating dashboard widget
- **Display on/off cycle on 0x0D-0x01** during tilt
- **Dashboard is cached in glasses firmware**
- No explicit head-tilt configuration command needed; IMU-based detection is autonomous

---

## What Still Needs Capture
- Head-up angle raw value format (degrees? raw IMU data?)
- Full STATE event position value semantics for dashboard navigation
- Gesture configuration commands (phone -> glasses, likely 0x01-0x20 or G2 Settings)
- Per-eye display: glasses can send content to left eye, right eye, or both (--right flag in teleprompter)
