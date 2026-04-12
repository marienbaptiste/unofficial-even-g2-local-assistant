import 'dart:convert';
import 'dart:typed_data';
import '../transport/packet_builder.dart';
import '../models/container.dart';
import '../models/evenhub_event.dart';

/// EvenHub protocol for Even G2 glasses.
///
/// Controls the container-based display system via service 0xE0-0x20.
/// EvenHub allows creating custom page layouts with text, image, and
/// list containers that support touch interaction.
///
/// CONFIRMED (2026-04-12): Service 0xE0 with command IDs in field 1,
/// magicRandom in field 2, and command-specific payloads in fields 3-18.
/// Audio control (mic start/stop) is EvenHub Cmd=15, field 18.
class EvenHub {
  // Confirmed command IDs (field 1 of EvenHub wrapper)
  static const int cmdCreatePage = 0;
  static const int cmdDeviceEvent = 2;   // glasses → phone
  static const int cmdImageUpdate = 3;
  static const int cmdTextUpdate = 5;
  static const int cmdRebuildPage = 7;
  static const int cmdShutdown = 9;
  static const int cmdHeartbeat = 12;
  static const int cmdAudioControl = 15;
  // ---------------------------------------------------------------------------
  // Page lifecycle
  // ---------------------------------------------------------------------------

  /// Build a createStartUpPageContainer packet (Cmd=0, field 3).
  ///
  /// Creates a new EvenHub page with the given container layout.
  /// Service 0xE0-0x20. CONFIRMED field layout from capture analysis.
  static Uint8List buildCreatePage(int seq, int msgId, PageLayout layout) {
    final containerBytes = _encodePageLayout(layout);
    final msgIdVarint = Varint.encode(msgId);

    final payload = <int>[
      0x08, cmdCreatePage, // field1 = cmd (0=create)
      0x10, ...msgIdVarint, // field2 = magicRandom
      0x1A, ...Varint.encode(containerBytes.length), ...containerBytes, // field3 = container data
    ];

    return PacketBuilder.build(
      seq: seq, serviceHi: 0xE0, serviceLo: 0x20, payload: payload,
    );
  }

  /// Build a rebuildPageContainer packet (Cmd=7, field 7).
  ///
  /// Replaces the current page layout with a new one without shutting down.
  static Uint8List buildRebuildPage(int seq, int msgId, PageLayout layout) {
    final containerBytes = _encodePageLayout(layout);
    final msgIdVarint = Varint.encode(msgId);

    final payload = <int>[
      0x08, cmdRebuildPage, // field1 = cmd (7=rebuild)
      0x10, ...msgIdVarint, // field2 = magicRandom
      0x3A, ...Varint.encode(containerBytes.length), ...containerBytes, // field7 = container data
    ];

    return PacketBuilder.build(
      seq: seq, serviceHi: 0xE0, serviceLo: 0x20, payload: payload,
    );
  }

  /// Build a shutDownPageContainer packet (Cmd=9, field 11).
  ///
  /// [exitMode] — 0: immediate, 1: ask user confirmation.
  static Uint8List buildShutdown(int seq, int msgId, {int exitMode = 0}) {
    final msgIdVarint = Varint.encode(msgId);
    final field11 = <int>[0x08, exitMode]; // ShutDownContainer.exitMode

    final payload = <int>[
      0x08, cmdShutdown, // field1 = cmd (9=shutdown)
      0x10, ...msgIdVarint, // field2 = magicRandom
      0x5A, ...Varint.encode(field11.length), ...field11, // field11 = ShutDownContainer
    ];

    return PacketBuilder.build(
      seq: seq, serviceHi: 0xE0, serviceLo: 0x20, payload: payload,
    );
  }

  // ---------------------------------------------------------------------------
  // Container updates
  // ---------------------------------------------------------------------------

  /// Build a textContainerUpgrade packet (Cmd=5, field 9).
  ///
  /// Updates the text content of an existing text container.
  /// [offset] and [length] allow partial text replacement.
  /// CONFIRMED: field9 = {f1=containerID, f3=offset, f4=length, f5=content}
  static Uint8List buildTextUpdate(
    int seq,
    int msgId,
    int containerID,
    String content, {
    int? offset,
    int? length,
  }) {
    final msgIdVarint = Varint.encode(msgId);
    final contentBytes = utf8.encode(content);

    final innerFields = <int>[
      0x08, ...Varint.encode(containerID), // field1 = containerID
    ];

    if (offset != null) {
      innerFields.addAll([0x18, ...Varint.encode(offset)]); // field3 = contentOffset
    }
    if (length != null) {
      innerFields.addAll([0x20, ...Varint.encode(length)]); // field4 = contentLength
    }

    innerFields.addAll([
      0x2A, ...Varint.encode(contentBytes.length), ...contentBytes, // field5 = content
    ]);

    final payload = <int>[
      0x08, cmdTextUpdate, // field1 = cmd (5=textUpdate)
      0x10, ...msgIdVarint, // field2 = magicRandom
      0x4A, ...Varint.encode(innerFields.length), ...innerFields, // field9 = TextContainerUpgrade
    ];

    return PacketBuilder.build(
      seq: seq, serviceHi: 0xE0, serviceLo: 0x20, payload: payload,
    );
  }

