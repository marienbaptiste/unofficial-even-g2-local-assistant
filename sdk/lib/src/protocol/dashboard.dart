import 'dart:convert';
import 'dart:typed_data';
import '../transport/packet_builder.dart';

/// Dashboard / AI Session protocol for Even G2 glasses.
///
/// Service 0x07 handles the full "Hey Even" voice assistant flow:
/// wake word detection, live transcription, AI response streaming,
/// TTS audio events, and session lifecycle.
///
/// Sub-services:
///   0x07-0x20 = phone → glasses (commands)
///   0x07-0x00 = glasses → phone (responses/ack)
///   0x07-0x01 = glasses → phone (events: wake, audio progress)
///
/// All field numbers CONFIRMED from BLE capture capture_20260412_225605.
class Dashboard {
  // -----------------------------------------------------------------------
  // Message types (field 1 values)
  // -----------------------------------------------------------------------
  static const int typeVoiceState = 1;
  static const int typeTranscriptionDone = 2;
  static const int typeTranscription = 3;
  static const int typeAiThinking = 4;
  static const int typeAiResponse = 5;
  static const int typeAudioEvent = 8;
  static const int typeHeartbeat = 9;
  static const int typeConfig = 10;

  // -----------------------------------------------------------------------
  // Voice states (VoiceState.state / field3.f1 values)
  // -----------------------------------------------------------------------
  /// Glasses mic opened, ready for speech (glasses → phone event).
  static const int stateListeningStarted = 1;

  /// Phone confirms listening is active (phone → glasses ack).
  static const int stateListeningActive = 2;

  /// Session boundary — wake word detected (start) or session ended (end).
  static const int stateBoundary = 3;

  // -----------------------------------------------------------------------
  // Packet builders — phone → glasses (service 0x07-0x20)
  // -----------------------------------------------------------------------

  /// Build a config packet (type=10).
  ///
  /// Sent at connection time and at the start of each AI session.
  static Uint8List buildConfig(int seq, int msgId) {
    final msgIdVarint = Varint.encode(msgId);
    final field13 = <int>[0x08, 0x00, 0x10, 0x50]; // f1=0, f2=80
    final payload = <int>[
      0x08, typeConfig,
      0x10, ...msgIdVarint,
      0x6A, ...Varint.encode(field13.length), ...field13,
    ];
    return PacketBuilder.build(seq: seq, serviceHi: 0x07, serviceLo: 0x20, payload: payload);
  }

  /// Build a voice state packet (type=1).
  ///
  /// Used for both wake acknowledgment and session end:
  /// - [stateBoundary] (3) = acknowledge wake / end session
  /// - [stateListening] (1) = confirm listening mode
  static Uint8List buildVoiceState(int seq, int msgId, int state) {
    final msgIdVarint = Varint.encode(msgId);
    final field3 = <int>[0x08, ...Varint.encode(state)];
    final payload = <int>[
      0x08, typeVoiceState,
      0x10, ...msgIdVarint,
      0x1A, ...Varint.encode(field3.length), ...field3,
    ];
    return PacketBuilder.build(seq: seq, serviceHi: 0x07, serviceLo: 0x20, payload: payload);
  }

  /// Build a live transcription packet (type=3, field 5).
  ///
  /// Sends progressive STT text as the user speaks.
  /// Each update contains the full text so far (not a delta).
  static Uint8List buildTranscription(int seq, int msgId, String text) {
    final textBytes = utf8.encode(text);
    final field5 = <int>[
      0x08, 0x00, // f1=0
      0x10, 0x00, // f2=0
      0x22, ...Varint.encode(textBytes.length), ...textBytes, // f4=text
    ];
    final msgIdVarint = Varint.encode(msgId);
    final payload = <int>[
      0x08, typeTranscription,
      0x10, ...msgIdVarint,
      0x2A, ...Varint.encode(field5.length), ...field5, // field 5
    ];
    return PacketBuilder.build(seq: seq, serviceHi: 0x07, serviceLo: 0x20, payload: payload);
  }

  /// Build a transcription-done packet (type=2, field 4).
  ///
  /// Signals end of speech — no more transcription updates will follow.
  static Uint8List buildTranscriptionDone(int seq, int msgId) {
    final msgIdVarint = Varint.encode(msgId);
    final field4 = <int>[0x08, 0x02]; // f1=2 (speech ended) — CONFIRMED from capture_20260412_234826
    final payload = <int>[
      0x08, typeTranscriptionDone,
      0x10, ...msgIdVarint,
      0x22, ...Varint.encode(field4.length), ...field4, // field 4
    ];
    return PacketBuilder.build(seq: seq, serviceHi: 0x07, serviceLo: 0x20, payload: payload);
  }

