/// CRC-16/CCITT implementation for G2 protocol.
///
/// Uses init=0xFFFF, polynomial=0x1021.
/// CRC is calculated over the payload only (bytes after the 8-byte header),
/// and stored little-endian at the end of the packet.
class Crc16 {
  static const int _init = 0xFFFF;
  static const int _poly = 0x1021;

  /// Calculate CRC-16/CCITT over [data].
  static int calculate(List<int> data) {
    int crc = _init;
    for (final byte in data) {
      crc ^= byte << 8;
      for (int i = 0; i < 8; i++) {
        if (crc & 0x8000 != 0) {
          crc = ((crc << 1) ^ _poly) & 0xFFFF;
        } else {
          crc = (crc << 1) & 0xFFFF;
        }
      }
    }
    return crc;
  }

  /// Verify CRC of a complete packet (header + payload + 2-byte CRC).
  /// Returns true if the CRC matches.
  static bool verify(List<int> packet) {
    if (packet.length < 10) return false; // 8 header + at least 0 payload + 2 CRC
    final payload = packet.sublist(8, packet.length - 2);
    final expected = calculate(payload);
    final actual = packet[packet.length - 2] | (packet[packet.length - 1] << 8);
    return expected == actual;
  }
}
