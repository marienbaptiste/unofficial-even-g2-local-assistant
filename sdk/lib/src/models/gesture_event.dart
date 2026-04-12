/// Types of gesture events from the G2 glasses.
enum GestureType {
  /// Single tap on the touchpad.
  singleTap,

  /// Double tap on the touchpad.
  doubleTap,

  /// Scroll/swipe gesture on the touchpad.
  scroll,

  /// Long press on the touchpad (~3 seconds).
  longPress,

  /// Both touchpads held simultaneously (enters silent mode).
  bothHold,

  /// Head tilt detected (dashboard trigger, includes position).
  headTilt,

  /// Unknown gesture type.
  unknown,
}

/// A gesture event received from the G2 glasses.
///
/// Use the convenience getters for clean conditional logic:
/// ```dart
/// g2.onGesture((g) {
///   if (g.isTap) handleTap();
///   if (g.isDoubleTap) handleDoubleTap();
///   if (g.isScroll) handleScroll(g.position!);
///   if (g.isHeadTilt) handleTilt(g.position!);
/// });
/// ```
class GestureEvent {
  /// The type of gesture.
  final GestureType type;

  /// Position value for scroll and head tilt gestures.
  ///
  /// For head tilt: dashboard widget index (counts down from 10 to 1).
  /// For scroll: new scroll position after the swipe.
  /// Null for tap, double tap, long press, and both hold.
  final int? position;

  /// Raw payload bytes (for debugging/protocol analysis).
  final List<int> rawPayload;

  GestureEvent({
    required this.type,
    this.position,
    this.rawPayload = const [],
  });

  // Convenience getters
  bool get isTap => type == GestureType.singleTap;
  bool get isDoubleTap => type == GestureType.doubleTap;
  bool get isScroll => type == GestureType.scroll;
  bool get isLongPress => type == GestureType.longPress;
  bool get isBothHold => type == GestureType.bothHold;
  bool get isHeadTilt => type == GestureType.headTilt;

  @override
  String toString() {
    final posStr = position != null ? ' pos=$position' : '';
    return 'Gesture(${type.name}$posStr)';
  }
}
