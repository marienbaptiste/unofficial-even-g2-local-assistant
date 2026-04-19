import 'dart:async';
import 'dart:typed_data';

import 'transport/ble_transport.dart';
import 'transport/packet_builder.dart';
import 'protocol/auth.dart';
import 'protocol/display.dart';
import 'protocol/audio.dart';
import 'protocol/gestures.dart';
import 'protocol/settings.dart';
import 'protocol/evenhub.dart';
import 'protocol/dashboard.dart';
import 'models/g2_device.dart';
import 'models/gesture_event.dart';
import 'models/audio_frame.dart';
import 'models/container.dart';
import 'models/evenhub_event.dart';

/// Main API for interacting with Even G2 smart glasses.
///
/// Handles all connection, authentication, and protocol details internally.
/// Just connect, then use [display], [mic], [settings], and [hub].
///
/// ```dart
/// final g2 = EvenG2();
///
/// // Find and connect
/// await g2.connectToNearest();
///
/// // Display text
/// await g2.display.show("Hello!");
/// await g2.display.showPartial("Typing...");
/// await g2.display.showFinal("Typing... complete!");
/// await g2.display.teleprompter("Long scrollable text...");
/// await g2.display.clear();
///
/// // Microphone
/// await g2.mic.start();
/// await Future.delayed(Duration(seconds: 5));
/// final packets = await g2.mic.stop();
/// final wav = g2.mic.toWav(packets);
///
/// // One-shot recording
/// final recorded = await g2.mic.record(Duration(seconds: 5));
///
/// // Gestures (the glasses report state changes, not gesture types)
/// g2.onGesture((gesture) {
///   if (gesture.isTap) print('Tapped!');
///   if (gesture.isDoubleTap) print('Double tap!');
///   if (gesture.isScroll) print('Scrolled to ${gesture.position}');
///   if (gesture.isHeadTilt) print('Tilted! Dashboard pos ${gesture.position}');
/// });
///
/// // Settings
/// await g2.settings.wearDetection(true);
///
/// // Cleanup
/// await g2.disconnect();
/// ```
class EvenG2 {
  final BleTransport _transport = BleTransport();
  final Audio _audioHandler = Audio();
  final Gestures _gestureHandler = Gestures();

  /// Optional R1 ring MAC address (6 bytes). Set via [ringMac] before connecting.
  /// If null, ring presence packet is skipped during init.
  List<int>? ringMac;

  int _seq = 0x08;
  int _msgId = 0x14;
  bool _authenticated = false;
  bool _disposed = false;

  StreamSubscription? _notifySubscription;
  StreamSubscription? _micSubscription;
  Timer? _heartbeatTimer;

  // Auto-reconnect state
  bool _autoReconnect = true;
  bool _reconnecting = false;
  G2Device? _lastDevice;
  Duration _reconnectDelay = const Duration(seconds: 3);
  int _reconnectAttempts = 0;
  static const int _maxReconnectAttempts = 10;

  final _eventController = StreamController<G2RawEvent>.broadcast();

  /// Display controller for showing text on the glasses.
  ///
  /// Use [G2Display.show] for one-shot messages, [G2Display.showPartial] and
  /// [G2Display.showFinal] for streaming text, or [G2Display.teleprompter]
  /// for long scrollable content.
  late final G2Display display = G2Display._(this);

  /// Microphone controller for recording audio from the glasses.
  ///
  /// Use [G2Mic.start] and [G2Mic.stop] to capture audio, or [G2Mic.record]
  /// for a simple timed recording. Provides raw packet data and optional
  /// decoded PCM output.
  late final G2Mic mic = G2Mic._(this);

  /// Device settings controller.
  ///
  /// Currently supports enabling/disabling wear detection.
  late final G2Settings settings = G2Settings._(this);

  /// EvenHub controller — container-based display with touch events.
  late final G2Hub hub = G2Hub._(this);

  /// Dashboard / AI session controller.
  ///
  /// Use to send live transcription, stream AI responses, and manage
  /// the AI conversation flow on the glasses via service 0x07.
  late final G2Dashboard dashboard = G2Dashboard._(this);

  // =========================================================================
  // Connection
  // =========================================================================

  /// Scan for nearby Even G2 glasses.
  ///
  /// Returns a list of discovered devices. You will typically see both
  /// left and right earpieces advertised separately.
  static Future<List<G2Device>> scan({
    Duration timeout = const Duration(seconds: 10),
  }) => BleTransport.scan(timeout: timeout);

  /// Whether to automatically reconnect when the connection drops.
  ///
  /// Defaults to true. Set to false if you want to manage reconnection yourself.
  bool get autoReconnect => _autoReconnect;
  set autoReconnect(bool value) => _autoReconnect = value;

  /// Find and connect to the nearest G2 glasses automatically.
  ///
  /// Scans for nearby devices, picks the left earpiece if available,
  /// connects, and handles all setup. This is the simplest way to connect.
  ///
  /// ```dart
  /// await g2.connectToNearest();
  /// ```
  Future<void> connectToNearest({Duration scanTimeout = const Duration(seconds: 10)}) async {
    final devices = await scan(timeout: scanTimeout);
    if (devices.isEmpty) throw StateError('No Even G2 glasses found');

    // Connect BOTH ears — left for display, right for AI events
    final left = devices.where((d) => d.name.contains('_L_'));
    final right = devices.where((d) => d.name.contains('_R_'));
    final primary = left.isNotEmpty ? left.first : devices.first;
    final secondary = right.isNotEmpty ? right.first : null;
    await connect(primary);
    if (secondary != null) {
      await _transport.connectSecondary(secondary);
    }
  }

  /// Connect to a specific G2 device from a [scan] result.
  ///
  /// Handles authentication and setup automatically.
  ///
  /// ```dart
  /// final devices = await EvenG2.scan();
  /// await g2.connect(devices.first);
  /// ```
  Future<void> connect(G2Device device) async {
    _lastDevice = device;
    _reconnectAttempts = 0;

    await _transport.connect(device);
    _notifySubscription = _transport.notifyStream.listen(_onNotify);

    // Listen for unexpected disconnects
    _transport.connectionStream.listen((connected) {
      if (!connected && _authenticated && !_disposed) {
        _onDisconnect();
      }
    });

    await _authenticate();
    await _initServices();
    _startHeartbeat();
  }

  /// Disconnect from the glasses and stop auto-reconnect.
  ///
  /// ```dart
  /// await g2.disconnect();
  /// ```
  Future<void> disconnect() async {
    _autoReconnect = false; // prevent reconnect on intentional disconnect
    await _cleanup();
  }

  /// Whether the glasses are currently connected and ready to use.
  bool get isConnected => _transport.isConnected && _authenticated;

  /// Whether a reconnection attempt is in progress.
  bool get isReconnecting => _reconnecting;

  /// Stream that emits true/false when the connection state changes.
  ///
  /// ```dart
  /// g2.onConnectionChange.listen((connected) {
  ///   print(connected ? 'Connected' : 'Disconnected');
  /// });
  /// ```
  Stream<bool> get onConnectionChange => _transport.connectionStream;

  // =========================================================================
  // Gestures
  // =========================================================================

