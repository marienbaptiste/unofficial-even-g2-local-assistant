# Navigation Display (G2 Glasses)

## Overview
The G2 can display turn-by-turn navigation directions, mini-maps, and route overview maps. The app uses Mapbox for routing and sends navigation data to the glasses via BLE.

---

## BLE Addresses

| UUID Suffix | Full UUID | Direction | Purpose |
|-------------|-----------|-----------|---------|
| `5401` | `00002760-08C2-11E1-9073-0E8AC72E5401` | Write | Navigation commands |
| `5402` | `00002760-08C2-11E1-9073-0E8AC72E5402` | Notify | Acknowledgments |
| `6401`/`6402` | `...6401` / `...6402` | Write | Map/arrow image data |

---

## Navigation Commands

### Service Functions (NavigateBleServiceCommand)

| Function | Purpose |
|----------|---------|
| `_sendNavigationStart` | Start navigation session |
| `_sendNavigationStop` | Stop navigation |
| `_sendNavigationArrive` | Signal arrival at destination |
| `_sendNavigationBasicInfo` | Send route basic info |
| `_sendNavigationMiniMap` | Send mini-map image |
| `_sendNavigationOverviewMap` | Send route overview map |
| `_sendNavigationRecalculating` | Route recalculation |
| `_sendNavigationHeartbeat` | Keep-alive during navigation |
| `_sendNavigationFavoriteList` | Send favorite locations |
| `_sendNavigationDeviceStartError` | Error starting navigation on device |

### Progress Tracking
- `EvenNavigateServiceProgress|_sendNavigationDataSequentially` — sequential data sending
- `EvenNavigateServiceProgress|_sendNavigationProgressIfNeeded` — progress updates

### Protobuf
- `navigation_main_msg_ctx` — main navigation message context
- `navigation_main_msg_ctx.fromBuffer` — deserialize navigation data
- Protobuf files:
  - `even_connect/g2/proto/generated/navigation/navigation.pb.dart`
  - `even_connect/g2/proto/generated/navigation/navigation.pbenum.dart`
- Command list: `Navigation_Cmd_list`

---

## Protocol Flow

### Start Navigation
```
1. Send _sendNavigationStart with route info → 5401
2. Send _sendNavigationBasicInfo (distance, ETA, etc.) → 5401
3. Send _sendNavigationOverviewMap (route overview image) → 6401/6402
4. Begin turn-by-turn updates
```

### Turn-by-Turn Updates
```
1. For each maneuver:
   a. Send navigation arrow/direction image → 6401/6402
   b. Send distance/instruction text → 5401
   c. Send _sendNavigationMiniMap (current area) → 6401/6402
2. Send _sendNavigationHeartbeat periodically
```

### End Navigation
```
1. On arrival: _sendNavigationArrive → 5401
2. On cancel: _sendNavigationStop → 5401
```

---

## Map/Arrow Images

Navigation arrows and maps are sent as images (same 4-bit grayscale BMP format as regular images — see `04-send-images-to-display.md`).

The app includes Mapbox SDKs:
- `libmapbox-common.so` (6.3MB)
- `libmapbox-maps.so` (12.2MB)
- `libnavigator-android.so` (27.6MB)

Map tiles are rendered locally and converted to BMP for the glasses display.

---

## Implementation on Mac

### Custom Navigation Display
```
1. Connect + authenticate with G2
2. Compute route using any mapping API
3. Render turn arrows as 4-bit grayscale BMP (267px wide)
4. Send _sendNavigationStart
5. For each turn:
   a. Send direction image via display channel
   b. Send distance/instruction via navigation command
6. Send _sendNavigationArrive or _sendNavigationStop
```

---

## What Needs BLE Snoop Capture
- Navigation service ID bytes
- Navigation protobuf field structure
- Arrow image format and dimensions
- Mini-map vs. overview map packet differentiation
- Turn instruction text format
