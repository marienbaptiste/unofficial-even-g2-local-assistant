import 'dart:typed_data';
import '../transport/packet_builder.dart';
import '../models/container.dart';
import '../models/evenhub_event.dart';

/// EvenHub protocol for Even G2 glasses.
///
/// Controls the container-based display system via service 0x81-0x20.
/// EvenHub allows creating custom page layouts with text, image, and
/// list containers that support touch interaction.
///
/// [NEEDS_CAPTURE] Protobuf field numbers are from the official SDK model
/// but exact wire encoding needs BLE capture verification.
class EvenHub {
  // ---------------------------------------------------------------------------
  // Page lifecycle
  // ---------------------------------------------------------------------------

  /// Build a createStartUpPageContainer packet.
  ///
  /// Creates a new EvenHub page with the given container layout.
  /// Service 0x81-0x20.
  static Uint8List buildCreatePage(int seq, int msgId, PageLayout layout) {
    // [NEEDS_CAPTURE] Protobuf field numbers are from the official SDK model
    // but exact wire encoding needs BLE capture verification.
    // Container properties map to PB fields:
    // containerID -> field tag TBD
    // xPosition -> field tag TBD
    // yPosition -> field tag TBD
    // width -> field tag TBD
    // height -> field tag TBD
    // borderWidth -> field tag TBD
    // borderColor -> field tag TBD
    // borderRadius -> field tag TBD
    // paddingLength -> field tag TBD
    // content -> field tag TBD (length-delimited)
    // captureEvents -> field tag TBD

    final containerBytes = _encodePageLayout(layout);

    // Outer wrapper: field1=commandType(1=create), field2=msgId, field3=containerData
    final msgIdVarint = Varint.encode(msgId);
    final commandType = 0x01; // create

    final payload = <int>[
      0x08, commandType, // field1 = commandType
      0x10, ...msgIdVarint, // field2 = msgId
      0x1A, containerBytes.length, ...containerBytes, // field3 = container data
    ];

    return PacketBuilder.build(
      seq: seq, serviceHi: 0x81, serviceLo: 0x20, payload: payload,
    );
  }

  /// Build a rebuildPageContainer packet.
  ///
  /// Replaces the current page layout with a new one without shutting down.
  static Uint8List buildRebuildPage(int seq, int msgId, PageLayout layout) {
    // [NEEDS_CAPTURE] Same structure as createPage but with commandType=2 (rebuild)
    final containerBytes = _encodePageLayout(layout);
    final msgIdVarint = Varint.encode(msgId);
    final commandType = 0x02; // rebuild

    final payload = <int>[
      0x08, commandType,
      0x10, ...msgIdVarint,
      0x1A, containerBytes.length, ...containerBytes,
    ];

    return PacketBuilder.build(
      seq: seq, serviceHi: 0x81, serviceLo: 0x20, payload: payload,
    );
  }

  /// Build a shutDownPageContainer packet.
  ///
  /// [exitMode] — 0: immediate, 1: ask user confirmation.
  static Uint8List buildShutdown(int seq, int msgId, {int exitMode = 0}) {
    // [NEEDS_CAPTURE] exitMode field tag TBD
    final msgIdVarint = Varint.encode(msgId);
    final commandType = 0x03; // shutdown

    final payload = <int>[
      0x08, commandType,
      0x10, ...msgIdVarint,
      0x1A, 0x02, 0x08, exitMode, // field3 = {field1: exitMode}
    ];

    return PacketBuilder.build(
      seq: seq, serviceHi: 0x81, serviceLo: 0x20, payload: payload,
    );
  }

  // ---------------------------------------------------------------------------
  // Container updates
  // ---------------------------------------------------------------------------

  /// Build a textContainerUpgrade packet.
  ///
  /// Updates the text content of an existing text container.
  /// [offset] and [length] allow partial text replacement.
  static Uint8List buildTextUpdate(
    int seq,
    int msgId,
    int containerID,
    String content, {
    int? offset,
    int? length,
  }) {
    // [NEEDS_CAPTURE] Protobuf field tags for text update TBD
    final msgIdVarint = Varint.encode(msgId);
    final contentBytes = content.codeUnits;
    final commandType = 0x04; // textUpdate

    final innerFields = <int>[
      0x08, containerID, // field1 = containerID
      0x12, contentBytes.length, ...contentBytes, // field2 = content (length-delimited)
    ];

    if (offset != null) {
      innerFields.addAll([0x18, ...Varint.encode(offset)]); // field3 = offset
    }
    if (length != null) {
      innerFields.addAll([0x20, ...Varint.encode(length)]); // field4 = length
    }

    final payload = <int>[
      0x08, commandType,
      0x10, ...msgIdVarint,
      0x1A, innerFields.length, ...innerFields,
    ];

    return PacketBuilder.build(
      seq: seq, serviceHi: 0x81, serviceLo: 0x20, payload: payload,
    );
  }