  /// Listen for gesture events from the glasses touchpad and sensors.
  ///
  /// The glasses report state changes (e.g. "touch began", "touch ended")
  /// which the SDK maps to semantic gesture types like tap, double-tap,
  /// scroll, long-press, etc.
  ///
  /// ```dart
  /// g2.onGesture((gesture) {
  ///   if (gesture.isTap) print('Tap!');
  ///   if (gesture.isDoubleTap) print('Double tap!');
  ///   if (gesture.isScroll) print('Scroll pos=${gesture.position}');
  ///   if (gesture.isLongPress) print('Long press!');
  ///   if (gesture.isHeadTilt) print('Tilt pos=${gesture.position}');
  /// });
  /// ```
  StreamSubscription<GestureEvent> onGesture(void Function(GestureEvent) callback) {
    return _gestureHandler.gestureStream.listen(callback);
  }

  /// Gesture event stream for use with StreamBuilder or other stream consumers.
  ///
  /// Prefer [onGesture] for simple callback-based listening.
  Stream<GestureEvent> get gestureStream => _gestureHandler.gestureStream;

  // =========================================================================
  // Raw Events (for debugging)
  // =========================================================================

  /// Stream of low-level protocol events for debugging and analysis.
  ///
  /// Each event contains the parsed packet with service IDs and payload.
  /// Not needed for normal use -- prefer [onGesture], [mic], and [display].
  ///
  /// ```dart
  /// g2.debugEvents.listen((event) => print(event));
  /// ```
  Stream<G2RawEvent> get debugEvents => _eventController.stream;

  // =========================================================================
  // Private
  // =========================================================================

  Future<void> _authenticate() async {
    for (final packet in Auth.buildAuthPackets()) {
      await _send(packet);
      await Future.delayed(const Duration(milliseconds: 100));
    }
    await Future.delayed(const Duration(milliseconds: 500));
    _authenticated = true;
  }

