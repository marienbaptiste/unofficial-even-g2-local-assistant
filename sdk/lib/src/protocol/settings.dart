import 'dart:typed_data';
import '../transport/packet_builder.dart';

/// Settings protocol for Even G2 glasses.
///
/// Controls device settings like wear detection via service 0x09-0x20.
class Settings {
  /// Build a wear detection toggle packet.
  ///
  /// CONFIRMED: field3.field5.f1 = value (0=off, 1=on).
  /// An init sync packet should be sent before this.
  static Uint8List buildWearDetection(int seq, int msgId, bool enable) {
    final value = enable ? 0x01 : 0x00;
    // field5 tag = (5 << 3) | 2 = 0x2A
    final inner = [0x08, value];
    final field5 = [0x2A, inner.length, ...inner];
    final msgIdVarint = Varint.encode(msgId);
    final payload = <int>[0x08, 0x01, 0x10, ...msgIdVarint, 0x1A, field5.length, ...field5];
    return PacketBuilder.build(seq: seq, serviceHi: 0x09, serviceLo: 0x20, payload: payload);
  }

  /// Build an init sync packet (sent before setting changes).
  ///
  /// Sends field3.field12.f1=1 to prepare the glasses for a settings update.
  static Uint8List buildInitSync(int seq, int msgId) {
    // field12 tag = (12 << 3) | 2 = 0x62
    final inner = [0x08, 0x01]; // field1 = 1
    final field12 = [0x62, inner.length, ...inner];
    final msgIdVarint = Varint.encode(msgId);
    final payload = <int>[0x08, 0x01, 0x10, ...msgIdVarint, 0x1A, field12.length, ...field12];
    return PacketBuilder.build(seq: seq, serviceHi: 0x09, serviceLo: 0x20, payload: payload);
  }
}
