import 'dart:typed_data';
import 'crc.dart';

/// Varint encoding/decoding utilities for the G2 protobuf-like protocol.
class Varint {
  /// Encode an integer as a protobuf varint.
  static Uint8List encode(int value) {
    final result = <int>[];
    while (value > 0x7F) {
      result.add((value & 0x7F) | 0x80);
      value >>= 7;
    }
    result.add(value & 0x7F);
    return Uint8List.fromList(result);
  }

  /// Decode a varint from [data] starting at [offset].
  /// Returns a record of (value, bytesConsumed).
  static (int value, int bytesConsumed) decode(List<int> data, int offset) {
    int value = 0;
    int shift = 0;
    int bytesConsumed = 0;
    while (offset < data.length) {
      final byte = data[offset];
      value |= (byte & 0x7F) << shift;
      offset++;
      bytesConsumed++;
      if (byte & 0x80 == 0) break;
      shift += 7;
    }
    return (value, bytesConsumed);
  }
}

/// G2 packet format builder.
///
/// Packet structure:
/// ```
/// [0xAA] [type] [seq] [len] [pkt_total] [pkt_serial] [svc_hi] [svc_lo] [payload...] [crc_lo] [crc_hi]
/// ```
///
/// - type: 0x21 for phone->glasses (TX), 0x12 for glasses->phone (RX)
/// - len: length of payload + 2 (for svc_hi, svc_lo already in header... actually payload bytes after header)
/// - pkt_total: total packets in sequence (usually 1 for single-packet messages)
/// - pkt_serial: 1-indexed packet number within sequence
/// - CRC-16/CCITT calculated over payload only, stored little-endian
class PacketBuilder {
  static const int headerByte = 0xAA;
  static const int typeTx = 0x21;
  static const int typeRx = 0x12;

  /// Build a complete G2 packet with header, payload, and CRC.
  ///
  /// [seq] - sequence number
  /// [serviceHi] - high byte of service ID
  /// [serviceLo] - low byte of service ID
  /// [payload] - protobuf payload bytes
  /// [pktTotal] - total packets (default 1)
  /// [pktSerial] - packet number, 1-indexed (default 1)
  static Uint8List build({
    required int seq,
    required int serviceHi,
    required int serviceLo,
    required List<int> payload,
    int pktTotal = 1,
    int pktSerial = 1,
  }) {
    final header = [
      headerByte,
      typeTx,
      seq,
      payload.length + 2, // len field includes svc_hi and svc_lo
      pktTotal,
      pktSerial,
      serviceHi,
      serviceLo,
    ];
    final packet = <int>[...header, ...payload];
    final crc = Crc16.calculate(payload);
    packet.add(crc & 0xFF);
    packet.add((crc >> 8) & 0xFF);
    return Uint8List.fromList(packet);
  }

  /// Build a packet from raw header + payload bytes, then append CRC.
  /// The input must have the 8-byte header already included.
  static Uint8List addCrc(List<int> headerAndPayload) {
    final payload = headerAndPayload.sublist(8);
    final crc = Crc16.calculate(payload);
    return Uint8List.fromList([
      ...headerAndPayload,
      crc & 0xFF,
      (crc >> 8) & 0xFF,
    ]);
  }

  /// Parse an incoming packet from glasses.
  /// Returns null if the packet is malformed.
  static G2Packet? parse(List<int> data) {
    if (data.length < 10) return null;
    if (data[0] != headerByte) return null;

    return G2Packet(
      type: data[1],
      seq: data[2],
      length: data[3],
      pktTotal: data[4],
      pktSerial: data[5],
      serviceHi: data[6],
      serviceLo: data[7],
      payload: Uint8List.fromList(data.sublist(8, data.length - 2)),
      crcValid: Crc16.verify(data),
    );
  }
}

/// Parsed G2 packet.
class G2Packet {
  final int type;
  final int seq;
  final int length;
  final int pktTotal;
  final int pktSerial;
  final int serviceHi;
  final int serviceLo;
  final Uint8List payload;
  final bool crcValid;

  G2Packet({
    required this.type,
    required this.seq,
    required this.length,
    required this.pktTotal,
    required this.pktSerial,
    required this.serviceHi,
    required this.serviceLo,
    required this.payload,
    required this.crcValid,
  });

  /// Service ID as a combined value (e.g., 0x0B20 for Conversate).
  int get serviceId => (serviceHi << 8) | serviceLo;

  @override
  String toString() =>
      'G2Packet(svc=${serviceHi.toRadixString(16)}-${serviceLo.toRadixString(16)}, '
      'seq=$seq, payload=${payload.length}B, crc=${crcValid ? "OK" : "BAD"})';
}
