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

    final device = devices.firstWhere(
      (d) => d.name.contains('_L_'),
      orElse: () => devices.first,
    );
    await connect(device);
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

  // ---------------------------------------------------------------------------
  // Heartbeat — keeps the BLE connection alive
  // ---------------------------------------------------------------------------

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    // Send heartbeat every 10 seconds (glasses timeout after ~30s idle)
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 10), (_) async {
      if (_transport.isConnected && _authenticated) {
        try {
          final payload = <int>[0x08, 0x0E, 0x10, ...Varint.encode(_nextMsgId()), 0x6A, 0x00];
          await _send(PacketBuilder.build(
            seq: _nextSeq(), serviceHi: 0x80, serviceLo: 0x00, payload: payload,
          ));
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

  G2Display._(this._g2);

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

  /// Display an AI response with a title and body.
  ///
  /// Shows a formatted card on the glasses with a bold title and body text.
  /// Use [isDone] = false while streaming the response, then send the final
  /// version with [isDone] = true.
  ///
  /// ```dart
  /// await g2.display.showAiResponse(
  ///   title: "Weather in Geneva",
  ///   body: "Currently 18°C, partly cloudy. High of 22°C expected.",
  /// );
  /// ```
  Future<void> showAiResponse({
    required String title,
    required String body,
    int icon = Display.iconAi,
    bool isDone = true,
  }) async {
    await _initConversate();
    await _g2._send(Display.buildAiResponse(
      _g2._nextSeq(), _g2._nextMsgId(),
      icon: icon, title: title, body: body, isDone: isDone,
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
    _g2._ensureConnected();
    await _g2._send(Display.buildConversateStop(
      _g2._nextSeq(), _g2._nextMsgId(),
    ));
    _conversateInitSent = false;
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
    }
  }

  void _reset() => _conversateInitSent = false;
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
  Future<void> start() async {
    _g2._ensureConnected();
    if (_active) return;

    // Conversate init is required to activate the mic on the glasses
    await _g2.display._initConversate();

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
    await _recordingSub?.cancel();
    _recordingSub = null;
    await _g2._micSubscription?.cancel();
    _g2._micSubscription = null;
    await _g2._transport.unsubscribeMic();
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
    if (packet.serviceHi != 0x81 || packet.serviceLo != 0x20) return;

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
