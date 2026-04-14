import 'dart:async';
import 'dart:typed_data';
import 'package:universal_ble/universal_ble.dart';
import '../models/g2_device.dart';

/// BLE UUID constants for Even G2 glasses.
class G2Uuids {
  static const String _base = '00002760-08c2-11e1-9073-0e8ac72e';

  /// Service UUIDs (containers)
  static const String serviceMain = '${_base}5450';
  static const String serviceDisplay = '${_base}6450';
  static const String serviceThird = '${_base}7450';

  /// Write characteristic (phone -> glasses commands)
  static const String charWrite = '${_base}5401';

  /// Notify characteristic (glasses -> phone responses)
  static const String charNotify = '${_base}5402';

  /// Display write characteristic
  static const String charDisplayWrite = '${_base}6401';

  /// Mic audio notify characteristic (LC3 frames, streams on subscribe)
  static const String charMicNotify = '${_base}6402';

  /// Third channel write
  static const String charThirdWrite = '${_base}7401';

  /// Third channel notify
  static const String charThirdNotify = '${_base}7402';
}

/// BLE transport layer for Even G2 glasses.
///
/// Handles scanning, connecting, GATT characteristic discovery,
/// and raw read/write operations using universal_ble.
class BleTransport {
  String? _deviceId;      // Primary device (left ear)
  String? _deviceIdRight; // Secondary device (right ear)

  // Discovered service UUIDs (may differ in case from constants)
  String? _svcMain;
  String? _svcDisplay;

  final _notifyController = StreamController<List<int>>.broadcast();
  final _micController = StreamController<List<int>>.broadcast();
  final _connectionController = StreamController<bool>.broadcast();

  bool _isConnected = false;

  /// Whether currently connected to a device.
  bool get isConnected => _isConnected;

  /// Stream of incoming packets from the notify characteristic (5402).
  Stream<List<int>> get notifyStream => _notifyController.stream;

  /// Stream of raw mic audio packets from 6402.
  Stream<List<int>> get micStream => _micController.stream;

  /// Stream of connection state changes.
  Stream<bool> get connectionStream => _connectionController.stream;

  /// Scan for Even G2 devices.
  static Future<List<G2Device>> scan({Duration timeout = const Duration(seconds: 10)}) async {
    final devices = <G2Device>[];
    final completer = Completer<List<G2Device>>();

    UniversalBle.onScanResult = (BleDevice device) {
      final name = device.name;
      if (name != null && name.contains('G2')) {
        final existing = devices.indexWhere((d) => d.id == device.deviceId);
        if (existing == -1) {
          devices.add(G2Device(
            id: device.deviceId,
            name: name,
            rssi: device.rssi ?? -100,
            isLeft: name.contains('_L'),
          ));
        }
      }
    };

    await UniversalBle.startScan();
    await Future.delayed(timeout);
    await UniversalBle.stopScan();

    return devices;
  }

  /// Connect to a G2 device and discover characteristics.
  Future<void> connect(G2Device device) async {
    _deviceId = device.id;

    // Set up connection change callback
    UniversalBle.onConnectionChange = (String deviceId, bool connected, [String? error]) {
      if (deviceId != _deviceId) return;
      _isConnected = connected;
      _connectionController.add(connected);
    };

    // Set up value change callback — routes data to appropriate stream
    UniversalBle.onValueChange = (String deviceId, String characteristicId, Uint8List value, [int? flags]) {
      if (deviceId != _deviceId) return;

      final charLower = characteristicId.toLowerCase();
      if (charLower.contains('6402')) {
        _micController.add(value);
      } else if (charLower.contains('5402') || charLower.contains('7402')) {
        _notifyController.add(value);
      }
    };

    await UniversalBle.connect(device.id);
    _isConnected = true;
    _connectionController.add(true);
    await Future.delayed(const Duration(seconds: 1));

    try {
      await UniversalBle.pair(device.id);
      await Future.delayed(const Duration(seconds: 1));
    } catch (_) {}

    // Discover services (retry up to 3 times)
    List<BleService> services = [];
    for (int attempt = 0; attempt < 3; attempt++) {
      try {
        services = await UniversalBle.discoverServices(device.id);
        if (services.isNotEmpty) break;
      } catch (e) {
        if (attempt < 2) {
          await Future.delayed(const Duration(seconds: 1));
        } else {
          throw Exception('Service discovery failed: $e');
        }
      }
    }

    // Find the actual service UUIDs from discovery (case-insensitive match)
    String? svcThird;
    for (final s in services) {
      final uuid = s.uuid.toLowerCase();
      if (uuid.contains('5450')) _svcMain = s.uuid;
      if (uuid.contains('6450')) _svcDisplay = s.uuid;
      if (uuid.contains('7450')) svcThird = s.uuid;
    }

    if (_svcMain == null) {
      throw Exception('G2 main service (5450) not found');
    }

    // 2 second delay after service discovery before subscribing (Windows fix)
    await Future.delayed(const Duration(seconds: 2));

    // Subscribe to main notify characteristic (5402)
    for (int attempt = 0; attempt < 3; attempt++) {
      try {
        await UniversalBle.setNotifiable(
          device.id, _svcMain!, G2Uuids.charNotify, BleInputProperty.notification,
        );
        break;
      } catch (e) {
        if (attempt < 2) {
          await Future.delayed(const Duration(seconds: 1));
        } else {
          throw Exception('Cannot subscribe to notify characteristic: $e');
        }
      }
    }

    // Subscribe to third channel notify (7402)
    if (svcThird != null) {
      try {
        await UniversalBle.setNotifiable(
          device.id, svcThird, G2Uuids.charThirdNotify, BleInputProperty.notification,
        );
      } catch (_) {}
    }
  }

