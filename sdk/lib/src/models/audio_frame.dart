import 'dart:typed_data';

/// A single LC3 audio frame from the G2 mic.
///
/// LC3 parameters: 10ms frame, 16kHz sample rate, 32kbps, mono, 160 samples/frame.
/// Each raw 205-byte packet from UUID 6402 contains 5 x 40-byte LC3 frames + 5-byte trailer.
class AudioFrame {
  /// Raw LC3 encoded frame data (40 bytes).
  final Uint8List data;

  /// Sequence counter from the packet trailer.
  final int sequenceCounter;

  AudioFrame({
    required this.data,
    required this.sequenceCounter,
  });

  /// LC3 frame size in bytes.
  static const int frameSize = 40;

  /// Number of LC3 frames per raw BLE packet.
  static const int framesPerPacket = 5;

  /// Raw BLE packet size (5 * 40 + 5 byte trailer).
  static const int packetSize = 205;

  /// Trailer size in bytes.
  static const int trailerSize = 5;

  /// LC3 frame duration in milliseconds.
  static const int frameDurationMs = 10;

  /// LC3 sample rate in Hz.
  static const int sampleRate = 16000;

  /// LC3 bitrate in bps.
  static const int bitrate = 32000;

  /// Samples per LC3 frame.
  static const int samplesPerFrame = 160;

  /// Parse a raw 205-byte mic packet into 5 AudioFrames.
  ///
  /// Packet format: [40B frame0][40B frame1][40B frame2][40B frame3][40B frame4][5B trailer]
  /// Trailer: [1B value][0x00][1B status][0xFF][1B seq_counter]
  static List<AudioFrame> parsePacket(List<int> packet) {
    if (packet.length != packetSize) return [];

    final trailerStart = framesPerPacket * frameSize;
    final seqCounter = packet[trailerStart + 4];

    final frames = <AudioFrame>[];
    for (int i = 0; i < framesPerPacket; i++) {
      final offset = i * frameSize;
      frames.add(AudioFrame(
        data: Uint8List.fromList(packet.sublist(offset, offset + frameSize)),
        sequenceCounter: seqCounter,
      ));
    }
    return frames;
  }
}