  /// Send the service init sequence after authentication.
  ///
  /// The Even app sends this batch right after auth to tell the glasses
  /// which features the phone supports. Without this, the AI listening
  /// interface doesn't activate on "Hey Even".
  ///
  /// Sequence matched to BLE capture capture_20260414_083412 (pkt#39060-39755).
  /// auth.dart Auth 2 sends f4.f1=2 (callback registration for wake events).
  Future<void> _initServices() async {
    const d = Duration(milliseconds: 50);

    // Second auth handshake (0x80-0x00, cmd=4) — capture pkt#39365
    await _send(PacketBuilder.build(
      seq: _nextSeq(), serviceHi: 0x80, serviceLo: 0x00,
      payload: [0x08, 0x04, 0x10, ...Varint.encode(_nextMsgId()), 0x1A, 0x04, 0x08, 0x01, 0x10, 0x04],
    ));
    await Future.delayed(const Duration(milliseconds: 300));

    // Capability mode (0x80-0x20, type=5) — capture pkt#39384
    await _send(PacketBuilder.build(
      seq: _nextSeq(), serviceHi: 0x80, serviceLo: 0x20,
      payload: [0x08, 0x05, 0x10, ...Varint.encode(_nextMsgId()), 0x22, 0x02, 0x08, 0x02], // f4.f1=2 — wake detection
    ));
    await Future.delayed(d);

    // Time sync (0x80-0x20, type=128) — capture pkt#39396
    final now = DateTime.now();
    final unixSec = now.millisecondsSinceEpoch ~/ 1000;
    final tzQuarters = now.timeZoneOffset.inMinutes ~/ 15;
    final tsBytes = Varint.encode(unixSec);
    final tzBytes = Varint.encode(tzQuarters);
    await _send(PacketBuilder.build(
      seq: _nextSeq(), serviceHi: 0x80, serviceLo: 0x20,
      payload: [
        0x08, 0x80, 0x01,
        0x10, ...Varint.encode(_nextMsgId()),
        0x82, 0x08,
        ...Varint.encode(2 + tsBytes.length + tzBytes.length),
        0x08, ...tsBytes,
        0x10, ...tzBytes,
      ],
    ));
    await Future.delayed(d);

    // 1. Settings init (0x09-0x20, type=1) — capture pkt#39443
    await _send(PacketBuilder.build(
      seq: _nextSeq(), serviceHi: 0x09, serviceLo: 0x20,
      payload: [
        0x08, 0x01, 0x10, ...Varint.encode(_nextMsgId()),
        0x1A, 0x0C, 0x4A, 0x0A, 0x08, 0x00, 0x10, 0x00, 0x18, 0x00, 0x20, 0x02, 0x28, 0x01,
      ],
    ));
    await Future.delayed(d);

    // 2. STT config (0x03-0x20, type=0) — capture pkt#39476
    await _send(PacketBuilder.build(
      seq: _nextSeq(), serviceHi: 0x03, serviceLo: 0x20,
      payload: [
        0x08, 0x00, 0x10, ...Varint.encode(_nextMsgId()),
        0x1a, 0x63, 0x08, 0x0a, 0x12, 0x04, 0x08, 0x00, 0x20, 0x04,
        0x12, 0x04, 0x08, 0x00, 0x20, 0x0b, 0x12, 0x04, 0x08, 0x00,
        0x20, 0x06, 0x12, 0x04, 0x08, 0x00, 0x20, 0x05, 0x12, 0x04,
        0x08, 0x00, 0x20, 0x08, 0x12, 0x04, 0x08, 0x00, 0x20, 0x07,
        0x12, 0x04, 0x08, 0x00, 0x20, 0x01, 0x12, 0x05, 0x08, 0x00,
        0x20, 0x8a, 0x02, 0x12, 0x1b, 0x08, 0x01, 0x10, 0x01, 0x1a,
        0x12, 0x73, 0x61, 0x6c, 0x65, 0x73, 0x65, 0x79, 0x65, 0x2d,
        0x75, 0x6e, 0x69, 0x76, 0x65, 0x72, 0x73, 0x61, 0x6c, 0x20,
        0xd1, 0x50, 0x12, 0x11, 0x08, 0x01, 0x10, 0x01, 0x1a, 0x08,
        0x73, 0x6f, 0x50, 0x48, 0x49, 0x43, 0x4f, 0x4e, 0x20, 0xdb,
        0x4e,
      ],
    ));
    await Future.delayed(d);

    // 3. Display state (0x0D-0x20, type=0) — capture pkt#39490
    await _send(PacketBuilder.build(
      seq: _nextSeq(), serviceHi: 0x0D, serviceLo: 0x20,
      payload: [0x08, 0x00, 0x10, ...Varint.encode(_nextMsgId())],
    ));
    await Future.delayed(d);

    // 4. Tasks status (0x0C-0x20, type=2) — capture pkt#39506
    await _send(PacketBuilder.build(
      seq: _nextSeq(), serviceHi: 0x0C, serviceLo: 0x20,
      payload: [
        0x08, 0x02, 0x10, ...Varint.encode(_nextMsgId()),
        0x22, 0x04, 0x08, 0x01, 0x10, 0x00,
      ],
    ));
    await Future.delayed(d);

    // 5. Dashboard / AI init (0x07-0x20, type=10) — capture pkt#39524
    await _send(Dashboard.buildConfig(_nextSeq(), _nextMsgId()));
    await Future.delayed(d);

    // 5b. Display/health config (0x0E-0x20, type=4) — required for AI interface
    await _send(PacketBuilder.build(
      seq: _nextSeq(), serviceHi: 0x0E, serviceLo: 0x20,
      payload: [
        0x08, 0x04, 0x10, ...Varint.encode(_nextMsgId()),
        0x32, 0x58, 0x0a, 0x54, 0x08, 0x03, 0x12, 0x4e, 0x45, 0x6e,
        0x65, 0x72, 0x67, 0x79, 0x20, 0x6f, 0x75, 0x74, 0x70, 0x75,
        0x74, 0x20, 0x64, 0x69, 0x70, 0x70, 0x65, 0x64, 0x3b, 0x20,
        0x61, 0x64, 0x64, 0x20, 0x73, 0x68, 0x6f, 0x72, 0x74, 0x20,
        0x6d, 0x6f, 0x76, 0x65, 0x6d, 0x65, 0x6e, 0x74, 0x20, 0x62,
        0x75, 0x72, 0x73, 0x74, 0x73, 0x20, 0x74, 0x6f, 0x20, 0x72,
        0x65, 0x74, 0x75, 0x72, 0x6e, 0x20, 0x74, 0x6f, 0x20, 0x79,
        0x6f, 0x75, 0x72, 0x20, 0x75, 0x73, 0x75, 0x61, 0x6c, 0x20,
        0x72, 0x68, 0x79, 0x74, 0x68, 0x6d, 0x18, 0x00, 0x10, 0x00,
      ],
    ));
    await Future.delayed(d);

    // 6. Skip onboarding (0x10-0x20, type=1) — capture pkt#39542
    await _send(PacketBuilder.build(
      seq: _nextSeq(), serviceHi: 0x10, serviceLo: 0x20,
      payload: [
        0x08, 0x01, 0x10, ...Varint.encode(_nextMsgId()),
        0x1a, 0x02, 0x08, 0x04,
      ],
    ));
    await Future.delayed(d);

    // 7. Ring presence (0x91-0x20, type=1) — capture pkt#39560
    if (ringMac != null && ringMac!.length == 6) {
      await _send(PacketBuilder.build(
        seq: _nextSeq(), serviceHi: 0x91, serviceLo: 0x20,
        payload: [
          0x08, 0x01, 0x10, ...Varint.encode(_nextMsgId()),
          0x1a, 0x0c, 0x0a, 0x06, ...ringMac!,
          0x10, 0x01, 0x18, 0x00,
        ],
      ));
      await Future.delayed(d);
    }

    // 8. Settings query (0x09-0x20, type=2) — capture pkt#39572
    await _send(PacketBuilder.build(
      seq: _nextSeq(), serviceHi: 0x09, serviceLo: 0x20,
      payload: [0x08, 0x02, 0x10, ...Varint.encode(_nextMsgId()), 0x22, 0x02, 0x08, 0x01],
    ));
    await Future.delayed(d);

    // 9. Display config (0x01-0x20, type=2) — capture pkt#39621
    await _send(PacketBuilder.build(
      seq: _nextSeq(), serviceHi: 0x01, serviceLo: 0x20,
      payload: [0x08, 0x02, 0x10, ...Varint.encode(_nextMsgId()),
        0x22, 0x17, 0x12, 0x15, 0x08, 0x04, 0x10, 0x03, 0x1A, 0x03, 0x01, 0x02, 0x03,
        0x20, 0x04, 0x2A, 0x04, 0x01, 0x03, 0x02, 0x02, 0x30, 0x00, 0x38, 0x01],
    ));
    await Future.delayed(d);

    // 10. EvenHub init (0x81-0x20, type=1) — capture pkt#39702
    await _send(PacketBuilder.build(
      seq: _nextSeq(), serviceHi: 0x81, serviceLo: 0x20,
      payload: [0x08, 0x01, 0x10, ...Varint.encode(_nextMsgId()), 0x1A, 0x00],
    ));
    await Future.delayed(d);

    // 11. Commit (0x20-0x20, type=0 + type=1) — capture pkt#39714+39720
    await _send(PacketBuilder.build(
      seq: _nextSeq(), serviceHi: 0x20, serviceLo: 0x20,
      payload: [0x08, 0x00, 0x10, ...Varint.encode(_nextMsgId()), 0x1A, 0x02, 0x08, 0x00],
    ));
    await Future.delayed(d);
    await _send(PacketBuilder.build(
      seq: _nextSeq(), serviceHi: 0x20, serviceLo: 0x20,
      payload: [0x08, 0x01, 0x10, ...Varint.encode(_nextMsgId()), 0x22, 0x00],
    ));
    await Future.delayed(d);

    // 12. Equalizer config (0x09-0x20, type=1) — capture pkt#39729
    await _send(PacketBuilder.build(
      seq: _nextSeq(), serviceHi: 0x09, serviceLo: 0x20,
      payload: [0x08, 0x01, 0x10, ...Varint.encode(_nextMsgId()),
        0x1A, 0x1A, 0x52, 0x18,
        0x0A, 0x06, 0x08, 0x00, 0x10, 0x00, 0x18, 0x00,
        0x0A, 0x06, 0x08, 0x00, 0x10, 0x01, 0x18, 0x00,
        0x0A, 0x06, 0x08, 0x00, 0x10, 0x02, 0x18, 0x00],
    ));
    await Future.delayed(d);

    // 13. Audio config (0x04-0x20, type=1) — capture pkt#39740
    await _send(PacketBuilder.build(
      seq: _nextSeq(), serviceHi: 0x04, serviceLo: 0x20,
      payload: [0x08, 0x01, 0x10, ...Varint.encode(_nextMsgId()),
        0x1A, 0x08, 0x08, 0x01, 0x10, 0x01, 0x18, 0x05, 0x28, 0x01],
    ));
    await Future.delayed(d);

    // 14. Widget batch (0x0E-0x20, type=2) — capture pkt#40344
    // Full dashboard widget layout. Last packet before 0x07-0x01 wake event fires.
    // Widgets: 2=stocks(10s), 3=news(2s), 4=general, 5=intensity, 6=balance, 9=unknown
    await _send(PacketBuilder.build(
      seq: _nextSeq(), serviceHi: 0x0E, serviceLo: 0x20,
      payload: [
        0x08, 0x02, 0x10, ...Varint.encode(_nextMsgId()),
        // field4 (tag 0x22), length 138 (varint 0x8A 0x01)
        0x22, 0x8A, 0x01,
        // f4.f1=1 (batch version)
        0x08, 0x01,
        // widget 2: stocks, refresh 10000ms
        0x12, 0x15, 0x08, 0x02, 0x10, 0x90, 0x4E, 0x1D, 0x00, 0x00, 0x00, 0x00, 0x25, 0x00, 0x00, 0x00, 0x00, 0x28, 0x00, 0x30, 0x00, 0x38, 0x00,
        // widget 3: news, refresh 2000ms, f3=1.0
        0x12, 0x15, 0x08, 0x03, 0x10, 0xD0, 0x0F, 0x1D, 0x00, 0x00, 0x80, 0x3F, 0x25, 0x00, 0x00, 0x00, 0x00, 0x28, 0x00, 0x30, 0x00, 0x38, 0x00,
        // widget 4: general
        0x12, 0x14, 0x08, 0x04, 0x10, 0x00, 0x1D, 0x00, 0x00, 0x00, 0x00, 0x25, 0x00, 0x00, 0x00, 0x00, 0x28, 0x00, 0x30, 0x00, 0x38, 0x00,
        // widget 5: intensity, f3=63.0 f4=68.0
        0x12, 0x14, 0x08, 0x05, 0x10, 0x00, 0x1D, 0x00, 0x00, 0x7C, 0x42, 0x25, 0x00, 0x00, 0x88, 0x42, 0x28, 0x00, 0x30, 0x00, 0x38, 0x00,
        // widget 6: balance
        0x12, 0x14, 0x08, 0x06, 0x10, 0x00, 0x1D, 0x00, 0x00, 0x00, 0x00, 0x25, 0x00, 0x00, 0x00, 0x00, 0x28, 0x00, 0x30, 0x00, 0x38, 0x00,
        // widget 9: unknown
        0x12, 0x14, 0x08, 0x09, 0x10, 0x00, 0x1D, 0x00, 0x00, 0x00, 0x00, 0x25, 0x00, 0x00, 0x00, 0x00, 0x28, 0x00, 0x30, 0x00, 0x38, 0x00,
        // f3=0 (end marker)
        0x18, 0x00,
      ],
    ));
    await Future.delayed(d);
  }

