# R1 Ring Health Data

## Overview
The Even R1 ring continuously monitors health metrics and syncs data to the phone app. Data includes steps, heart rate, HRV, SpO2, sleep, skin temperature, and calories.

---

## BLE Addresses

| UUID | Type | Direction | Purpose |
|------|------|-----------|---------|
| `BAE80001-4F05-4503-8E65-3AF1F7329D1F` | Service | — | R1 ring service |
| `BAE80012-4F05-4503-8E65-3AF1F7329D1F` | Write | Phone → Ring | Request health data |
| `BAE80013-4F05-4503-8E65-3AF1F7329D1F` | Notify | Ring → Phone | Receive health data |

---

## Health Metrics

### Available Data Types

| Metric | Data Class | Module |
|--------|-----------|--------|
| **Steps** | `BleRing1HealthActivity` | Activity |
| **Calories** | `BleRing1HealthActivity` | Activity |
| **Heart Rate** | `BleRing1HealthPoint` | Heart Rate |
| **Resting HR** | `BleRing1HealthDaily` | Heart Rate |
| **HRV** (Heart Rate Variability) | `BleRing1HealthPoint` / `BleRing1HealthDaily` | HRV |
| **SpO2** (Blood Oxygen) | `BleRing1HealthPoint` | Blood Oxygen |
| **Sleep Score** | `BleRing1HealthSleep` | Sleep |
| **Sleep Segments** | `BleRing1HealthSleep` | Sleep |
| **Skin Temperature** | `BleRing1HealthSleep` | Sleep |
| **Stress** (derived) | computed from HRV | — |

### Health Module Types
- `BleRing1Module` / `HealthModuleType` — enum of module types
- `BleRing1CmdExt|toHealthModuleType` — convert command to module type

---

## Data Types

### Real-Time Points (`ring1Notify-point`)
Ring pushes periodic health snapshots:
- Handler: `ring1Notify-point`
- Data class: `BleRing1HealthPoint`
- Cached data: `ring1Notify-point: cached all-day steps=<N>`
- Module tracking: `ring1Notify-point: cached module=<module>`
- Arrives on `BAE80013` as notifications

### Daily Summaries (`_handleRing1HealthDailyData`)
Aggregated daily data:
- `_handleRing1HealthDailyData: cmd=<cmd>`
- Sub-types:
  - **Activity**: `_handleRing1HealthDailyData-activity: steps=<N>`
  - **Sleep**: `_handleRing1HealthDailyData-sleep: receive one segment, dailyParam=<param>`
  - **Common**: `_handleRing1HealthDailyData-common: cmd=<cmd>, rawLen items=<N>`

### Health Items
- `BleRing1HealthItem` — generic health data item
- `BleRing1HealthDaily` — daily summary container

---

## Protocol Flow

### Requesting Health Data

```
1. Connect to ring (BAE80001 service)
2. Enable notifications on BAE80013
3. Send getDailyData command on BAE80012
   - BleRing1CmdHealthExt|getDailyData
4. Receive daily data on BAE80013
   - Multiple packets for different modules
5. Acknowledge: BleRing1CmdHealthExt|ackNotifyData
```

### History Sync
```
1. fetchAllHistoryDataFromRing
   - Throttled: "fetchAllHistoryDataFromRing: throttle, need wait <N>"
   - Last sync time: "fetchAllHistoryDataFromRing: lastHistoryDataTime = <time>"
2. Ring sends historical data in batches
3. App stores in local database
```

### Auto-Sync
The app runs periodic background syncs:
- `auto-sync(background): timer fired, isRingConnected=<bool>`
- `auto-sync(foreground): timer fired, isRingConnected=<bool>`

---

## Health Settings

### Configuration
- `getHealthSettingsStatus` — get current health monitoring config
- `setHealthSettingsStatus` — update config
- `setHealthEnable` — enable/disable health tracking
- Settings per module (HR, SpO2, sleep, etc.)

### Health Tracking
- `health_tracking` — master toggle
- `health_tracking_disabled_info/title` — disabled state UI

---

## Sleep Data

### Sleep Tracking
- `BleRing1HealthSleep` — sleep data model
- Sleep segments with start/end times
- `sleepScore` — overall sleep quality score
- `skinTemperature` — skin temp during sleep
- `latest-sleep/skinTemp: skinTemperature <value>`
- `latest-sleep/skinTemp: sleepScore <value>`

### Sleep Upload
- `sleep-upload: start upload, segmentCount=<N>`
- `sleep-upload: success -> cleared pending, source=<source>`
- `sleep-upload: upload failed (keep pending), source=<source>`
- `sleep-upload(disk): add one segment, serialId=<id>`

---

## SpO2 Data

- `spo2=<value>` — SpO2 reading
- `BLOOD_OXYGEN` — module identifier
- Alert threshold: `(n-1.maxSpO2 - n-1.minSpO2) > 5%`

---

## Ring Status

### Wear Detection
- `BleRing1SystemWearStatus` — is ring being worn

### Battery/Charging
- `BleRing1ChargeInfo` — charge level
- `BleRing1ChargeStatus` — charging state
- `ring_is_currently_charging`
- `ring_not_charging`

### System
- `BleRing1SystemInfo` — firmware, hardware info
- `BleRing1SystemStatus` — overall status
- `ring_firmware_version` — current firmware

---

## Data Storage Keys
- `health_point` / `health_point_index` — real-time points
- `health_raw` / `health_raw_index` — raw health data
- `health_raw_samples_` — raw sample storage
- `health_pending_upload` — data waiting to sync to cloud
- `health_sync_log` — sync history
- `health_last_history_data_time` — last sync timestamp

---

## Implementation on Mac

### Stream Real-Time Health Data
```
1. CBCentralManager → scan for "EVEN R1"
2. Connect, discover BAE80001 service
3. Subscribe to BAE80013 notifications
4. Parse incoming BleRing1Cmd packets
5. Filter for health point data (ring1Notify-point commands)
6. Extract: steps, HR, HRV, SpO2 values
```

### Request Daily Summary
```
1. Connect to ring
2. Send getDailyData command on BAE80012
3. Receive and parse daily data packets on BAE80013
4. Send ackNotifyData to acknowledge
```

### Request History
```
1. Send fetchAllHistoryData command
2. Receive batch data packets
3. Acknowledge each batch
4. Store locally
```

---

## What Needs BLE Snoop Capture
- Ring command byte format for getDailyData, ackNotifyData
- Health point data packet structure (which bytes = HR, steps, SpO2, etc.)
- Sleep segment data format
- Ring notification vs. command response differentiation
- Throttle timing for history sync requests