  /// Build an updateImageRawData packet (Cmd=3, field 5).
  ///
  /// Updates the image data of an existing image container.
  /// CONFIRMED: field5 = {f1=containerID, f3=sessionId, f4=totalSize,
  /// f5=compressMode(0), f6=fragmentIndex, f7=fragmentSize, f8=rawData}
  ///
  /// For images > 4096 bytes, call this multiple times with incrementing
  /// fragmentIndex. Use 200ms delay between fragments.
  static Uint8List buildImageUpdate(
    int seq,
    int msgId,
    int containerID,
    Uint8List imageData, {
    int sessionId = 0,
    int fragmentIndex = 0,
    int? totalSize,
  }) {
    final msgIdVarint = Varint.encode(msgId);
    final total = totalSize ?? imageData.length;

    final innerFields = <int>[
      0x08, ...Varint.encode(containerID), // field1 = containerID
      0x18, ...Varint.encode(sessionId), // field3 = mapSessionId
      0x20, ...Varint.encode(total), // field4 = mapTotalSize
      0x28, 0x00, // field5 = compressMode (0=uncompressed)
      0x30, ...Varint.encode(fragmentIndex), // field6 = mapFragmentIndex
      0x38, ...Varint.encode(imageData.length), // field7 = mapFragmentPacketSize
      0x42, ...Varint.encode(imageData.length), ...imageData, // field8 = mapRawData
    ];

    final payload = <int>[
      0x08, cmdImageUpdate, // field1 = cmd (3=imageUpdate)
      0x10, ...msgIdVarint, // field2 = magicRandom
      0x2A, ...Varint.encode(innerFields.length), ...innerFields, // field5 = ImageRawDataUpdate
    ];

    return PacketBuilder.build(
      seq: seq, serviceHi: 0xE0, serviceLo: 0x20, payload: payload,
    );
  }

  // ---------------------------------------------------------------------------
  // Audio & IMU control
  // ---------------------------------------------------------------------------

  /// Build an audioControl packet (Cmd=15, field 18).
  ///
  /// Enables or disables the glasses microphone.
  /// CONFIRMED: This is THE mic start/stop command.
  static Uint8List buildAudioControl(int seq, int msgId, bool enable) {
    final msgIdVarint = Varint.encode(msgId);
    final field18 = <int>[0x08, enable ? 0x01 : 0x00]; // AudioCtrCmd.audioFuncEn

    final payload = <int>[
      0x08, cmdAudioControl, // field1 = cmd (15=audio)
      0x10, ...msgIdVarint, // field2 = magicRandom
      // field18 tag: (18 << 3) | 2 = 0x92 0x01
      0x92, 0x01, ...Varint.encode(field18.length), ...field18,
    ];

    return PacketBuilder.build(
      seq: seq, serviceHi: 0xE0, serviceLo: 0x20, payload: payload,
    );
  }

  /// Build an EvenHub heartbeat packet (Cmd=12, field 14).
  ///
  /// Sent every 5 seconds to keep the EvenHub session alive.
  static Uint8List buildHubHeartbeat(int seq, int msgId) {
    final msgIdVarint = Varint.encode(msgId);
    final field14 = <int>[]; // HeartBeatPacket — cnt is optional

    final payload = <int>[
      0x08, cmdHeartbeat, // field1 = cmd (12=heartbeat)
      0x10, ...msgIdVarint, // field2 = magicRandom
      0x72, ...Varint.encode(field14.length), ...field14, // field14 = HeartBeatPacket
    ];

    return PacketBuilder.build(
      seq: seq, serviceHi: 0xE0, serviceLo: 0x20, payload: payload,
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
    final msgIdVarint = Varint.encode(msgId);

    final freqVarint = Varint.encode(frequencyMs);
    final innerFields = <int>[
      0x08, enable ? 0x01 : 0x00, // field1 = enable
      0x10, ...freqVarint, // field2 = frequencyMs
    ];

    // IMU control — exact command ID TBD, using placeholder
    final payload = <int>[
      0x08, 0x10, // placeholder cmd for IMU
      0x10, ...msgIdVarint,
      0x1A, innerFields.length, ...innerFields,
    ];

    return PacketBuilder.build(
      seq: seq, serviceHi: 0xE0, serviceLo: 0x20, payload: payload,
    );
  }

  // ---------------------------------------------------------------------------
  // Event parsing
  // ---------------------------------------------------------------------------

  /// Parse an EvenHub event from a glasses notification payload.
  ///
  /// Returns null if the payload is not an EvenHub event.
  /// CONFIRMED: Cmd=2 (OS_NOTIFY_EVENT_TO_APP) in field 13 (SendDeviceEvent).
  /// field13.field1=ListEvent, field13.field2=TextEvent, field13.field3=SysEvent
  static HubEvent? parseEvent(Uint8List payload) {
    // Expected structure from service 0xE0-0x00 responses:
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