  // ---------------------------------------------------------------------------
  // Heartbeat — keeps the BLE connection alive
  // ---------------------------------------------------------------------------

  int _heartbeatCount = 0;

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatCount = 0;
    // Even app sends both heartbeats every 5s; battery poll every 10th tick (~50s)
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      if (_transport.isConnected && _authenticated) {
        try {
          // 1. EvenHub heartbeat (service 0xE0-0x20, cmd=12)
          await _send(EvenHub.buildHubHeartbeat(_nextSeq(), _nextMsgId()));

          // 2. DevSettings heartbeat (service 0x80-0x00, cmd=14)
          final payload = <int>[0x08, 0x0E, 0x10, ...Varint.encode(_nextMsgId()), 0x6A, 0x00];
          await _send(PacketBuilder.build(
            seq: _nextSeq(), serviceHi: 0x80, serviceLo: 0x00, payload: payload,
          ));

          _heartbeatCount++;
        } catch (_) {
          // Connection may have dropped — will trigger reconnect
        }
      }
    });
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  // ---------------------------------------------------------------------------
  // Auto-reconnect
  // ---------------------------------------------------------------------------

  void _onDisconnect() {
    _authenticated = false;
    _stopHeartbeat();
    display._reset();

    if (_autoReconnect && !_disposed && !_reconnecting && _lastDevice != null) {
      _attemptReconnect();
    }
  }

  Future<void> _attemptReconnect() async {
    _reconnecting = true;
    _reconnectAttempts++;

    while (_autoReconnect && !_disposed && _reconnectAttempts <= _maxReconnectAttempts) {
      try {
        // Exponential backoff: 3s, 6s, 12s... capped at 30s
        final delay = Duration(seconds: (_reconnectDelay.inSeconds * _reconnectAttempts).clamp(3, 30));
        await Future.delayed(delay);

        if (_disposed || !_autoReconnect) break;

        // Try to reconnect
        await _cleanup(keepAutoReconnect: true);
        await _transport.connect(_lastDevice!);
        _notifySubscription = _transport.notifyStream.listen(_onNotify);
        await _authenticate();
        await _initServices();
        _startHeartbeat();

        // Restore mic if it was active
        if (mic._active) {
          _micSubscription = _transport.micStream.listen(_audioHandler.processPacket);
          await _transport.subscribeMic();
        }

        _reconnectAttempts = 0;
        _reconnecting = false;
        return;
      } catch (_) {
        _reconnectAttempts++;
      }
    }

    _reconnecting = false;
  }

  Future<void> _cleanup({bool keepAutoReconnect = false}) async {
    final savedAutoReconnect = _autoReconnect;
    _stopHeartbeat();

    if (mic.isActive) {
      await _micSubscription?.cancel();
      _micSubscription = null;
      mic._active = false;
    }
    await _notifySubscription?.cancel();
    _notifySubscription = null;
    await _transport.disconnect();
    _authenticated = false;
    _seq = 0x08;
    _msgId = 0x14;
    display._reset();

    if (keepAutoReconnect) {
      _autoReconnect = savedAutoReconnect;
    }
  }

  // Pending response completers — keyed by "svcHi-svcLo"
  final Map<String, Completer<G2Packet>> _pendingResponses = {};

  void _onNotify(List<int> data) {
    final packet = PacketBuilder.parse(data);
    if (packet != null) {
      _eventController.add(G2RawEvent(packet: packet));
      _gestureHandler.processPacket(packet);
      hub._processPacket(packet);
      dashboard._processPacket(packet);

      // Complete any pending response waiter
      final key = '${packet.serviceHi}-${packet.serviceLo}';
      if (_pendingResponses.containsKey(key)) {
        _pendingResponses[key]!.complete(packet);
        _pendingResponses.remove(key);
      }
    }
  }

  /// Send a packet and wait for a response on the specified service.
  ///
  /// Returns the response packet, or null if timeout.
  Future<G2Packet?> _sendAndWait(Uint8List data, {
    required int responseSvcHi,
    required int responseSvcLo,
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final key = '$responseSvcHi-$responseSvcLo';
    final completer = Completer<G2Packet>();
    _pendingResponses[key] = completer;

    await _send(data);

    try {
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      _pendingResponses.remove(key);
      return null;
    }
  }

  Future<void> _send(Uint8List data) => _transport.write(data);
  int _nextSeq() => _seq++;
  int _nextMsgId() => _msgId++;

  /// Send a raw pre-built packet for advanced/test usage.
  Future<void> sendRaw(Uint8List data) {
    _ensureConnected();
    return _send(data);
  }

  /// Get the next sequence number for manual packet building.
  int nextSeq() => _nextSeq();

  /// Get the next message ID for manual packet building.
  int nextMsgId() => _nextMsgId();

  void _ensureConnected() {
    if (!_transport.isConnected) {
      throw StateError('Not connected. Call connect() or connectToNearest() first.');
    }
  }

  /// Release all resources permanently.
  ///
  /// Call this when you are completely done with the glasses instance.
  /// After calling dispose, this instance cannot be reused.
  ///
  /// ```dart
  /// await g2.disconnect();
  /// g2.dispose();
  /// ```
  void dispose() {
    _disposed = true;
    _autoReconnect = false;
    _stopHeartbeat();
    _notifySubscription?.cancel();
    _micSubscription?.cancel();
    _audioHandler.dispose();
    _gestureHandler.dispose();
    dashboard._dispose();
    hub._dispose();
    _eventController.close();
    _transport.dispose();
  }
}

// =============================================================================
// G2Display — text display controller
// =============================================================================

/// Controls what text appears on the glasses display.
///
/// Three display modes:
/// - **One-shot**: [show] displays a complete message.
/// - **Streaming**: [showPartial] and [showFinal] for incremental text
///   (e.g. AI responses arriving word by word).
/// - **Teleprompter**: [teleprompter] for long scrollable text.
class G2Display {
  final EvenG2 _g2;
  bool _conversateInitSent = false;
  Timer? _conversateHeartbeatTimer;