  /// Build an AI-thinking packet (type=4, field 6).
  ///
  /// Shows a loading indicator on the glasses while waiting for AI response.
  static Uint8List buildAiThinking(int seq, int msgId) {
    final msgIdVarint = Varint.encode(msgId);
    final payload = <int>[
      0x08, typeAiThinking,
      0x10, ...msgIdVarint,
      0x32, 0x00, // field 6 = empty bytes
    ];
    return PacketBuilder.build(seq: seq, serviceHi: 0x07, serviceLo: 0x20, payload: payload);
  }

  /// Build an AI response chunk packet (type=5, field 7).
  ///
  /// Streams a chunk of AI response text to the glasses display.
  /// Call multiple times, then call [buildAiResponseDone] to finish.
  static Uint8List buildAiResponse(int seq, int msgId, String text) {
    final textBytes = utf8.encode(text);
    final field7 = <int>[
      0x08, 0x00, // f1=0
      0x10, 0x00, // f2=0
      0x22, ...Varint.encode(textBytes.length), ...textBytes, // f4=text
      0x30, 0x00, // f6=0 (not done) — capture sends this explicitly
    ];
    final msgIdVarint = Varint.encode(msgId);
    final payload = <int>[
      0x08, typeAiResponse,
      0x10, ...msgIdVarint,
      0x3A, ...Varint.encode(field7.length), ...field7, // field 7 (tag 0x3A)
    ];
    return PacketBuilder.build(seq: seq, serviceHi: 0x07, serviceLo: 0x20, payload: payload);
  }

  /// Build the final AI response packet (type=5, field 7 with is_done=1).
  ///
  /// Signals that the AI response is complete. Text is empty.
  static Uint8List buildAiResponseDone(int seq, int msgId) {
    final field7 = <int>[
      0x08, 0x00, // f1=0
      0x10, 0x00, // f2=0
      0x22, 0x00, // f4="" (empty text)
      0x30, 0x01, // f6=1 (is_done)
    ];
    final msgIdVarint = Varint.encode(msgId);
    final payload = <int>[
      0x08, typeAiResponse,
      0x10, ...msgIdVarint,
      0x3A, ...Varint.encode(field7.length), ...field7, // field 7 (tag 0x3A)
    ];
    return PacketBuilder.build(seq: seq, serviceHi: 0x07, serviceLo: 0x20, payload: payload);
  }

  /// Build a session heartbeat (type=9, field 11).
  static Uint8List buildHeartbeat(int seq, int msgId) {
    final msgIdVarint = Varint.encode(msgId);
    final field11 = <int>[0x08, 0x01]; // f1=1 (active)
    final payload = <int>[
      0x08, typeHeartbeat,
      0x10, ...msgIdVarint,
      0x5A, ...Varint.encode(field11.length), ...field11, // field 11
    ];
    return PacketBuilder.build(seq: seq, serviceHi: 0x07, serviceLo: 0x20, payload: payload);
  }

  // -----------------------------------------------------------------------
  // Event parsing — glasses → phone (service 0x07-0x01)
  // -----------------------------------------------------------------------

  /// Parse a 0x07-0x01 event packet payload.
  ///
  /// Returns an [EvenAiEvent] describing what happened, or null if
  /// the payload can't be parsed.
  static EvenAiEvent? parseEvent(Uint8List payload) {
    if (payload.length < 2) return null;

    // field 1 = type (varint)
    if (payload[0] != 0x08) return null;
    final (type, typeBytes) = Varint.decode(payload, 1);
    int offset = 1 + typeBytes;

    // field 2 = seq (varint), optional
    int seq = 0;
    if (offset < payload.length && payload[offset] == 0x10) {
      offset++;
      final (s, sBytes) = Varint.decode(payload, offset);
      seq = s;
      offset += sBytes;
    }

    // Nested state value — in field 3 (tag 0x1A) or field 10 (tag 0x52)
    int nestedValue = 0;
    if (offset + 2 < payload.length) {
      final tag = payload[offset];
      if (tag == 0x1A || tag == 0x52) {
        // length-delimited field
        final len = payload[offset + 1];
        if (offset + 2 + len <= payload.length && len >= 2) {
          // nested f1 varint
          if (payload[offset + 2] == 0x08) {
            nestedValue = payload[offset + 3];
          }
        }
      }
    }

    switch (type) {
      case typeVoiceState:
        return EvenAiEvent.voiceState(seq: seq, state: nestedValue);
      case typeAudioEvent:
        return EvenAiEvent.audioProgress(seq: seq, status: nestedValue);
      default:
        return EvenAiEvent.unknown(type: type, seq: seq);
    }
  }

