import 'dart:typed_data';
import '../transport/packet_builder.dart';

/// Authentication protocol for Even G2 glasses.
///
/// The auth handshake consists of 7 packets sent to service 0x80-0x00 and 0x80-0x20.
/// Packets 3 and 7 include time sync with Unix timestamp and timezone offset
/// in quarter-hours from UTC.
class Auth {
  /// Build the 7-packet authentication sequence.
  ///
  /// [timestamp] - Unix timestamp (defaults to current time).
  /// [tzOffsetMinutes] - Timezone offset in minutes from UTC (defaults to local).
  static List<Uint8List> buildAuthPackets({
    int? timestamp,
    int? tzOffsetMinutes,
  }) {
    final ts = timestamp ?? (DateTime.now().millisecondsSinceEpoch ~/ 1000);
    final tsVarint = Varint.encode(ts);

    // Timezone in quarter-hours from UTC
    final tzMinutes = tzOffsetMinutes ?? DateTime.now().timeZoneOffset.inMinutes;
    final tzQuarterHours = tzMinutes ~/ 15;
    final tzVarint = Varint.encode(tzQuarterHours);

    final packets = <Uint8List>[];

    // Auth 1: Capability query (service 0x80-0x00)
    packets.add(_addCrc([
      0xAA, 0x21, 0x01, 0x0C, 0x01, 0x01, 0x80, 0x00,
      0x08, 0x04, 0x10, 0x0C, 0x1A, 0x04, 0x08, 0x01, 0x10, 0x04,
    ]));

    // Auth 2: Capability response request (service 0x80-0x20)
    packets.add(_addCrc([
      0xAA, 0x21, 0x02, 0x0A, 0x01, 0x01, 0x80, 0x20,
      0x08, 0x05, 0x10, 0x0E, 0x22, 0x02, 0x08, 0x02,
    ]));

    // Auth 3: Time sync (service 0x80-0x20)
    // field128 = { field1 = unix_timestamp, field2 = tz_quarter_hours }
    final payload3 = <int>[
      0x08, 0x80, 0x01, 0x10, 0x0F, 0x82, 0x08, 0x11, 0x08,
      ...tsVarint, 0x10, ...tzVarint,
    ];
    packets.add(_addCrc([
      0xAA, 0x21, 0x03, payload3.length + 2, 0x01, 0x01, 0x80, 0x20,
      ...payload3,
    ]));

    // Auth 4: Additional capability exchange (service 0x80-0x00)
    packets.add(_addCrc([
      0xAA, 0x21, 0x04, 0x0C, 0x01, 0x01, 0x80, 0x00,
      0x08, 0x04, 0x10, 0x10, 0x1A, 0x04, 0x08, 0x01, 0x10, 0x04,
    ]));

    // Auth 5: Additional capability exchange (service 0x80-0x00)
    packets.add(_addCrc([
      0xAA, 0x21, 0x05, 0x0C, 0x01, 0x01, 0x80, 0x00,
      0x08, 0x04, 0x10, 0x11, 0x1A, 0x04, 0x08, 0x01, 0x10, 0x04,
    ]));

    // Auth 6: Final capability (service 0x80-0x20)
    packets.add(_addCrc([
      0xAA, 0x21, 0x06, 0x0A, 0x01, 0x01, 0x80, 0x20,
      0x08, 0x05, 0x10, 0x12, 0x22, 0x02, 0x08, 0x01,
    ]));

    // Auth 7: Final time sync (service 0x80-0x20, same format as auth 3)
    final payload7 = <int>[
      0x08, 0x80, 0x01, 0x10, 0x13, 0x82, 0x08, 0x11, 0x08,
      ...tsVarint, 0x10, ...tzVarint,
    ];
    packets.add(_addCrc([
      0xAA, 0x21, 0x07, payload7.length + 2, 0x01, 0x01, 0x80, 0x20,
      ...payload7,
    ]));

    return packets;
  }

  static Uint8List _addCrc(List<int> headerAndPayload) {
    return PacketBuilder.addCrc(headerAndPayload);
  }
}
