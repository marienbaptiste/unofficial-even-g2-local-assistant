/// Represents a discovered Even G2 device.
class G2Device {
  /// Platform device ID (MAC address or UUID).
  final String id;

  /// Device name (e.g., "G2_32_L").
  final String name;

  /// Signal strength at time of discovery.
  final int rssi;

  /// Whether this is the left lens (vs right).
  final bool isLeft;

  G2Device({
    required this.id,
    required this.name,
    required this.rssi,
    required this.isLeft,
  });

  @override
  String toString() => 'G2Device($name, rssi=$rssi, ${isLeft ? "Left" : "Right"})';
}
