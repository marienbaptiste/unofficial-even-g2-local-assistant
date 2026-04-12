# Even G2 SDK

Flutter SDK for the Even G2 smart glasses BLE protocol. Provides a clean API for all confirmed G2 features including display control, mic audio streaming, gesture events, and settings.

## Installation

Add to your `pubspec.yaml`:

```yaml
dependencies:
  even_g2_sdk:
    path: ../SDK/even_g2_sdk  # or publish to pub.dev
```

## Quick Start

```dart
import 'package:even_g2_sdk/even_g2_sdk.dart';

final g2 = EvenG2();

// Scan for devices
final devices = await EvenG2.scan(timeout: Duration(seconds: 10));

// Connect (auth handshake is automatic)
await g2.connect(devices.first);

// Display text
await g2.showText('Hello from Flutter!');

// Clean up
await g2.disconnect();
g2.dispose();
```

## API Reference

### Connection

```dart
// Scan for nearby G2 glasses
static Future<List<G2Device>> EvenG2.scan({Duration timeout});

// Connect and authenticate
Future<void> connect(G2Device device);

// Disconnect
Future<void> disconnect();

// Connection state
bool get isConnected;
Stream<bool> get connectionStream;
```

### Display - Conversate

Real-time text display with streaming support (service 0x0B-0x20).

```dart
// Show text (init packet sent automatically on first call)
await g2.showText('Hello!');

// Streaming text (partial updates)
await g2.showText('Thinking', isFinal: false);
await g2.showText('Thinking...done!', isFinal: true);

// Keep session alive
await g2.sendHeartbeat();
```

### Display - Teleprompter

Multi-page scrollable text display (service 0x06-0x20). Text is automatically word-wrapped (25 chars/line) and paginated (10 lines/page).

```dart
await g2.showTeleprompter('Your long text here...');
await g2.showTeleprompter('Auto scroll text', manualMode: false);
```

### Mic Audio

LC3-encoded mic audio from UUID 6402. Subscribing starts the mic stream automatically.

```dart
// Start mic
await g2.startMic();

// Listen for LC3 frames (40 bytes each, 10ms/frame, 16kHz mono)
g2.micFrameStream.listen((AudioFrame frame) {
  // frame.data = raw LC3 bytes
  // frame.sequenceCounter = packet sequence
});

// Or get raw 205-byte packets (5 frames + trailer)
g2.micRawStream.listen((Uint8List packet) { ... });

// Stop mic
await g2.stopMic();
```

LC3 decoding is NOT included. Use an external LC3 decoder via FFI to convert frames to PCM.

LC3 parameters: 10ms frame duration, 16kHz sample rate, 32kbps, mono, 160 samples/frame.

### Gestures

Touch and motion events from the glasses (service 0x01-0x01).

```dart
g2.gestures.listen((GestureEvent event) {
  switch (event.type) {
    case GestureType.singleTap:
    case GestureType.doubleTap:
    case GestureType.scroll:
    case GestureType.longPress:
    case GestureType.bothHold:
    case GestureType.headTilt:
      print('Position: ${event.position}');
    case GestureType.unknown:
  }
});
```

### Settings

```dart
// Toggle wear detection (sends init sync + toggle)
await g2.setWearDetection(true);   // ON
await g2.setWearDetection(false);  // OFF
```

### Raw Events

```dart
// All parsed packets from the glasses
g2.events.listen((G2RawEvent event) {
  print(event.packet); // G2Packet with service ID, payload, etc.
});
```

## Advanced Usage

For direct protocol access, use the exported protocol classes:

```dart
import 'package:even_g2_sdk/even_g2_sdk.dart';

// Build packets manually
final packet = PacketBuilder.build(
  seq: 0x01,
  serviceHi: 0x0B,
  serviceLo: 0x20,
  payload: [...],
);

// CRC verification
final isValid = Crc16.verify(rawPacketBytes);

// Varint encoding
final encoded = Varint.encode(1234567);
final (value, consumed) = Varint.decode(data, offset);

// Auth packets
final authSequence = Auth.buildAuthPackets();

// Display packets
final init = Display.buildConversateInit(seq, msgId);
final text = Display.buildConversateText(seq, msgId, 'Hello');
final pages = Display.formatText('Long text...');
```

## BLE UUIDs

| UUID Suffix | Direction | Purpose |
|-------------|-----------|---------|
| `5401` | Write | Commands (phone -> glasses) |
| `5402` | Notify | Responses (glasses -> phone) |
| `6401` | Write | Display data |
| `6402` | Notify | Mic audio stream (LC3) |
| `7401` | Write | Third channel |
| `7402` | Notify | Third channel |

Base UUID: `00002760-08C2-11E1-9073-0E8AC72E{suffix}`

## Packet Format

```
[0xAA] [type] [seq] [len] [pkt_total] [pkt_serial] [svc_hi] [svc_lo] [payload...] [crc_lo] [crc_hi]
```

- Type: `0x21` = TX (phone->glasses), `0x12` = RX (glasses->phone)
- CRC-16/CCITT (init=0xFFFF, poly=0x1021) over payload only, little-endian
- pkt_serial is 1-indexed

## Test App

A Windows test app is included in `test/windows_test_app/`. It uses `universal_ble` for Windows BLE support.

```bash
cd test/windows_test_app
flutter run -d windows
```

## Platform Support

The SDK uses `universal_ble` which supports iOS, Android, macOS, Linux, Windows, and web.

## License

MIT
