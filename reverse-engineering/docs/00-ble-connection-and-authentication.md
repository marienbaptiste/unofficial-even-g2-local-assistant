# BLE Connection & Authentication

## Overview
Before any communication with the G2 glasses or R1 ring, you must establish a BLE connection and complete the authentication handshake.

---

## G2 Glasses Connection

### Device Discovery
- **Device name format**: `Even G2_XX_L_YYYYYY` or `Even G2_XX_R_YYYYYY`
  - `XX` = model variant
  - `L`/`R` = left/right ear placement
  - `YYYYYY` = serial suffix
- Scan for BLE devices advertising the Even service UUID base

### BLE Service UUIDs

**Main Even Protocol Service** (base: `00002760-08C2-11E1-9073-0E8AC72E{xxxx}`):

| UUID Suffix | Full UUID | Type | Purpose |
|-------------|-----------|------|---------|
| `0001` | `00002760-08C2-11E1-9073-0E8AC72E0001` | Service | Primary service |
| `0002` | `00002760-08C2-11E1-9073-0E8AC72E0002` | Service | Secondary service |
| `5401` | `00002760-08C2-11E1-9073-0E8AC72E5401` | Write (no response) | **Command channel** (phone → glasses) |
| `5402` | `00002760-08C2-11E1-9073-0E8AC72E5402` | Notify | **Response channel** (glasses → phone) |
| `5450` | `00002760-08C2-11E1-9073-0E8AC72E5450` | Read | Service declaration |
| `6401` | `00002760-08C2-11E1-9073-0E8AC72E6401` | Write (no response) | Display data channel |
| `6402` | `00002760-08C2-11E1-9073-0E8AC72E6402` | Notify | **Mic audio stream** (LC3 frames, CONFIRMED) |
| `6450` | `00002760-08C2-11E1-9073-0E8AC72E6450` | Read | Display service declaration |
| `7401` | `00002760-08C2-11E1-9073-0E8AC72E7401` | Write (no response) | Third channel write |
| `7402` | `00002760-08C2-11E1-9073-0E8AC72E7402` | Notify | Third channel notify |
| `7450` | `00002760-08C2-11E1-9073-0E8AC72E7450` | Read | Third channel declaration |

**Nordic UART Service** (used for DFU/firmware updates):

| UUID | Purpose |
|------|---------|
| `6E400001-B5A3-F393-E0A9-E50E24DCCA9E` | NUS Service |
| `6E400002-B5A3-F393-E0A9-E50E24DCCA9E` | NUS TX (write) |
| `6E400003-B5A3-F393-E0A9-E50E24DCCA9E` | NUS RX (notify) |

### Connection Parameters
- Interval: 7.5–30ms
- Latency: 0
- Timeout: 2000ms
- MTU: 512 bytes (request max MTU after connection)

### Connection Steps
1. Scan for device by name prefix `Even G2`
2. Connect to GATT server
3. Request MTU 512
4. Discover services
5. Enable notifications on `5402` (write `0x0100` to CCCD descriptor)
6. Enable notifications on `6402` for mic audio (streams immediately on subscribe)
7. Enable notifications on `7402` if needed
8. Perform authentication handshake (see below)

---

## Authentication Handshake

The G2 uses a **custom 7-packet application-level handshake** (no BLE PIN pairing).

### Protocol
All packets use the Even BLE Transport format (see packet structure below).

**Service ID**: `0x80` (authentication/session management)

Key classes from the app:
- `BleG2CmdProtoDeviceSettingsExt|startPair` — initiates pairing
- `BleG2CmdProtoDeviceSettingsExt|createTimeSyncCommand` — time synchronization
- `TimeSync` — protobuf message with timestamp and transaction_id

### Handshake Flow (from community docs)
1. Phone sends auth request (service `0x80-20`)
2. Glasses respond with auth acknowledgment (service `0x80-01`)
3. Time sync exchange with timestamp and timezone offset
4. ~7 packets total to complete

### Time Sync Format (CONFIRMED 2026-04-03)

The time sync packets (auth packets 3 and 7) use protobuf `field128` (wire type = length-delimited, field tag `0x82 0x08`):

```
field128 = {
    field1 = unix_timestamp (varint-encoded)
    field2 = timezone_offset_in_quarter_hours (varint-encoded)
}
```