  /// Interval between Conversate heartbeat packets. Matches Even app capture (~10s).
  static const Duration conversateHeartbeatInterval = Duration(seconds: 10);

  G2Display._(this._g2);

  void _startConversateHeartbeat() {
    _conversateHeartbeatTimer?.cancel();
    _conversateHeartbeatTimer = Timer.periodic(
      conversateHeartbeatInterval,
      (_) {
        if (_g2.isConnected && _conversateInitSent) {
          heartbeat().catchError((_) {});
        }
      },
    );
  }

  void _stopConversateHeartbeat() {
    _conversateHeartbeatTimer?.cancel();
    _conversateHeartbeatTimer = null;
  }

  /// Display a complete message on the glasses.
  ///
  /// Replaces whatever is currently shown. Best for short notifications,
  /// status updates, or single-line responses.
  ///
  /// ```dart
  /// await g2.display.show("Hello!");
  /// await g2.display.show("Temperature: 22°C");
  /// ```
  Future<void> show(String text) async {
    await _initConversate();
    await _g2._send(Display.buildConversateText(
      _g2._nextSeq(), _g2._nextMsgId(), text, isFinal: true,
    ));
  }

  /// Display an intermediate text update (more content is coming).
  ///
  /// Call this repeatedly as text arrives, then call [showFinal] with the
  /// complete text. The glasses show a "still loading" indicator until
  /// [showFinal] is called.
  ///
  /// ```dart
  /// await g2.display.showPartial("Think");
  /// await g2.display.showPartial("Thinking...");
  /// await g2.display.showFinal("The answer is 42.");
  /// ```
  Future<void> showPartial(String text) async {
    await _initConversate();
    await _g2._send(Display.buildConversateText(
      _g2._nextSeq(), _g2._nextMsgId(), text, isFinal: false,
    ));
  }

  /// Display the final text after a series of [showPartial] calls.
  ///
  /// Signals to the glasses that the streaming response is complete.
  /// Can also be used standalone as an alias for [show].
  ///
  /// ```dart
  /// await g2.display.showPartial("Loading...");
  /// await g2.display.showFinal("Done! Here are your results.");
  /// ```
  Future<void> showFinal(String text) async {
    await _initConversate();
    await _g2._send(Display.buildConversateText(
      _g2._nextSeq(), _g2._nextMsgId(), text, isFinal: true,
    ));
  }

  /// Clear the glasses display.
  ///
  /// Removes all text from the screen by sending an empty message.
  ///
  /// ```dart
  /// await g2.display.clear();
  /// ```
  Future<void> clear() async {
    await _initConversate();
    await _g2._send(Display.buildConversateText(
      _g2._nextSeq(), _g2._nextMsgId(), '', isFinal: true,
    ));
  }

  /// Display long scrollable text on the glasses.
  ///
  /// Automatically word-wraps and paginates the content.
  /// The user scrolls through pages using swipe gestures on the touchpad.
  ///
  /// ```dart
  /// await g2.display.teleprompter("Your long speech or notes here...");
  /// ```
  Future<void> teleprompter(String text, {bool manualScroll = true}) async {
    _g2._ensureConnected();

    final pages = Display.formatText(text);
    final totalLines = text.split('\n').length;

    await _g2._send(Display.buildDisplayConfig(_g2._nextSeq(), _g2._nextMsgId()));
    await Future.delayed(const Duration(milliseconds: 300));

    await _g2._send(Display.buildTeleprompterInit(
      _g2._nextSeq(), _g2._nextMsgId(),
      totalLines: totalLines, manualMode: manualScroll,
    ));
    await Future.delayed(const Duration(milliseconds: 500));

    for (int i = 0; i < 10 && i < pages.length; i++) {
      await _g2._send(Display.buildContentPage(_g2._nextSeq(), _g2._nextMsgId(), i, pages[i]));
      await Future.delayed(const Duration(milliseconds: 100));
    }

    await _g2._send(Display.buildMarker(_g2._nextSeq(), _g2._nextMsgId()));
    await Future.delayed(const Duration(milliseconds: 100));

    for (int i = 10; i < 12 && i < pages.length; i++) {
      await _g2._send(Display.buildContentPage(_g2._nextSeq(), _g2._nextMsgId(), i, pages[i]));
      await Future.delayed(const Duration(milliseconds: 100));
    }

    await _g2._send(Display.buildSync(_g2._nextSeq(), _g2._nextMsgId()));
    await Future.delayed(const Duration(milliseconds: 100));

    for (int i = 12; i < pages.length; i++) {
      await _g2._send(Display.buildContentPage(_g2._nextSeq(), _g2._nextMsgId(), i, pages[i]));
      await Future.delayed(const Duration(milliseconds: 100));
    }
  }

  /// Display an AI response card with an icon and a message.
  ///
  /// Cards stack on the glasses (up to 4). Use [isDone] = false while
  /// streaming, then send the final card with [isDone] = true.
  ///
  /// ```dart
  /// await g2.display.showAiResponse(
  ///   icon: Display.iconBulb,
  ///   message: "qwen2.5:7b 842ms",
  /// );
  /// ```
  Future<void> showAiResponse({
    required String message,
    int icon = Display.iconBulb,
    bool isDone = true,
  }) async {
    await _initConversate();
    await _g2._send(Display.buildAiResponse(
      _g2._nextSeq(), _g2._nextMsgId(),
      icon: icon, message: message, isDone: isDone,
    ));
  }

  /// Display the user's spoken prompt on the glasses.
  ///
  /// Shows what the user said, typically before an AI response follows.
  ///
  /// ```dart
  /// await g2.display.showUserPrompt("What's the weather today?");
  /// ```
  Future<void> showUserPrompt(String text) async {
    await _initConversate();
    await _g2._send(Display.buildUserPrompt(
      _g2._nextSeq(), _g2._nextMsgId(), text,
    ));
  }

  /// End the current display session.
  ///
  /// Closes the Conversate mode on the glasses. The display returns to the
  /// dashboard or idle state. A new session starts automatically on the next
  /// [show], [showAiResponse], or other display call.
  ///
  /// ```dart
  /// await g2.display.stop();
  /// ```
  Future<void> stop() async {
    _stopConversateHeartbeat();
    _conversateInitSent = false;
    if (!_g2.isConnected) return;
    try {
      await _g2._send(Display.buildConversateStop(
        _g2._nextSeq(), _g2._nextMsgId(),
      ));
    } catch (_) {
      // BLE may have dropped between isConnected check and write
    }
  }

  /// Pause the Conversate session without ending it.
  ///
  /// Mic streaming stops but the session stays alive. Call [resume] to continue.
  /// Matches the Even app's "pause" button behavior.
  ///
  /// ```dart
  /// await g2.display.pause();
  /// // ... later ...
  /// await g2.display.resume();
  /// ```
  Future<void> pause() async {
    _stopConversateHeartbeat();
    if (!_g2.isConnected) return;
    try {
      await _g2._send(Display.buildConversatePause(
        _g2._nextSeq(), _g2._nextMsgId(),
      ));
    } catch (_) {}
  }