  /// Build an updateImageRawData packet.
  ///
  /// Updates the image data of an existing image container.
  /// [imageData] should be raw bitmap data matching the container dimensions.
  static Uint8List buildImageUpdate(
    int seq,
    int msgId,
    int containerID,
    Uint8List imageData,
  ) {
    // [NEEDS_CAPTURE] Protobuf field tags for image update TBD
    // Image data may need to be sent in multiple packets for large images.
    final msgIdVarint = Varint.encode(msgId);
    final commandType = 0x05; // imageUpdate

    final innerFields = <int>[
      0x08, containerID, // field1 = containerID
      0x12, ...Varint.encode(imageData.length), ...imageData, // field2 = imageData
    ];

    final payload = <int>[
      0x08, commandType,
      0x10, ...msgIdVarint,
      0x1A, ...Varint.encode(innerFields.length), ...innerFields,
    ];

    return PacketBuilder.build(
      seq: seq, serviceHi: 0x81, serviceLo: 0x20, payload: payload,
    );
  }

  // ---------------------------------------------------------------------------
  // Audio & IMU control
  // ---------------------------------------------------------------------------

  /// Build an audioControl packet for EvenHub mode.
  ///
  /// Enables or disables audio capture while in EvenHub mode.
  static Uint8List buildAudioControl(int seq, int msgId, bool enable) {
    // [NEEDS_CAPTURE] Audio control field tags TBD
    final msgIdVarint = Varint.encode(msgId);
    final commandType = 0x06; // audioControl

    final payload = <int>[
      0x08, commandType,
      0x10, ...msgIdVarint,
      0x1A, 0x02, 0x08, enable ? 0x01 : 0x00,
    ];

    return PacketBuilder.build(
      seq: seq, serviceHi: 0x81, serviceLo: 0x20, payload: payload,
    );
  }

  /// Build an imuControl packet.
  ///
  /// Enables or disables IMU sensor data streaming.
  /// [frequencyMs] sets the data rate (default 100ms between readings).
  static Uint8List buildImuControl(
    int seq,
    int msgId,
    bool enable, {
    int frequencyMs = 100,
  }) {
    // [NEEDS_CAPTURE] IMU control field tags TBD
    final msgIdVarint = Varint.encode(msgId);
    final commandType = 0x07; // imuControl

    final freqVarint = Varint.encode(frequencyMs);
    final innerFields = <int>[
      0x08, enable ? 0x01 : 0x00, // field1 = enable
      0x10, ...freqVarint, // field2 = frequencyMs
    ];

    final payload = <int>[
      0x08, commandType,
      0x10, ...msgIdVarint,
      0x1A, innerFields.length, ...innerFields,
    ];

    return PacketBuilder.build(
      seq: seq, serviceHi: 0x81, serviceLo: 0x20, payload: payload,
    );
  }

  // ---------------------------------------------------------------------------
  // Event parsing
  // ---------------------------------------------------------------------------

