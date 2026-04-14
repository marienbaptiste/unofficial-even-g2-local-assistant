# All G2 Services Reference

## Overview
Complete reference of all protobuf services available on the G2 glasses, with their protobuf definitions and packet creation functions.

---

## Transport Layer

All services use the same BLE transport:
- Write: `00002760-08C2-11E1-9073-0E8AC72E5401`
- Notify: `00002760-08C2-11E1-9073-0E8AC72E5402`
- Display: `...6401` / `...6402`

Packet format: `[0xAA] [type] [seq] [len] [pkt_total] [pkt_serial] [svc_hi] [svc_lo] [protobuf...] [crc16]`

Service ID definitions: `service_id_def.pbenum.dart`

---

## Confirmed Service Map (as of 2026-04-03)

Sub-service pattern: `0x00` = response (glasses -> phone), `0x01` = event/notification (glasses -> phone), `0x20` = command (phone -> glasses).

ATT handles: `0x0842/0x0844` (main channel), `0x0864` (mic audio stream), `0x0882/0x0884` (secondary/display channel).

### Confirmed Services

| Service ID | Name | Status | Notes |
|-----------|------|--------|-------|
| **0x01** | AI/Text Content + Gesture Events | CONFIRMED | 0x01-0x01 for gesture events (glasses -> phone), 0x01-0x20 for text/AI content |
| **0x03** | Transcribe | Inferred from code | Bidirectional, 17-46 packets per session |
| **0x04** | Display Wake | CONFIRMED | 1-4 packets per session, display on/off |
| **0x07** | Dashboard | CONFIRMED | Widget data, 0x07-0x01 during AI session |
| **0x09** | Device Info | CONFIRMED | Firmware 2.0.9.20, battery level in field12 |
| **0x0B** | Conversate | CONFIRMED | Full protobuf decoded. field1=type (1=init, 6=data, 0xFF=marker), field2=seq, field8=text (sub1=UTF-8, sub2=0 partial/1 final) |
| **0x0C** | Tasks/Quick List | From g2_transport.proto | 7-18 packets, bidirectional |
| **0x0D** | Device Config + Display State | CONFIRMED | 0x0D-0x01 events: field3.1=1 = display on, empty field3 = display off |
| **0x0E** | Display Config + R1 Health Insights | CONFIRMED | Display rendering params. Also carries R1 ring health insights (e.g. "Resting HR rose above baseline") in field2 |
| **0x10** | Unknown (possibly Translate) | Observed | 5-12 packets, bidirectional |
| **0x20** | Commit | From g2_transport.proto | 2-8 packets, low traffic |
| **0x80** | Auth/Sync/Heartbeat | CONFIRMED | Heartbeats + auth handshake. field3 contains ring name "EVEN R1_8EAB6C" |
| **0x81** | EvenHub | CONFIRMED | App hub sync |
| **0x91** | Unknown | Observed | 5-12 packets, bidirectional |
| **0xC4** | File Transfer (notify_whitelist.json) | CONFIRMED | On secondary channel (0x0882/0x0884). Sends notification whitelist config, NOT audio control |
| **0xE0** | EvenHub App Service | CONFIRMED | type=0 createPage, type=3 imageUpdate, type=5 textUpdate, type=9 audioControl, type=12 heartbeat |
| **0xC5** | AI/Display Session Control | CONFIRMED | On secondary channel. Spikes during AI, contains JSON-like data |
| Handle 0x0864 | Mic Audio Stream | CONFIRMED | LC3 32kbps, 5x40B frames per 205B packet, 10ms/16kHz/mono. NOT wrapped in G2 transport (no 0xAA header). Decoded 82s successfully with lc3codec |

### All Known Services (including unconfirmed from app code)

