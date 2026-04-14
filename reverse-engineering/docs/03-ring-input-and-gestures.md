# R1 Ring Input & Gestures

## Overview
The Even R1 smart ring connects via BLE and provides tap/gesture input and health monitoring. The ring communicates with the phone, which bridges events to the G2 glasses.

---

## BLE Addresses

| UUID | Type | Direction | Purpose |
|------|------|-----------|---------|
| `BAE80001-4F05-4503-8E65-3AF1F7329D1F` | Service | — | R1 ring primary service |
| `BAE80012-4F05-4503-8E65-3AF1F7329D1F` | Write | Phone → Ring | Send commands |
| `BAE80013-4F05-4503-8E65-3AF1F7329D1F` | Notify | Ring → Phone | Receive events & data |

---

## Ring Connection

### Discovery
- **Device name**: `EVEN R1_*`
- Scan for BLE devices advertising service `BAE80001-4F05-4503-8E65-3AF1F7329D1F`

### Connection Steps
1. Scan for `EVEN R1` devices
2. Connect to GATT server
3. Discover services
4. Enable notifications on `BAE80013` (write `0x0100` to CCCD)
5. Send initial pairing/handshake commands on `BAE80012`

### Ring ↔ Glasses Bridge
The ring connects to the phone app, which bridges data to the glasses:
- `start connect ring: deviceUuid = <uuid>`
- `RING_CONNECT_INFO` — sent to glasses via G2 protocol
- `RING_CONNECT_TIMEOUT` — connection timeout handling
- `BleG2CmdProtoRingExt|openRingBroadcast` — enable ring events on glasses
- `BleG2CmdProtoRingExt|switchRingHand` — configure left/right hand

---

## Ring Commands (BleRing1Cmd)

### Command System
- Protocol class: `BleRing1CmdProto`
- Service class: `BleRing1CmdService`
- Request/Response: `BleRing1CmdRequest` / `BleRing1CmdResponse`
- Multi-packet support: `BleRing1CmdPrivateExt|_handleMultiPacket`
- Queue management: `BleRing1CmdPublicExt|sendCmd`, `cleanCmdQueue`

### Command Processing
```
Phone sends command → BAE80012 (write)
Ring responds → BAE80013 (notify)
App processes: _processCmd → _handleCmdResponse
```

### System Commands
| Command | Function |
|---------|----------|
| `getSystemSettingsStatus` | Get ring system settings |
| `setSystemSettingsStatus` | Update ring system settings |
| `getAlgoKeyStatus` | Get algorithm key status |
| `setAlgoKey` | Set algorithm key |
| `unpair` | Unpair ring from phone |

### Health Commands
| Command | Function |
|---------|----------|
| `getDailyData` | Request daily health summary |
| `ackNotifyData` | Acknowledge received health data |
| `getHealthSettingsStatus` | Get health monitoring config |
| `setHealthSettingsStatus` | Update health monitoring config |
| `setHealthEnable` | Enable/disable health tracking |

---

## Ring Events & Notifications

### Real-Time Health Points
Ring sends periodic health data points:
- Notification channel: `BAE80013`
- Handler: `ring1Notify-point`
- Data class: `BleRing1HealthPoint`
- Includes: steps, heart rate, SpO2, etc.
- Error handling: `ring1Notify-point: parse BleRing1HealthPoint failed, cmd=`
- Unknown commands: `ring1Notify-point: unknown cmd=`

### Ring Input Events
Ring events (taps, clicks) flow through:
- `onListenOsRingEvent` — OS-level ring event listener
- Events bridged to glasses: `_createRingDataPackage`
- `RING_GLASSES` — ring event forwarded to glasses display

The ring likely supports:
- **Tap** — single tap on ring surface
- **Double tap** — quick double tap
- **Touch/swipe** — slide along ring surface (for scrolling)

(Exact gesture types need BLE snoop capture confirmation)

---

## Ring ↔ Glasses Event Flow

```
R1 Ring → BLE (BAE80013) → Phone App → G2 Protocol (5401) → Glasses

1. Ring detects gesture (tap/swipe)
2. Ring sends event via BAE80013 notify
3. Phone receives and processes BleRing1Cmd
4. Phone forwards to glasses via _createRingDataPackage
5. Glasses act on the event (scroll, select, etc.)
```

---

## Ring System Info

### Device Information
- `BleRing1SystemInfo` — ring hardware/firmware info
- `BleRing1SystemStatus` — current ring status
- `BleRing1SystemDeviceSn` — serial number
- `BleRing1SystemWearStatus` — is ring being worn
- `BleRing1ChargeInfo` / `BleRing1ChargeStatus` — battery and charging state

### File Transfer
The ring supports file transfers (firmware, health data export):
- `BleRing1FileModel` — file metadata
- `BleRing1FileExportCmd` — export data from ring
- `BleRing1FileCmdRequest` — file command request
- `BleRing1FileDataReceive` — receive file data

### Firmware Updates
- Uses Nordic DFU protocol (`NordicDfu`, `dev.steenbakker.nordic_dfu`)
- OTA pages: `DeviceRingBsDsdOtaPage`, `DeviceRingDfuErrorOtaPage`
- Multi-step upgrade with SD + App components

---

## Implementation on Mac

### Capture Ring Input
```
1. CBCentralManager → scan for "EVEN R1"
2. Connect, discover service BAE80001
3. Subscribe to BAE80013 notifications
4. Parse incoming BleRing1Cmd packets
5. Identify gesture events vs. health data by command type
6. Trigger custom actions based on gesture type
```

### Forward Ring Events to Glasses
```
1. Connect to both R1 ring and G2 glasses
2. On ring event: parse BleRing1Cmd
3. Wrap in G2 protocol: _createRingDataPackage
4. Send to glasses via 5401
```

---

## What Needs BLE Snoop Capture
- Ring command byte format (not protobuf — appears to be custom binary)
- Gesture event types and their byte values
- Ring pairing/handshake sequence
- Health point data format
- Which ring commands are tap/swipe vs. health data