  /// Resume a paused Conversate session.
  ///
  /// Matches the Even app's "continue" button. Re-sends the display config.
  ///
  /// ```dart
  /// await g2.display.resume();
  /// ```
  Future<void> resume() async {
    if (!_g2.isConnected) return;
    try {
      await _g2._send(Display.buildConversateContinue(
        _g2._nextSeq(), _g2._nextMsgId(),
      ));
      _startConversateHeartbeat();
    } catch (_) {}
  }

  /// Keep the display session alive during long pauses.
  ///
  /// The glasses automatically close the display after a period of inactivity.
  /// Call this periodically (e.g. every 15 seconds) if your app has long gaps
  /// between display updates.
  ///
  /// ```dart
  /// // While waiting for a slow API response:
  /// await g2.display.heartbeat();
  /// ```
  Future<void> heartbeat() async {
    _g2._ensureConnected();
    await _g2._send(Display.buildConversateHeartbeat(_g2._nextSeq(), _g2._nextMsgId()));
  }

  Future<void> _initConversate({String? title}) async {
    _g2._ensureConnected();
    if (!_conversateInitSent) {
      final response = await _g2._sendAndWait(
        Display.buildConversateInit(_g2._nextSeq(), _g2._nextMsgId(), title: title),
        responseSvcHi: 0x0B,
        responseSvcLo: 0x00,
        timeout: const Duration(seconds: 3),
      );
      if (response == null) {
        await Future.delayed(const Duration(milliseconds: 1000));
      }
      _conversateInitSent = true;
      // Start keepalive heartbeat automatically when a session begins
      _startConversateHeartbeat();
    }
  }

  void _reset() {
    _conversateInitSent = false;
    _stopConversateHeartbeat();
  }
}

// =============================================================================
// G2Mic — microphone controller
// =============================================================================

/// Controls the glasses microphone for audio recording.
///
/// Audio arrives as encoded packets from the glasses. For decoded audio
/// (PCM/WAV), provide a decoder via [setDecoder].
///
/// Quick start:
/// ```dart
/// // Simple timed recording
/// final packets = await g2.mic.record(Duration(seconds: 5));
///
/// // Manual start/stop
/// await g2.mic.start();
/// // ... do something ...
/// final packets = await g2.mic.stop();
///
/// // Convert to WAV (requires setDecoder)
/// final wav = g2.mic.toWav(packets);
/// ```
class G2Mic {
  final EvenG2 _g2;
  bool _active = false;
  final List<Uint8List> _recordingBuffer = [];
  StreamSubscription? _recordingSub;

  G2Mic._(this._g2);

  /// Whether the microphone is currently recording.
  bool get isActive => _active;

  /// Number of audio packets received since [start] was called.
  int get packetCount => _g2._audioHandler.packetCount;

  /// Estimated duration of audio recorded since [start] was called.
  ///
  /// ```dart
  /// await g2.mic.start();
  /// await Future.delayed(Duration(seconds: 3));
  /// print('Recorded ${g2.mic.recordingDuration.inSeconds}s');
  /// ```
  Duration get recordingDuration => Duration(
    milliseconds: packetCount * AudioFrame.framesPerPacket * AudioFrame.frameDurationMs,
  );

  /// Provide an audio decoder for PCM/WAV output.
  ///
  /// The SDK does not bundle any audio codec. You supply a function that
  /// takes a single encoded audio frame (40 bytes) and returns decoded
  /// PCM samples (Int16List of 160 samples, 16-bit signed, 16 kHz mono).
  ///
  /// ```dart
  /// g2.mic.setDecoder((encodedFrame) {
  ///   return myCodecLib.decode(encodedFrame); // returns Int16List
  /// });
  /// ```
  void setDecoder(Lc3DecoderCallback decoder) => _g2._audioHandler.setDecoder(decoder);

  /// Listen for decoded PCM audio samples. Requires [setDecoder].
  ///
  /// Each callback receives 160 samples of 16-bit signed PCM (10 ms of audio).
  ///
  /// ```dart
  /// g2.mic.onPcm((samples) {
  ///   // samples is Int16List, 160 values, 16 kHz mono
  ///   myBuffer.addAll(samples);
  /// });
  /// ```
  StreamSubscription<Int16List> onPcm(void Function(Int16List) callback) {
    return _g2._audioHandler.pcmStream.listen(callback);
  }

  /// Decoded PCM audio stream. Requires [setDecoder].
  ///
  /// Emits Int16List of 160 samples per event (~every 10 ms).
  /// Use with StreamBuilder or other stream consumers.
  Stream<Int16List> get pcmStream => _g2._audioHandler.pcmStream;

  /// Raw audio packet stream for forwarding or custom processing.
  ///
  /// Each packet is 205 bytes containing multiple encoded audio frames.
  /// Emits approximately 20 times per second.
  Stream<Uint8List> get packetStream => _g2._audioHandler.rawPacketStream;

  /// Start recording audio from the glasses microphone.
  ///
  /// Audio begins streaming immediately. Listen via [onPcm], [pcmStream],
  /// [packetStream], or [levelStream]. Call [stop] to end recording and
  /// retrieve the captured packets.
  ///
  /// ```dart
  /// await g2.mic.start();
  /// // Audio is now streaming...
  /// final packets = await g2.mic.stop();
  /// ```
  ///
  /// Set [raw] to true to skip the Conversate display init — use this when
  /// the mic is needed during a Dashboard AI session (Hey Even flow) where
  /// Conversate mode would conflict.
  Future<void> start({bool raw = false}) async {
    _g2._ensureConnected();
    if (_active) return;

    // Conversate init activates the mic in normal display mode.
    // Skip it in raw mode (e.g. during Dashboard AI sessions).
    if (!raw) {
      await _g2.display._initConversate();
    }

    _g2._audioHandler.resetCounter();
    _g2._micSubscription = _g2._transport.micStream.listen(_g2._audioHandler.processPacket);
    await _g2._transport.subscribeMic();
    _active = true;

    // Start buffering for stop() return value
    _recordingBuffer.clear();
    _recordingSub = _g2._audioHandler.rawPacketStream.listen((pkt) => _recordingBuffer.add(pkt));
  }

  /// Audio volume level stream (0.0 to 1.0) for VU meter display.
  ///
  /// Emits approximately 20 values per second while the mic is active.
  /// Values are approximate -- suitable for visual indicators, not
  /// precise audio analysis.
  ///
  /// ```dart
  /// g2.mic.levelStream.listen((level) {
  ///   print('Volume: ${(level * 100).toInt()}%');
  /// });
  /// ```
  Stream<double> get levelStream => _g2._audioHandler.rawPacketStream.map((pkt) {
    if (pkt.length < 205) return 0.0;
    // Byte 200 is the audio energy indicator (0-139 range, higher = louder)
    final energy = pkt[200];
    return (energy / 80.0).clamp(0.0, 1.0);
  });

  /// Stop recording and return all captured audio packets.
  ///
  /// Returns the raw packets captured since [start] was called.
  /// Pass these to [toWav] to get a WAV file, or to [toEncodedFrames]
  /// to extract the raw encoded audio data.
  ///
  /// ```dart
  /// final packets = await g2.mic.stop();
  /// print('Got ${packets.length} packets');
  /// ```
  Future<List<Uint8List>> stop() async {
    // Safe to call when not active or disconnected — no-op.
    if (!_active) return List.from(_recordingBuffer);
    await _recordingSub?.cancel();
    _recordingSub = null;
    await _g2._micSubscription?.cancel();
    _g2._micSubscription = null;
    try {
      await _g2._transport.unsubscribeMic();
    } catch (_) {
      // BLE may have dropped already
    }
    _active = false;
    return List.from(_recordingBuffer);
  }

