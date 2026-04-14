# Even G2 SDK

Flutter SDK for the Even G2 smart glasses BLE protocol. Reverse-engineered from BLE captures. Provides a clean API for display, microphone, AI assistant, gestures, EvenHub containers, and settings.

## Installation

```yaml
dependencies:
  even_g2_sdk:
    path: ../sdk
```

## Quick Start

```dart
import 'package:even_g2_sdk/even_g2_sdk.dart';

final g2 = EvenG2();

// Connect to nearest glasses (both L + R ears)
await g2.connectToNearest();

// Display text
await g2.display.show("Hello!");

// Listen for "Hey Even" wake word
g2.dashboard.onWake.listen((_) async {
  await g2.dashboard.ackWake();
  await g2.dashboard.sendTranscription("Processing...");
  await g2.dashboard.showThinking();
  await g2.dashboard.streamResponse("The answer is 42.");
  await g2.dashboard.streamResponseDone();
  await g2.dashboard.endSession();
});

// Clean up
await g2.disconnect();
g2.dispose();
```

## Features

### Connection

Connects to both left and right earpieces automatically. Left ear handles display, right ear delivers AI wake events.

```dart
// Auto-connect (finds both L + R ears)
await g2.connectToNearest();

// Or connect a specific device from scan results
final devices = await EvenG2.scan();
await g2.connect(devices.first);

// Connection state
g2.isConnected;           // true/false
g2.onConnectionChange;    // Stream<bool>
g2.autoReconnect = true;  // auto-reconnect on disconnect (default: true)
```

### Display - Text

Three display modes via the Conversate service (0x0B).

```dart
// One-shot message
await g2.display.show("Hello!");

// Streaming (partial updates as text arrives)
await g2.display.showPartial("Think");
await g2.display.showPartial("Thinking...");
await g2.display.showFinal("The answer is 42.");

// Teleprompter (long scrollable text, auto word-wrapped)
await g2.display.teleprompter("Your long text here...");

// Clear display
await g2.display.clear();
```

### Display - AI Cards

Rich card format with icons, used by the Even AI interface.

```dart
await g2.display.showAiResponse(
  icon: Display.iconAi,
  title: 'Weather',
  body: 'Sunny, 22C in Geneva',
  isDone: false,
);
await g2.display.showAiResponse(
  icon: Display.iconPerson,
  title: 'Reminder',
  body: 'Meeting at 3pm',
  isDone: true,  // marks end of card sequence
);
```

Icon constants: `Display.iconLink` (1), `Display.iconAi` (2), `Display.iconPerson` (3), `Display.iconLocation` (4), `Display.iconQuestion` (5).

### Dashboard - AI Assistant (Hey Even)

Full AI session flow via the Dashboard service (0x07). This is how the "Hey Even" voice assistant works.

```dart
// Listen for wake word ("Hey Even" detected by glasses)
g2.dashboard.onWake.listen((event) async {
  // 1. Acknowledge wake - tells glasses we're handling it
  await g2.dashboard.ackWake();

  // 2. Start mic and capture audio
  await g2.mic.start(raw: true);

  // 3. Send live transcription as user speaks
  await g2.dashboard.sendTranscription("what is the weather");

  // 4. Signal speech ended
  await g2.mic.stop();
  await g2.dashboard.transcriptionDone();

  // 5. Show thinking indicator
  await g2.dashboard.showThinking();

  // 6. Stream AI response (glasses display it progressively)
  await g2.dashboard.streamResponse("It's 22C and sunny in Geneva.");
  await g2.dashboard.streamResponseDone();

  // 7. Keep response visible, then end
  await g2.dashboard.heartbeat();
  await g2.dashboard.endSession();
});

// Listen for all dashboard events (including audio TTS progress)
g2.dashboard.onEvent.listen((event) {
  if (event.isBoundary) print('Session ended by glasses');
  if (event.isAudioStarted) print('TTS playback started');
});
```

### Microphone

LC3-encoded audio from the glasses mic (UUID 6402). 16kHz, 32kbps, mono, 10ms frames.

```dart
// Start mic
await g2.mic.start();

// Raw LC3 packets (205 bytes: 5x40B frames + 5B trailer)
g2.mic.packetStream.listen((packet) { ... });

// Audio level (0.0 - 1.0)
g2.mic.levelStream.listen((level) { ... });

// One-shot recording
final packets = await g2.mic.record(Duration(seconds: 5));
final wav = g2.mic.toWav(packets);  // requires LC3 decoder

// Stop
await g2.mic.stop();
```

To decode LC3 to PCM, provide an external decoder:
```dart
g2.mic.setDecoder((Uint8List lc3Frame) {
  return myLc3Decoder.decode(lc3Frame); // returns Int16List (160 samples)
});
g2.mic.onPcm((samples) => print('${samples.length} PCM samples'));
```

### Gestures

Touch and motion events from the glasses sensors.