  /// Parse an EvenHub event from a glasses notification payload.
  ///
  /// Returns null if the payload is not an EvenHub event.
  static HubEvent? parseEvent(Uint8List payload) {
    // [NEEDS_CAPTURE] Event parsing field layout TBD
    // Expected structure from service 0x81-0x20 responses:
    // field1 = eventType (varint)
    // field2 = touchSource (varint)
    // field3 = containerID (varint)
    // field4 = containerName (length-delimited string)
    // field5 = selectedItemIndex (varint)
    // field6 = selectedItemName (length-delimited string)
    // field7 = imuData (sub-message with x, y, z as fixed32/float)

    if (payload.isEmpty) return null;

    try {
      int offset = 0;
      int? eventType;
      int? touchSource;
      int? containerID;
      String? containerName;
      int? selectedItemIndex;
      String? selectedItemName;
      ImuData? imuData;

      while (offset < payload.length) {
        if (offset >= payload.length) break;
        final tagByte = payload[offset];
        final fieldNumber = tagByte >> 3;
        final wireType = tagByte & 0x07;
        offset++;

        if (wireType == 0) {
          // Varint
          final (value, consumed) = Varint.decode(payload, offset);
          offset += consumed;

          switch (fieldNumber) {
            case 1: eventType = value; break;
            case 2: touchSource = value; break;
            case 3: containerID = value; break;
            case 5: selectedItemIndex = value; break;
          }
        } else if (wireType == 2) {
          // Length-delimited
          final (len, consumed) = Varint.decode(payload, offset);
          offset += consumed;

          if (offset + len > payload.length) break;

          switch (fieldNumber) {
            case 4:
              containerName = String.fromCharCodes(payload.sublist(offset, offset + len));
              break;
            case 6:
              selectedItemName = String.fromCharCodes(payload.sublist(offset, offset + len));
              break;
            case 7:
              imuData = _parseImuData(payload.sublist(offset, offset + len));
              break;
          }
          offset += len;
        } else {
          // Unknown wire type — skip
          break;
        }
      }

      if (eventType == null) return null;

      return HubEvent(
        type: HubEventType.fromValue(eventType),
        source: TouchSource.fromValue(touchSource ?? 0),
        containerID: containerID,
        containerName: containerName,
        selectedItemIndex: selectedItemIndex,
        selectedItemName: selectedItemName,
        imuData: imuData,
      );
    } catch (_) {
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  /// Encode a PageLayout into protobuf-like bytes.
  static List<int> _encodePageLayout(PageLayout layout) {
    // [NEEDS_CAPTURE] All container encoding field tags TBD
    final result = <int>[];

    // Encode text containers as repeated field1 sub-messages
    for (final tc in layout.textContainers) {
      final fields = <int>[
        0x08, tc.id, // containerID
        0x10, tc.x, // x
        0x18, tc.y, // y
        0x20, tc.width, // width (may need varint for >127)
        0x28, tc.height, // height
        0x30, tc.borderWidth,
        0x38, tc.borderColor,
        0x40, tc.borderRadius,
        0x48, tc.paddingLength,
        0x50, tc.captureEvents ? 0x01 : 0x00,
      ];

      if (tc.content != null) {
        final contentBytes = tc.content!.codeUnits;
        fields.addAll([
          0x5A, contentBytes.length, ...contentBytes,
        ]);
      }

      if (tc.name != null) {
        final nameBytes = tc.name!.codeUnits;
        fields.addAll([
          0x62, nameBytes.length, ...nameBytes,
        ]);
      }

      // Wrap as field1 (text container list)
      result.addAll([0x0A, fields.length, ...fields]);
    }

    // Encode image containers as repeated field2 sub-messages
    for (final ic in layout.imageContainers) {
      final fields = <int>[
        0x08, ic.id,
        0x10, ic.x,
        0x18, ic.y,
        0x20, ic.width,
        0x28, ic.height,
      ];

      if (ic.name != null) {
        final nameBytes = ic.name!.codeUnits;
        fields.addAll([0x32, nameBytes.length, ...nameBytes]);
      }

      result.addAll([0x12, fields.length, ...fields]);
    }

    // Encode list containers as repeated field3 sub-messages
    for (final lc in layout.listContainers) {
      final fields = <int>[
        0x08, lc.id,
        0x10, lc.x,
        0x18, lc.y,
        0x20, lc.width,
        0x28, lc.height,
        0x30, lc.borderWidth,
        0x38, lc.borderColor,
        0x40, lc.borderRadius,
        0x48, lc.paddingLength,
        0x50, lc.showSelectionBorder ? 0x01 : 0x00,
        0x58, lc.captureEvents ? 0x01 : 0x00,
      ];

      // Encode item names as repeated length-delimited field
      for (final itemName in lc.itemNames) {
        final nameBytes = itemName.codeUnits;
        fields.addAll([0x62, nameBytes.length, ...nameBytes]);
      }

      if (lc.itemWidth != null) {
        fields.addAll([0x68, ...Varint.encode(lc.itemWidth!)]);
      }

      if (lc.name != null) {
        final nameBytes = lc.name!.codeUnits;
        fields.addAll([0x72, nameBytes.length, ...nameBytes]);
      }

      result.addAll([0x1A, fields.length, ...fields]);
    }

    return result;
  }

  /// Parse IMU data from a protobuf sub-message.
  static ImuData? _parseImuData(Uint8List data) {
    // [NEEDS_CAPTURE] IMU data encoding TBD — likely 3x float (fixed32)
    if (data.length < 12) return null;

    final byteData = ByteData.sublistView(data);
    // Assuming little-endian float encoding
    try {
      // Skip field tags, read raw floats for now
      // Actual field layout needs capture verification
      final x = byteData.getFloat32(0, Endian.little);
      final y = byteData.getFloat32(4, Endian.little);
      final z = byteData.getFloat32(8, Endian.little);
      return ImuData(x: x, y: y, z: z);
    } catch (_) {
      return null;
    }
  }
}
