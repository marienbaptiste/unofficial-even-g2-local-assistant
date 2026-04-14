/// Display configuration for the G2 glasses.
///
/// Controls display intensity, balance, and height/distance settings.
class DisplayConfig {
  /// Display intensity for the left eye (widget 5, f3).
  final double? intensityLeft;

  /// Display intensity for the right eye (widget 5, f4).
  final double? intensityRight;

  /// Display balance for the left eye (widget 6, f3).
  final double? balanceLeft;

  /// Display balance for the right eye (widget 6, f4).
  final double? balanceRight;

  /// Display height/distance value (field3.field2.f1).
  /// Known values: 0, 5, 6, 8, 12.
  final int? heightDistance;

  DisplayConfig({
    this.intensityLeft,
    this.intensityRight,
    this.balanceLeft,
    this.balanceRight,
    this.heightDistance,
  });

  @override
  String toString() =>
      'DisplayConfig(intensity=L:$intensityLeft/R:$intensityRight, '
      'balance=L:$balanceLeft/R:$balanceRight, height=$heightDistance)';
}
