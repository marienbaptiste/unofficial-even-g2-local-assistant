/// Flutter SDK for Even G2 smart glasses BLE protocol.
///
/// Provides scanning, connection, authentication, display control,
/// mic audio streaming, gesture events, and settings management.
///
/// ```dart
/// import 'package:even_g2_sdk/even_g2_sdk.dart';
///
/// final g2 = EvenG2();
/// final devices = await EvenG2.scan();
/// await g2.connect(devices.first);
/// await g2.showText('Hello from Flutter!');
/// ```
library even_g2_sdk;

// Main API
export 'src/even_g2.dart';

// Models
export 'src/models/g2_device.dart';
export 'src/models/gesture_event.dart';
export 'src/models/audio_frame.dart';
export 'src/models/display_config.dart';
export 'src/models/container.dart';
export 'src/models/evenhub_event.dart';

// Transport (for advanced usage)
export 'src/transport/ble_transport.dart' show BleTransport, G2Uuids;
export 'src/transport/packet_builder.dart' show PacketBuilder, G2Packet, Varint;
export 'src/transport/crc.dart' show Crc16;

// Protocol (for advanced usage)
export 'src/protocol/auth.dart' show Auth;
export 'src/protocol/display.dart' show Display;
export 'src/protocol/audio.dart' show Audio;
export 'src/protocol/gestures.dart' show Gestures;
export 'src/protocol/settings.dart' show Settings;
export 'src/protocol/evenhub.dart' show EvenHub;
