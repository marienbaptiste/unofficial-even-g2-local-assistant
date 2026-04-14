# Even Hub SDK Analysis (Official @evenrealities/even_hub_sdk)

Released: April 3, 2026

## Architecture

The SDK is a **WebView bridge** — apps are web pages running inside the Even app.
Communication: Web JS -> EvenAppBridge -> Flutter Even App -> BLE -> Glasses

Our SDK bypasses this: Python/Dart -> BLE directly -> Glasses

## Display Container Model

### Container Types (max 12 per page)

1. **TextContainerProperty** (max 8 per page)
   - xPosition, yPosition, width, height
   - borderWidth, borderColor, borderRadius, paddingLength
   - containerID, containerName
   - content (string)
   - isEventCapture (0/1 - enables click events)

2. **ImageContainerProperty** (max 4 per page)
   - xPosition, yPosition
   - width (20-288px), height (20-144px)
   - containerID, containerName

3. **ListContainerProperty**
   - Same positioning as text
   - itemContainer: ListItemContainerProperty
     - itemCount, itemWidth
     - isItemSelectBorderEn (selection highlight)
     - itemName (string array)

### Page Lifecycle Commands

1. `createStartUpPageContainer` -> creates page, returns success/invalid/oversize/outOfMemory
2. `rebuildPageContainer` -> updates layout with new containers
3. `textContainerUpgrade` -> update text content (containerID, content, contentOffset, contentLength)
4. `updateImageRawData` -> push image (containerID, imageData as bytes)
5. `shutDownPageContainer` -> close (exitMode: 0=immediate, 1=ask user)

### Audio Control
- `audioControl(true)` -> enable mic
- `audioControl(false)` -> disable mic
- Audio arrives as PCM in audioEvent

### IMU Control
- `imuControl(true, reportFrequency)` -> enable IMU data streaming
- Frequency: 100-1000ms intervals (ImuReportPace enum)
- Data: x, y, z (doubles)
- Arrives as IMU_DATA_REPORT event with IMU_Report_Data

## Events (Glasses -> App)

### OsEventTypeList
| Value | Name | Description |
|-------|------|-------------|
| 0 | CLICK_EVENT | Container tapped |
| 1 | SCROLL_TOP_EVENT | Scrolled to top |
| 2 | SCROLL_BOTTOM_EVENT | Scrolled to bottom |
| 3 | DOUBLE_CLICK_EVENT | Double tap |
| 4 | FOREGROUND_ENTER_EVENT | App entered foreground |
| 5 | FOREGROUND_EXIT_EVENT | App left foreground |
| 6 | ABNORMAL_EXIT_EVENT | Crash/error |
| 7 | SYSTEM_EXIT_EVENT | System closed app |
| 8 | IMU_DATA_REPORT | IMU data (x,y,z) |

### EventSourceType
| Value | Name | Description |
|-------|------|-------------|
| 0 | TOUCH_EVENT_FORM_DUMMY_NULL | No source |
| 1 | TOUCH_EVENT_FROM_GLASSES_R | Right touchpad |
| 2 | TOUCH_EVENT_FROM_RING | R1 ring |
| 3 | TOUCH_EVENT_FROM_GLASSES_L | Left touchpad |

### Event Payloads
- **List_ItemEvent**: containerID, containerName, currentSelectItemName, currentSelectItemIndex, eventType
- **Text_ItemEvent**: containerID, containerName, eventType
- **Sys_ItemEvent**: eventType, eventSource, imuData (x,y,z), systemExitReasonCode
- **AudioEventPayload**: audioPcm (Uint8Array of PCM bytes)

## Error Codes (EvenHubErrorCodeName)
- APP_REQUEST_CREATE_PAGE_SUCCESS
- APP_REQUEST_CREATE_INVAILD_CONTAINER
- APP_REQUEST_CREATE_OVERSIZE_RESPONSE_CONTAINER
- APP_REQUEST_CREATE_OUTOFMEMORY_CONTAINER
- APP_REQUEST_UPGRADE_IMAGE_RAW_DATA_SUCCESS/FAILED
- APP_REQUEST_REBUILD_PAGE_SUCCESS/FAILED
- APP_REQUEST_UPGRADE_TEXT_DATA_SUCCESS/FAILED
- APP_REQUEST_UPGRADE_SHUTDOWN_SUCCESS/FAILED
- APP_REQUEST_UPGRADE_HEARTBEAT_PACKET_SUCCESS
- APP_REQUEST_AUDIO_CTR_SUCCESS/FAILED

## Device Info Available
- DeviceModel: G1, G2, Ring1
- DeviceStatus: sn, connectType, isWearing, batteryLevel, isCharging, isInCase
- UserInfo: uid, name, avatar, country

## Key Findings for Our Protocol

1. **Left/Right touchpad IS distinguished** via EventSourceType (1=right, 3=left)
2. **IMU data IS available** — x/y/z doubles at configurable frequency
3. **Container-based rendering** maps to service 0x81 (EvenHub) protobuf
4. **Image size**: 20-288px wide, 20-144px tall
5. **Max containers**: 12 per page (8 text + 4 image)
6. **Partial text update** with offset/length
7. **Audio returns as PCM** not LC3 (the Even app decodes LC3 before passing to WebView)