| Service | Create Function | Proto Files | Known Service ID |
|---------|----------------|-------------|-----------------|
| **Authentication** | `startPair`, `createTimeSyncCommand` | `dev_pair_manager.pb.dart` | `0x80-00` / `0x80-20` |
| **Even AI** | `_createEvenAiDataPackage` | `even_ai.pb.dart` | `0x01` |
| **Conversate** | `_createConverseDataPackage` | `conversate.pb.dart` | `0x0B-20` (CONFIRMED) |
| **Transcribe** | `_createTranscribeDataPackage` | `transcribe.pb.dart` | `0x03` (inferred) |
| **Translate** | (via translate ext) | `translate.pb.dart` | `0x10` (suspected) |
| **Teleprompter** | `_createTelepromptDataPackage` | `teleprompt.pb.dart` | `0x06-20` |
| **Dashboard** | `_createDashboardDataPackage` | `dashboard.pb.dart` | `0x07-20` |
| **Navigation** | `_createNavigationDataPackage` | `navigation.pb.dart` | TBD |
| **Notification** | `_createNotificationDataPackage` | `notification.pb.dart` | `0x02-20` |
| **Quick List / Tasks** | `_createQuickListDataPackage` | `quicklist.pb.dart` | `0x0C` |
| **Health** | `_createHealthDataPackage` | `health.pb.dart` | TBD |
| **Ring** | `_createRingDataPackage` | `ring.pb.dart` | TBD |
| **Menu** | `_createMenuDataPackage` | `menu.pb.dart` | TBD |
| **G2 Settings** | `_createG2SettingDataPackage` | `g2_setting.pb.dart` | TBD |
| **Device Config** | `_createDevCfgDataPackage` | `dev_config_protocol.pb.dart` | `0x0D-00` |
| **Device Info** | (via device settings) | `dev_infomation.pb.dart` | `0x09-00` |
| **Device Settings** | (via device settings) | `dev_settings.pb.dart` | TBD |
| **Sync Info** | `_createSyncInfoDataPackage` | `sync_info.pb.dart` | `0x80-00` |
| **Module Config** | `_createModuleConfigureDataPackage` | `module_configure.pb.dart` | TBD |
| **Display Config** | (via settings) | `g2_setting.pb.dart` | `0x0E-20` |
| **Display Wake** | (via EvenHub) | EvenHub | `0x04-20` |
| **EvenHub** | `_createEvenHubDataPackage` | `EvenHub.pb.dart` | `0x81-20` |
| **File Transfer** | (via file ext) | audio.proto | `0xC4-00` |
| **EvenHub App Service** | (via EvenHub ext) | EvenHub.pb.dart | `0xE0` |
| **AI/Display Session** | (via display ext) | — | `0xC5` |
| **OTA** | `_createFileTransmitDataPackage` | `ota_transmit.pbenum.dart` | TBD |
| **File Service** | (via file ext) | `efs_transmit.pbenum.dart` | TBD |
| **Logger** | `_createLoggerDataPackage` | `logger.pb.dart` | TBD |
| **Onboarding** | `_createOnboardingDataPackage` | `onboarding.pb.dart` | TBD |
| **Glasses Case** | `_createGlassesCaseDataPackage` | `glasses_case.pb.dart` | TBD |

---

## Service Details

### Authentication (0x80)
- `startPair` — initiate pairing handshake
- `createTimeSyncCommand` — sync time with glasses
- `sendHeartbeat` — keep connection alive
- `disconnect` — graceful disconnect
- `unpair` — remove pairing
- `quickRestart` — restart glasses
- `restoreFactory` — factory reset
- `selectPipeChannel` — select communication channel

### Even AI
- Commands: `EVEN_AI_ENTER`, `EVEN_AI_EXIT`, `EVEN_AI_WAKE_UP`
- Messages: `EvenAIControl`, `EvenAIReplyInfo`, `EvenAIAskInfo`, `EvenAIAnalyseInfo`, `EvenAIPromptInfo`, `EvenAISkillInfo`, `EvenAIVADInfo`, `EvenAIConfig`, `EvenAIHeartbeat`, `EvenAIEvent`, `EvenAISentiment`

### Conversate
- Commands: `CONVERSATE_CONTROL`, `CONVERSATE_TRANSCRIBE_DATA`, `CONVERSATE_KEYPOINT_DATA`, `CONVERSATE_TAG_DATA`, `CONVERSATE_TAG_TRACKING_DATA`, `CONVERSATE_TITLE_DATA`, `CONVERSATE_HEART_BEAT`, `CONVERSATE_STATUS_NOTIFY`, `CONVERSATE_COMM_RESP`
- Error codes: `CONVERSATE_ERR_FAIL`, `CONVERSATE_ERR_NETWORK`

### Transcribe
- Commands: `TRANSCRIBE_CTRL`, `TRANSCRIBE_RESULT`, `TRANSCRIBE_HEARTBEAT`, `TRANSCRIBE_NOTIFY`
- Messages: `TranscribeControl`, `TranscribeResult`, `TranscribeHeartBeat`, `TranscribeNotify`, `TranscribeDataPackage`

### Translate
- Commands: `TRANSLATE_CTRL`, `TRANSLATE_RESULT`, `TRANSLATE_HEARTBEAT`, `TRANSLATE_NOTIFY`, `TRANSLATE_MODE_SWITCH`
- Messages: `TranslateDataPackage`, `TranslateResult`, `TranslateNotify`, `TranslateHeartBeat`