  // -----------------------------------------------------------------------
  // Legacy aliases (deprecated — use new names)
  // -----------------------------------------------------------------------

  @Deprecated('Use buildConfig instead')
  static Uint8List buildInit(int seq, int msgId) => buildConfig(seq, msgId);

  @Deprecated('Use buildTranscriptionDone instead')
  static Uint8List buildVoiceDone(int seq, int msgId) => buildTranscriptionDone(seq, msgId);

  @Deprecated('Use buildVoiceState(seq, msgId, Dashboard.stateBoundary) instead')
  static Uint8List buildWakeAck(int seq, int msgId, {int trigger = stateBoundary}) =>
      buildVoiceState(seq, msgId, trigger);
}

// =========================================================================
// EvenAiEvent — typed events from glasses
// =========================================================================

/// The kind of event received from the glasses on service 0x07-0x01.
enum EvenAiEventType {
  /// "Hey Even" wake word detected, or session ended.
  /// Check [EvenAiEvent.state]: [Dashboard.stateBoundary] = wake/end,
  /// [Dashboard.stateListening] = mic active.
  voiceState,

  /// TTS audio playback progress during AI response readout.
  audioProgress,

  /// Unrecognized event type.
  unknown,
}

/// An event from the glasses AI service (0x07-0x01).
class EvenAiEvent {
  final EvenAiEventType type;
  final int seq;

  /// For [voiceState]: the voice state value.
  /// [Dashboard.stateBoundary] (3) = wake word detected or session ended.
  /// [Dashboard.stateListening] (1) = mic is active, recording speech.
  final int state;

  /// For [audioProgress]: 2 = started, 1 = in progress.
  final int audioStatus;

  /// Raw type value for [unknown] events.
  final int rawType;

  EvenAiEvent._({
    required this.type,
    this.seq = 0,
    this.state = 0,
    this.audioStatus = 0,
    this.rawType = 0,
  });

  /// Wake word detected or voice state changed.
  factory EvenAiEvent.voiceState({required int seq, required int state}) =>
      EvenAiEvent._(type: EvenAiEventType.voiceState, seq: seq, state: state);

  /// TTS audio playback progress.
  factory EvenAiEvent.audioProgress({required int seq, required int status}) =>
      EvenAiEvent._(type: EvenAiEventType.audioProgress, seq: seq, audioStatus: status);

  /// Unknown event type.
  factory EvenAiEvent.unknown({required int type, required int seq}) =>
      EvenAiEvent._(type: EvenAiEventType.unknown, seq: seq, rawType: type);

  /// True if this is a session boundary event (state=3).
  /// Sent by glasses when a session ends, or as a reset between sessions.
  /// NOT the wake signal — use [isListening] for that (state=1).
  bool get isBoundary => type == EvenAiEventType.voiceState && state == Dashboard.stateBoundary;

  /// True if the glasses mic just opened (LISTENING_STARTED).
  bool get isListening => type == EvenAiEventType.voiceState && state == Dashboard.stateListeningStarted;

  /// True if TTS audio just started playing.
  bool get isAudioStarted => type == EvenAiEventType.audioProgress && audioStatus == 2;

  @override
  String toString() {
    switch (type) {
      case EvenAiEventType.voiceState:
        final s = state == Dashboard.stateBoundary ? 'BOUNDARY' : state == Dashboard.stateListeningStarted ? 'LISTENING_STARTED' : state == Dashboard.stateListeningActive ? 'LISTENING_ACTIVE' : '$state';
        return 'EvenAiEvent.voiceState(seq=$seq, state=$s)';
      case EvenAiEventType.audioProgress:
        return 'EvenAiEvent.audioProgress(seq=$seq, status=$audioStatus)';
      case EvenAiEventType.unknown:
        return 'EvenAiEvent.unknown(type=$rawType, seq=$seq)';
    }
  }
}