- `field1`: Current Unix timestamp (seconds since epoch), varint-encoded
- `field2`: **Timezone offset in quarter-hours from UTC** (e.g., UTC+2 = 8 quarter-hours)
- Python: `int(-time.altzone / 900)` gives the correct value

**Bug found:** The original auth code used `txid = 0xE8FFFFFFFFFFFFFF01` as field2, which is a garbage value (~max int64). The correct field2 is the timezone offset. After fixing this, the glasses display the correct time.

### Post-Authentication
- Send heartbeat: `BleG2CmdProtoDeviceSettingsExt|sendHeartbeat`
- Packet type: `APP_REQUEST_HEARTBEAT_PACKET`
- Keep-alive required to maintain connection

---

## Packet Structure (EvenBleTransport)

Every packet follows this format:

```
[0xAA] [type] [seq] [len] [pkt_total] [pkt_serial] [svc_hi] [svc_lo] [protobuf_payload...] [crc_lo] [crc_hi]
```

| Byte | Field | Description |
|------|-------|-------------|
| 0 | Magic | Always `0xAA` |
| 1 | Type | `0x21` = phone→glasses, `0x12` = glasses→phone |
| 2 | Sequence | Counter 0–255, increments per packet |
| 3 | Length | Length of payload + 2 (for service ID bytes) |
| 4 | Packet Total | Total packets in multi-packet message (usually `0x01`) |
| 5 | Packet Serial | Current packet number (1-indexed) |
| 6 | Service ID Hi | Service category byte |
| 7 | Service ID Lo | Sub-service byte (`0x00`=control, `0x01`=response, `0x20`=data) |
| 8..N-2 | Payload | Protobuf-encoded data |
| N-1, N | CRC | CRC-16/CCITT (little-endian) |

Confirmed by app string: `EvenBleTransport::fromBytes: headId is not 0xAA. Received: 0x`

### CRC-16/CCITT
- Init: `0xFFFF`
- Polynomial: `0x1021`
- Calculated over **payload bytes only** (skip 8-byte header)
- Output: little-endian (low byte first)

```python
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
```

### Multi-Packet Messages
When payload exceeds MTU (512 bytes):
- Sequence ID stays constant across fragments
- Byte 4 = total number of packets
- Byte 5 = current packet number (1 to N)

---

## R1 Ring Connection

### Device Discovery
- **Device name format**: `EVEN R1_*`

### BLE UUIDs

| UUID | Type | Purpose |
|------|------|---------|
| `BAE80001-4F05-4503-8E65-3AF1F7329D1F` | Service | R1 ring service |
| `BAE80012-4F05-4503-8E65-3AF1F7329D1F` | Write | Commands (phone → ring) |
| `BAE80013-4F05-4503-8E65-3AF1F7329D1F` | Notify | Responses (ring → phone) |

### Ring-Glasses Bridge
The ring connects to the phone, which bridges data to the glasses:
- `RING_CONNECT_INFO` — ring connection status sent to glasses
- `BleG2CmdProtoRingExt|openRingBroadcast` — enable ring broadcast on glasses
- `BleG2CmdProtoRingExt|switchRingHand` — set which hand wears the ring

---

## GATT Handle Mapping (from direct BLE enumeration, 2026-04-03)

Handle numbers differ between snoop captures and direct BLE connections.

```
Service 00002760-...1001: char 0001 (write), char 0002 (notify)
Service 00002760-...5450: char 5401 handle=0x0841 (write), char 5402 handle=0x0843 (notify)
Service 00002760-...6450: char 6401 handle=0x0861 (write), char 6402 handle=0x0863 (notify) -- MIC AUDIO
Service 00002760-...7450: char 7401 handle=0x0881 (write), char 7402 handle=0x0883 (notify)
Service 6e400001-...: NUS TX handle=0x08A1 (write), NUS RX handle=0x08A3 (notify) -- DFU
```

Note: snoop handle 0x0864 = direct handle 0x0863 = UUID 6402 (mic audio).

---

## What Still Needs Capture (BLE Snoop)
- Service ID hex values for each feature
- Timing requirements between packets
- Any encryption/obfuscation on payload data