  /// Record audio for a fixed duration and return the captured packets.
  ///
  /// Convenience method that calls [start], waits for [duration], then
  /// calls [stop]. Returns the same packet list as [stop].
  ///
  /// ```dart
  /// final packets = await g2.mic.record(Duration(seconds: 10));
  /// final wav = g2.mic.toWav(packets);
  /// ```
  Future<List<Uint8List>> record(Duration duration) async {
    await start();
    await Future.delayed(duration);
    return stop();
  }

  /// Convert captured packets to WAV audio bytes. Requires [setDecoder].
  ///
  /// Returns null if no decoder has been set or if decoding fails.
  ///
  /// ```dart
  /// final packets = await g2.mic.stop();
  /// final wav = g2.mic.toWav(packets);
  /// if (wav != null) {
  ///   // Save to file, send to API, etc.
  /// }
  /// ```
  Uint8List? toWav(List<Uint8List> packets) => _g2._audioHandler.packetsToWav(packets);

  /// Extract raw encoded audio frames from captured packets.
  ///
  /// Returns the concatenated encoded frames without any decoding.
  /// Useful for saving raw audio to process later with external tools.
  ///
  /// ```dart
  /// final packets = await g2.mic.stop();
  /// final rawFrames = g2.mic.toEncodedFrames(packets);
  /// ```
  Uint8List toEncodedFrames(List<Uint8List> packets) => Audio.extractAllFrames(packets);
}

// =============================================================================
// G2Settings — device settings controller
// =============================================================================

/// Controls glasses device settings.
///
/// ```dart
/// await g2.settings.wearDetection(true);
/// ```
class G2Settings {
  final EvenG2 _g2;

  G2Settings._(this._g2);

  /// Toggle the wear detection sensor on the glasses.
  ///
  /// When enabled, the glasses detect when they are put on or taken off.
  ///
  /// ```dart
  /// await g2.settings.wearDetection(true);   // enable
  /// await g2.settings.wearDetection(false);  // disable
  /// ```
  Future<void> wearDetection(bool enabled) async {
    _g2._ensureConnected();
    await _g2._send(Settings.buildInitSync(_g2._nextSeq(), _g2._nextMsgId()));
    await Future.delayed(const Duration(milliseconds: 300));
    await _g2._send(Settings.buildWearDetection(_g2._nextSeq(), _g2._nextMsgId(), enabled));
  }
}

// =============================================================================
// G2Hub — EvenHub container display controller
// =============================================================================

/// Controls the custom layout display system for rich UI on the glasses.
///
/// Create pages with positioned text, image, and list containers that
/// support touch interaction. [NEEDS_CAPTURE] -- some features are
/// still being reverse-engineered.
///
/// ```dart
/// final layout = PageLayout(
///   textContainers: [
///     TextContainer(id: 0, x: 0, y: 0, width: 288, height: 50, content: 'Hello!'),
///   ],
/// );
/// await g2.hub.createPage(layout);
/// await g2.hub.updateText(0, 'Updated text');
/// await g2.hub.closePage();
/// ```
class G2Hub {
  final EvenG2 _g2;
  final _hubEventController = StreamController<HubEvent>.broadcast();
  final _imuController = StreamController<ImuData>.broadcast();

  G2Hub._(this._g2);

  /// Display a new page with the given layout on the glasses.
  Future<void> createPage(PageLayout layout) async {
    _g2._ensureConnected();
    await _g2._send(EvenHub.buildCreatePage(
      _g2._nextSeq(), _g2._nextMsgId(), layout,
    ));
  }

  /// Replace the current page layout while keeping the session open.
  Future<void> updatePage(PageLayout layout) async {
    _g2._ensureConnected();
    await _g2._send(EvenHub.buildRebuildPage(
      _g2._nextSeq(), _g2._nextMsgId(), layout,
    ));
  }

  /// Update the text content of a text container.
  ///
  /// [offset] and [length] allow partial text replacement.
  Future<void> updateText(int containerID, String content, {int? offset, int? length}) async {
    _g2._ensureConnected();
    await _g2._send(EvenHub.buildTextUpdate(
      _g2._nextSeq(), _g2._nextMsgId(), containerID, content,
      offset: offset, length: length,
    ));
  }

  /// Update the image data of an image container.
  ///
  /// [imageData] should be raw bitmap data matching the container dimensions.
  Future<void> updateImage(int containerID, Uint8List imageData) async {
    _g2._ensureConnected();
    await _g2._send(EvenHub.buildImageUpdate(
      _g2._nextSeq(), _g2._nextMsgId(), containerID, imageData,
    ));
  }

  /// Close the current page and return to the default glasses screen.
  ///
  /// When [askUser] is true, shows a confirmation dialog on the glasses
  /// before closing.
  Future<void> closePage({bool askUser = false}) async {
    _g2._ensureConnected();
    await _g2._send(EvenHub.buildShutdown(
      _g2._nextSeq(), _g2._nextMsgId(), exitMode: askUser ? 1 : 0,
    ));
  }

  /// Enable or disable motion sensor data from the glasses.
  ///
  /// When enabled, accelerometer and gyroscope data streams via [imuStream].
  /// [frequencyMs] sets the interval between readings (default 100 ms).
  Future<void> setImu(bool enabled, {int frequencyMs = 100}) async {
    _g2._ensureConnected();
    await _g2._send(EvenHub.buildImuControl(
      _g2._nextSeq(), _g2._nextMsgId(), enabled, frequencyMs: frequencyMs,
    ));
  }

  /// Stream of user interaction events (taps, scrolls) on page containers.
  ///
  /// ```dart
  /// g2.hub.events.listen((event) {
  ///   if (event.isClick) print('Clicked ${event.containerName}');
  ///   if (event.isScroll) print('Scrolled');
  /// });
  /// ```
  Stream<HubEvent> get events => _hubEventController.stream;

  /// Stream of motion sensor data. Enable with [setImu] first.
  Stream<ImuData> get imuStream => _imuController.stream;

  /// Process an incoming packet and emit events if applicable.
  void _processPacket(G2Packet packet) {
    // EvenHub events come on service 0xE0 (confirmed) or 0x81 (legacy)
    if (packet.serviceHi != 0xE0 && packet.serviceHi != 0x81) return;
    if (packet.serviceLo != 0x00 && packet.serviceLo != 0x20) return;

    final event = EvenHub.parseEvent(packet.payload);
    if (event == null) return;

    _hubEventController.add(event);
    if (event.type == HubEventType.imuData && event.imuData != null) {
      _imuController.add(event.imuData!);
    }
  }

  void _dispose() {
    _hubEventController.close();
    _imuController.close();
  }
}

// =============================================================================
// G2Dashboard — AI session controller
// =============================================================================