### Teleprompter (0x06-20)
- Commands: `TELEPROMPT_CONTROL`, `TELEPROMPT_PAGE_DATA`, `TELEPROMPT_PAGE_DATA_REQUEST`, `TELEPROMPT_FILE_LIST`, `TELEPROMPT_FILE_LIST_REQUEST`, `TELEPROMPT_FILE_SELECT`, `TELEPROMPT_HEART_BEAT`, `TELEPROMPT_STATUS_NOTIFY`, `TELEPROMPT_PAGE_AI_SYNC`, `TELEPROMPT_PAGE_SCROLL_SYNC`, `TELEPROMPT_COMM_RESP`
- Error codes: `TELEPROMPT_ERR_CLOSED`, `TELEPROMPT_ERR_FAIL`, `TELEPROMPT_ERR_PD_DECODE_FAIL`, `TELEPROMPT_ERR_REPEATED_MESSAGE`

### Dashboard (0x07-20)
- Commands: `Dashboard_Receive`, `Dashboard_Respond`
- Responses: `DASHBOARD_RECEIVED_SUCCESS`, `DASHBOARD_PARAMETER_ERROR`

### Navigation
- Commands: `Navigation_Cmd_list`
- Functions: start, stop, arrive, basic info, mini map, overview map, recalculating, heartbeat, favorite list

### Notification (0x02-20)
- Commands: `NOTIFICATION_CTRL`, `NOTIFICATION_IOS`, `NOTIFICATION_JSON_WHITELIST`, `NOTIFICATION_WHITELIST_CTRL`
- Responses: `NOTIFICATION_COMM_RSP`

### OTA / File Service
- OTA: `OTA_TRANSMIT_FILE`, `OTA_TRANSMIT_INFORMATION`, `OTA_TRANSMIT_NOTIFY`, `OTA_TRANSMIT_RESULT_CHECK`, `OTA_TRANSMIT_START`
- File: `EVEN_FILE_SERVICE_CMD_SEND_START`, `_SEND_DATA`, `_SEND_RESULT_CHECK`, `_EXPORT_START`, `_EXPORT_DATA`, `_EXPORT_RESULT_CHECK`
- Responses: `_RSP_SUCCESS`, `_RSP_FAIL`, `_RSP_DATA_CRC_ERR`, `_RSP_FLASH_WRITE_ERR`, `_RSP_NO_RESOURCES`, `_RSP_TIMEOUT`, `_RSP_START_ERR`, `_RSP_RESULT_CHECK_FAIL`

---

## Packet Types (App ↔ Glasses)

### App → Glasses
- `APP_REQUEST_CREATE_STARTUP_PAGE_PACKET`
- `APP_REQUEST_REBUILD_PAGE_PACKET`
- `APP_REQUEST_SHUTDOWN_PAGE_PACKET`
- `APP_REQUEST_HEARTBEAT_PACKET`
- `APP_REQUEST_AUDIO_CTR_PACKET`
- `APP_UPDATE_IMAGE_RAW_DATA_PACKET`
- `APP_UPDATE_TEXT_DATA_PACKET`
- `APP_REQUEST_UPGRADE_HEARTBEAT_PACKET_SUCCESS`

### Glasses → App
- `OS_RESPONSE_CREATE_STARTUP_PAGE_PACKET`
- `OS_RESPONSE_REBUILD_PAGE_PACKET`
- `OS_RESPONSE_SHUTDOWN_PAGE_PACKET`
- `OS_RESPONSE_IMAGE_RAW_DATA_PACKET`
- `OS_RESPONSE_AUDIO_CTR_PACKET`

### Status
- `APP_REQUEST_REBUILD_PAGE_SUCCESS` / `_FAILD`
- `APP_REQUEST_AUDIO_CTR_SUCCESS` / `_FAILED`
- `APP_REQUEST_UPGRADE_IMAGE_RAW_DATA_SUCCESS` / `_FAILED`

---

## EventSourceType (EvenHub SDK)

Events from the glasses report their source via `EventSourceType`:

| Value | Source |
|-------|--------|
| 1 | RIGHT (right touchpad) |
| 2 | RING (R1 ring) |
| 3 | LEFT (left touchpad) |

This corrects earlier findings that the glasses could not distinguish left vs right touchpad — via EvenHub events, the source IS reported.

---

## Flutter Package Map

| Package | Contents |
|---------|----------|
| `even` | Main app (UI, services, API, pages) |
| `even_connect` | BLE connectivity (G1, G2, Ring1 protocols) |
| `even_core` | Core services |
| `flutter_ezw_audio` | Audio processing (AGC, noise reduction, speech enhance) |
| `flutter_ezw_lc3` | LC3 codec FFI bindings |
| `flutter_ezw_asr` | ASR/transcription (Azure, Soniox) |
| `teleprompt` | Teleprompter feature |
| `nordic_dfu` | Firmware updates |
| `taudio` | Audio playback (Flutter Sound) |
| `record_platform_interface` | Audio recording interface |