  /// Connect a secondary device (right ear) and subscribe to its notifications.
  /// The onValueChange callback already accepts data from any device.
  Future<void> connectSecondary(G2Device device) async {
    _deviceIdRight = device.id;

    // Update callback to accept both devices
    final primaryId = _deviceId;
    final rightId = device.id;
    UniversalBle.onValueChange = (String deviceId, String characteristicId, Uint8List value, [int? flags]) {
      if (deviceId != primaryId && deviceId != rightId) return;
      final charLower = characteristicId.toLowerCase();
      if (charLower.contains('6402')) {
        _micController.add(value);
      } else if (charLower.contains('5402') || charLower.contains('7402')) {
        _notifyController.add(value);
      }
    };

    try {
      await UniversalBle.connect(device.id);
      await Future.delayed(const Duration(seconds: 2));

      final services = await UniversalBle.discoverServices(device.id);
      String? svcMain;
      for (final s in services) {
        if (s.uuid.toLowerCase().contains('5450')) svcMain = s.uuid;
      }
      if (svcMain != null) {
        await Future.delayed(const Duration(seconds: 1));
        await UniversalBle.setNotifiable(
          device.id, svcMain, G2Uuids.charNotify, BleInputProperty.notification,
        );
      }
    } catch (e) {
      // Right ear failed — continue with left only
      _deviceIdRight = null;
    }
  }

  /// Write to RIGHT ear (for commands that need the command role device).
  Future<void> writeRight(Uint8List data) async {
    if (_deviceIdRight == null) {
      // Fall back to primary if no right ear
      return write(data);
    }
    await UniversalBle.writeValue(
      _deviceIdRight!, _svcMain!, G2Uuids.charWrite, data, BleOutputProperty.withoutResponse,
    );
  }

  /// Subscribe to mic audio stream (6402).
  /// Subscribing automatically starts the mic stream on the glasses.
  Future<void> subscribeMic() async {
    if (_deviceId == null || _svcDisplay == null) {
      throw Exception('Mic characteristic not found — display service not discovered');
    }
    await UniversalBle.setNotifiable(
      _deviceId!, _svcDisplay!, G2Uuids.charMicNotify, BleInputProperty.notification,
    );
  }

  /// Unsubscribe from mic audio stream.
  Future<void> unsubscribeMic() async {
    if (_deviceId == null || _svcDisplay == null) return;
    try {
      await UniversalBle.setNotifiable(
        _deviceId!, _svcDisplay!, G2Uuids.charMicNotify, BleInputProperty.disabled,
      );
    } catch (_) {}
  }

  /// Write data to the main write characteristic (5401).
  Future<void> write(Uint8List data) async {
    if (_deviceId == null || _svcMain == null) {
      throw Exception('Not connected');
    }
    await UniversalBle.writeValue(
      _deviceId!, _svcMain!, G2Uuids.charWrite, data, BleOutputProperty.withoutResponse,
    );
  }

  /// Write data to the display write characteristic (6401).
  Future<void> writeDisplay(Uint8List data) async {
    if (_deviceId == null || _svcDisplay == null) {
      throw Exception('Display characteristic not found');
    }
    await UniversalBle.writeValue(
      _deviceId!, _svcDisplay!, G2Uuids.charDisplayWrite, data, BleOutputProperty.withoutResponse,
    );
  }

  /// Disconnect from the device.
  Future<void> disconnect() async {
    if (_deviceId != null) {
      try {
        // Try to unsubscribe before disconnecting
        try {
          await UniversalBle.setNotifiable(
            _deviceId!, _svcMain ?? G2Uuids.serviceMain, G2Uuids.charNotify, BleInputProperty.disabled,
          );
        } catch (_) {}
        await unsubscribeMic();
        await UniversalBle.disconnect(_deviceId!);
      } catch (_) {}
    }

    _deviceId = null;
    _svcMain = null;
    _svcDisplay = null;
    _isConnected = false;
    _connectionController.add(false);
  }

  /// Dispose all streams.
  void dispose() {
    _notifyController.close();
    _micController.close();
    _connectionController.close();
  }
}