```dart
g2.onGesture((gesture) {
  if (gesture.isTap) print('Tap');
  if (gesture.isDoubleTap) print('Double tap');
  if (gesture.isScroll) print('Scroll to position ${gesture.position}');
  if (gesture.isLongPress) print('Long press');
  if (gesture.isHeadTilt) print('Head tilt, dashboard pos ${gesture.position}');
});
```

Note: The glasses report **state changes** (position/item indices), not gesture types directly. The SDK maps these to semantic gesture types.

### EvenHub - Custom Pages

Create custom page layouts with text and image containers on the glasses display.

```dart
// Create a page with text containers
final page = await g2.hub.createPage(PageLayout(
  textContainers: [
    TextContainer(id: 10, x: 0, y: 0, width: 400, height: 100, content: 'Title'),
    TextContainer(id: 11, x: 0, y: 100, width: 400, height: 100, content: 'Body'),
  ],
));

// Update text content
await g2.hub.updateText(containerId: 10, text: 'Updated Title');

// Listen for touch events on containers
g2.hub.events.listen((event) {
  if (event.isClick) print('Clicked container ${event.containerID}');
});

// Close the page
await g2.hub.closePage();
```

### Settings

```dart
// Wear detection
await g2.settings.wearDetection(true);   // enable
await g2.settings.wearDetection(false);  // disable
```

### Ring Support

Optional R1 ring integration. Set the ring MAC before connecting:

```dart
// Set ring MAC address (6 bytes) — found during BLE scan or from Even app
g2.ringMac = [0x6C, 0xAB, 0x8E, 0x19, 0x25, 0xEB];
await g2.connectToNearest();
// Ring presence is registered automatically during init
```

If `ringMac` is null, the ring presence step is skipped.

### Debug Events

```dart
// All raw protocol packets from glasses
g2.debugEvents.listen((event) {
  final svc = '${event.packet.serviceHi.toRadixString(16)}-${event.packet.serviceLo.toRadixString(16)}';
  print('$svc [${event.packet.payload.length}B]');
});
```

## BLE Architecture

### Dual-Ear Connection

Even G2 glasses are two separate BLE devices (`_L_` and `_R_`). The SDK connects both:
- **Left ear** (`_L_`): Primary device. Receives auth, init, and all commands.
- **Right ear** (`_R_`): Secondary. Sends AI wake events (0x07-0x01) back to the phone.

`connectToNearest()` handles this automatically.

### Characteristics

| UUID Suffix | Direction | Purpose |
|-------------|-----------|---------|
| `5401` | Write | Commands (phone -> glasses) |
| `5402` | Notify | Responses + events (glasses -> phone) |
| `6401` | Write | Display data (images) |
| `6402` | Notify | Mic audio (raw LC3, no transport header) |
| `7401` | Write | Third channel (notification whitelist) |
| `7402` | Notify | Third channel responses |

Base UUID: `00002760-08C2-11E1-9073-0E8AC72E{suffix}`

### Transport Packet Format

```
[0xAA] [type] [seq] [len] [pkt_total] [pkt_serial] [svc_hi] [svc_lo] [payload...] [crc16_le]
```

- `type`: 0x21 = phone->glasses, 0x12 = glasses->phone
- `crc`: CRC-16/CCITT (init=0xFFFF, poly=0x1021) over payload only, little-endian
- Mic audio on 6402 is NOT wrapped in transport (raw LC3 frames directly)

### Service Map

| Service | Sub | Direction | Purpose |
|---------|-----|-----------|---------|
| 0x01 | 0x20/0x00/0x01 | Both | News/stock data + dashboard scroll events |
| 0x03 | 0x20/0x00 | Both | STT model configuration |
| 0x04 | 0x20/0x00 | Both | Display wake configuration |
| 0x07 | 0x20/0x00/0x01 | Both | **Dashboard / AI session** (transcription, response, events) |
| 0x09 | 0x20/0x00/0x01 | Both | Device info, battery, brightness, settings |
| 0x0B | 0x20/0x00 | Both | Conversate (real-time text display) |
| 0x0C | 0x20/0x00 | Both | Tasks / quick list |
| 0x0D | 0x20/0x00/0x01 | Both | Device config + display on/off events |
| 0x0E | 0x20/0x00 | Both | Widget dashboard config (per-eye brightness) |
| 0x10 | 0x20/0x00 | Both | Onboarding |
| 0x20 | 0x20/0x00 | Both | Commit (settings sync) |
| 0x80 | 0x00/0x01/0x20 | Both | Auth, time sync, heartbeats, ring info |
| 0x81 | 0x20/0x00 | Both | EvenHub legacy init |
| 0x91 | 0x20/0x00 | Both | Ring presence (MAC registration) |
| 0xC4 | 0x00 | Both | File transfer (notification whitelist file) |
| 0xC5 | 0x00 | Both | Notification whitelist JSON |
| 0xE0 | 0x00 | Both | EvenHub app service (containers, audio, IMU) |

Sub-service pattern: `0x00` = response, `0x01` = event, `0x20` = command.

## Platform Support

Uses `universal_ble` — supports iOS, Android, macOS, Linux, Windows, and web.

## License

MIT