/// Controls the AI conversation flow on the glasses via Dashboard service 0x07.
///
/// Listens for "Hey Even" wake word events and provides a clean stream-based
/// API. Handles the full protocol handshake (config + voice state acks).
///
/// ```dart
/// // Listen for "Hey Even" wake word
/// g2.dashboard.onWake.listen((_) async {
///   // Acknowledge and start the session
///   await g2.dashboard.ackWake();
///
///   // Start mic, run STT, stream transcription...
///   await g2.dashboard.sendTranscription("What is the weather?");
///   await g2.dashboard.transcriptionDone();
///   await g2.dashboard.showThinking();
///
///   // Stream AI response
///   await g2.dashboard.streamResponse("The weather today is sunny.");
///   await g2.dashboard.streamResponseDone();
///
///   // End session
///   await g2.dashboard.endSession();
/// });
/// ```
class G2Dashboard {
  final EvenG2 _g2;
  final _wakeController = StreamController<EvenAiEvent>.broadcast();
  final _eventController = StreamController<EvenAiEvent>.broadcast();
  bool _sessionActive = false;

  G2Dashboard._(this._g2);

  // -----------------------------------------------------------------------
  // Event streams
  // -----------------------------------------------------------------------

  /// Stream that fires when "Hey Even" wake word is detected.
  ///
  /// Only emits BOUNDARY voice state events (the actual wake word).
  /// Call [ackWake] to acknowledge and start the AI session.
  ///
  /// ```dart
  /// g2.dashboard.onWake.listen((event) {
  ///   print('Hey Even detected!');
  ///   g2.dashboard.ackWake();
  /// });
  /// ```
  Stream<EvenAiEvent> get onWake => _wakeController.stream;

  /// Stream of all AI events from the glasses (voice state, audio progress).
  ///
  /// For most use cases, prefer [onWake] which filters to just wake events.
  Stream<EvenAiEvent> get onEvent => _eventController.stream;

  // -----------------------------------------------------------------------
  // Session lifecycle
  // -----------------------------------------------------------------------

  /// Whether an AI session is currently active (between [ackWake] and [endSession]).
  bool get isSessionActive => _sessionActive;

  /// Acknowledge the wake word and start an AI session.
  ///
  /// Protocol from BLE capture_20260414_011807:
  ///   #6798  << EVT type=1 state=1  (LISTENING_STARTED — wake trigger)
  ///   #6914  >> CMD type=1 state=2  (LISTENING_ACTIVE — ack)
  ///   #7034  >> CMD type=9 f11={1}  (heartbeat — immediate)
  ///
  /// Call this immediately after receiving an [onWake] event.
  Future<void> ackWake() async {
    _g2._ensureConnected();
    _sessionActive = true;

    // 1. Confirm listening (state=2)
    await _g2._send(Dashboard.buildVoiceState(
      _g2._nextSeq(), _g2._nextMsgId(), Dashboard.stateListeningActive,
    ));

    // 2. Immediate heartbeat — capture always sends type=9 right after ack
    await _g2._send(Dashboard.buildHeartbeat(
      _g2._nextSeq(), _g2._nextMsgId(),
    ));
  }

  /// Send a config packet (type=10) to (re)activate AI listening.
  ///
  /// Used during init and at the start of back-to-back sessions.
  Future<void> sendConfig() async {
    _g2._ensureConnected();
    await _g2._send(Dashboard.buildConfig(_g2._nextSeq(), _g2._nextMsgId()));
  }

  /// Send a live transcription update (type=3).
  ///
  /// Call repeatedly with the full text so far as the user speaks.
  /// The glasses display the text in real-time.
  Future<void> sendTranscription(String text) async {
    _g2._ensureConnected();
    await _g2._send(Dashboard.buildTranscription(_g2._nextSeq(), _g2._nextMsgId(), text));
  }

  /// Signal that transcription is complete (type=2).
  ///
  /// Call after the final [sendTranscription] update, before [showThinking].
  Future<void> transcriptionDone() async {
    _g2._ensureConnected();
    await _g2._send(Dashboard.buildTranscriptionDone(_g2._nextSeq(), _g2._nextMsgId()));
  }

  /// Show the AI thinking indicator on the glasses (type=4).
  ///
  /// Call after [transcriptionDone], before [streamResponse].
  Future<void> showThinking() async {
    _g2._ensureConnected();
    await _g2._send(Dashboard.buildAiThinking(_g2._nextSeq(), _g2._nextMsgId()));
  }

  /// Stream an AI response text chunk to the glasses (type=5).
  ///
  /// Call multiple times as the AI generates its response. Each chunk
  /// is appended to the display. Call [streamResponseDone] after the last chunk.
  Future<void> streamResponse(String text) async {
    _g2._ensureConnected();
    await _g2._send(Dashboard.buildAiResponse(_g2._nextSeq(), _g2._nextMsgId(), text));
  }

  /// Signal that the AI response is complete (type=5, is_done=1).
  ///
  /// Tells the glasses no more response chunks are coming.
  Future<void> streamResponseDone() async {
    _g2._ensureConnected();
    await _g2._send(Dashboard.buildAiResponseDone(_g2._nextSeq(), _g2._nextMsgId()));
  }

  /// End the AI session (type=1, state=BOUNDARY).
  ///
  /// Signals the glasses to return to idle/dashboard mode.
  /// Call after [streamResponseDone] or to abort a session.
  Future<void> endSession() async {
    _sessionActive = false;
    _g2._ensureConnected();
    await _g2._send(Dashboard.buildVoiceState(
      _g2._nextSeq(), _g2._nextMsgId(), Dashboard.stateBoundary,
    ));
  }

  /// Send a session heartbeat (type=9).
  Future<void> heartbeat() async {
    _g2._ensureConnected();
    await _g2._send(Dashboard.buildHeartbeat(_g2._nextSeq(), _g2._nextMsgId()));
  }

  // -----------------------------------------------------------------------
  // Legacy aliases
  // -----------------------------------------------------------------------

  @Deprecated('Use ackWake() instead — now sends full handshake sequence')
  Future<void> init() async {
    _g2._ensureConnected();
    await _g2._send(Dashboard.buildConfig(_g2._nextSeq(), _g2._nextMsgId()));
  }

  @Deprecated('Use heartbeat() instead')
  Future<void> startSession() => heartbeat();

  @Deprecated('Use transcriptionDone() instead')
  Future<void> voiceDone() => transcriptionDone();

  // -----------------------------------------------------------------------
  // Internal
  // -----------------------------------------------------------------------

  /// Process an incoming packet and emit events if applicable.
  void _processPacket(G2Packet packet) {
    // Only care about 0x07-0x01 (event sub-service)
    if (packet.serviceHi != 0x07 || packet.serviceLo != 0x01) return;

    final event = Dashboard.parseEvent(packet.payload);
    if (event == null) return;

    _eventController.add(event);

    // Wake = glasses send LISTENING_STARTED (state=1) per capture_20260414_011807
    if (event.isListening) {
      _wakeController.add(event);
    }
  }

  void _dispose() {
    _sessionActive = false;
    _wakeController.close();
    _eventController.close();
  }
}

// =============================================================================
// G2RawEvent — for debugging
// =============================================================================

/// A low-level protocol event from the glasses, for debugging only.
///
/// Access via [EvenG2.debugEvents]. Not needed for normal use.
class G2RawEvent {
  final G2Packet packet;
  G2RawEvent({required this.packet});

  @override
  String toString() => 'G2RawEvent(${packet.toString()})';
}
