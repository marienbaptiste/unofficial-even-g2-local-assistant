import 'dart:async';
import 'dart:typed_data';
import '../models/gesture_event.dart';
import '../transport/packet_builder.dart';

/// Gesture event parser for Even G2 glasses.
///
/// Gestures arrive on service 0x01-0x01 (glasses -> phone).
/// The gesture type is encoded in field6 of the protobuf payload:
///
/// - field6.field5: Touch gestures
///   - sub2=1 only -> single_tap
///   - sub1=1, sub2=2 -> double_tap
///   - sub1=2, sub2=3 -> scroll
///   - f1=3 -> long_press
///   - f1=4 -> both_hold
/// - field6.field3: STATE events (dashboard position after head tilt/scroll)
class Gestures {
  final _gestureController = StreamController<GestureEvent>.broadcast();

  /// Stream of parsed gesture events.
  Stream<GestureEvent> get gestureStream => _gestureController.stream;

  /// Process an incoming packet and emit gesture events if applicable.
  ///
  /// Only processes packets from service 0x01-0x01.
  void processPacket(G2Packet packet) {
    if (packet.serviceHi != 0x01 || packet.serviceLo != 0x01) return;

    final event = _parseGesture(packet.payload);
    if (event != null) {
      _gestureController.add(event);
    }
  }

  /// Parse gesture data from a protobuf payload.
  ///
  /// The payload uses a simplified protobuf-like encoding. We look for
  /// field6 (tag 0x32 = field6, wire type 2/length-delimited) and parse
  /// its sub-fields.
  GestureEvent? _parseGesture(Uint8List payload) {
    // Find field6 in the payload (tag = (6 << 3) | 2 = 0x32)
    final field6Data = _findField(payload, 0x32);
    if (field6Data == null) return null;

    // Check for field3 (STATE/position event): tag = (3 << 3) | 0 = 0x18
    final field3Value = _findVarintField(field6Data, 0x18);
    if (field3Value != null) {
      return GestureEvent(
        type: GestureType.headTilt,
        position: field3Value,
        rawPayload: payload,
      );
    }

    // Check for field5 (touch gesture): tag = (5 << 3) | 2 = 0x2A
    final field5Data = _findField(field6Data, 0x2A);
    if (field5Data == null) return null;

    // Parse sub-fields of field5
    // sub1 (field1): tag = (1 << 3) | 0 = 0x08
    // sub2 (field2): tag = (2 << 3) | 0 = 0x10
    final sub1 = _findVarintField(field5Data, 0x08);
    final sub2 = _findVarintField(field5Data, 0x10);

    GestureType type;
    if (sub1 == 3) {
      type = GestureType.longPress;
    } else if (sub1 == 4) {
      type = GestureType.bothHold;
    } else if (sub1 == 1 && sub2 == 2) {
      type = GestureType.doubleTap;
    } else if (sub1 == 2 && sub2 == 3) {
      type = GestureType.scroll;
    } else if (sub2 == 1 && (sub1 == null || sub1 == 0)) {
      type = GestureType.singleTap;
    } else {
      type = GestureType.unknown;
    }

    return GestureEvent(
      type: type,
      rawPayload: payload,
    );
  }

  /// Find a length-delimited field in protobuf-like data.
  /// Returns the field content bytes, or null if not found.
  List<int>? _findField(List<int> data, int tag) {
    int i = 0;
    while (i < data.length) {
      if (data[i] == tag && i + 1 < data.length) {
        // Next byte(s) are the length (varint)
        final (len, consumed) = Varint.decode(data, i + 1);
        final start = i + 1 + consumed;
        if (start + len <= data.length) {
          return data.sublist(start, start + len);
        }
      }
      i++;
    }
    return null;
  }

  /// Find a varint field value in protobuf-like data.
  /// Returns the decoded varint value, or null if not found.
  int? _findVarintField(List<int> data, int tag) {
    int i = 0;
    while (i < data.length) {
      if (data[i] == tag && i + 1 < data.length) {
        final (value, _) = Varint.decode(data, i + 1);
        return value;
      }
      i++;
    }
    return null;
  }

  /// Dispose streams.
  void dispose() {
    _gestureController.close();
  }
}
