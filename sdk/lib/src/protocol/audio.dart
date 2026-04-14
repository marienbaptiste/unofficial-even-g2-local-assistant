import 'dart:async';
import 'dart:typed_data';
import '../models/audio_frame.dart';

/// Audio protocol handler for Even G2 glasses.
///
/// The G2 streams LC3-encoded mic audio on UUID 6402. Unlike other data,
/// audio packets are NOT wrapped in the G2 transport format (no 0xAA header).
///
/// Each 205-byte packet contains:
/// - 5 x 40-byte LC3 frames
/// - 5-byte trailer: [value][0x00][status][0xFF][seq_counter]
///
/// LC3 parameters: 10ms frame, 16kHz, 32kbps, mono, 160 samples/frame.
/// Subscribing to the 6402 characteristic automatically starts the mic stream.
/// Callback type for LC3 decoding.
///
/// Takes a 40-byte LC3 frame and returns 160 PCM samples (16-bit signed).
/// The user provides their own decoder (e.g., via FFI to liblc3).
/// No third-party codec is bundled with this SDK.
typedef Lc3DecoderCallback = Int16List Function(Uint8List lc3Frame);

class Audio {
  final _frameController = StreamController<AudioFrame>.broadcast();
  final _rawPacketController = StreamController<Uint8List>.broadcast();
  final _pcmController = StreamController<Int16List>.broadcast();

  int _packetCount = 0;
  Lc3DecoderCallback? _decoder;

  /// Stream of individual parsed LC3 audio frames (always available).
  Stream<AudioFrame> get frameStream => _frameController.stream;

  /// Stream of raw 205-byte mic packets (for recording/forwarding).
  Stream<Uint8List> get rawPacketStream => _rawPacketController.stream;

  /// Stream of decoded PCM samples (16kHz, 16-bit signed, mono).
  ///
  /// Only emits data if a decoder has been set via [setDecoder].
  /// Each emission is 160 samples (10ms of audio).
  Stream<Int16List> get pcmStream => _pcmController.stream;

  /// Whether a decoder is configured.
  bool get hasDecoder => _decoder != null;

  /// Total number of packets received since last reset.
  int get packetCount => _packetCount;

  /// Set the LC3 decoder callback.
  ///
  /// The SDK does not bundle any LC3 codec. You must provide your own,
  /// for example via FFI to liblc3 (Apache 2.0, build it yourself)
  /// or any other LC3 implementation.
  ///
  /// Example:
  /// ```dart
  /// g2.audio.setDecoder((lc3Frame) {
  ///   // Your LC3 decode logic here
  ///   return myLc3Decoder.decode(lc3Frame);
  /// });
  /// ```
  void setDecoder(Lc3DecoderCallback decoder) {
    _decoder = decoder;
  }

  /// Remove the decoder. PCM stream will stop emitting.
  void clearDecoder() {
    _decoder = null;
  }

  /// Process a raw mic packet from UUID 6402.
  ///
  /// Parses the 205-byte packet into 5 LC3 frames and emits them.
  /// If a decoder is set, also decodes and emits PCM samples.
  void processPacket(List<int> data) {
    if (data.length != AudioFrame.packetSize) return;

    _packetCount++;
    final raw = Uint8List.fromList(data);
    _rawPacketController.add(raw);

    final frames = AudioFrame.parsePacket(data);
    for (final frame in frames) {
      _frameController.add(frame);

      if (_decoder != null) {
        try {
          final pcm = _decoder!(frame.data);
          _pcmController.add(pcm);
        } catch (_) {
          // Decoder error — skip frame silently
        }
      }
    }
  }

  /// Record raw LC3 packets for a given duration.
  ///
  /// Returns the raw 205-byte packets collected. Use [extractAllFrames]
  /// to get individual LC3 frames, or [recordToWav] for decoded audio.
  Future<List<Uint8List>> recordRaw(Duration duration) async {
    final packets = <Uint8List>[];
    final sub = rawPacketStream.listen((pkt) => packets.add(pkt));
    await Future.delayed(duration);
    await sub.cancel();
    return packets;
  }

  /// Record and decode to WAV file. Requires a decoder to be set.
  ///
  /// Returns the WAV file bytes, or null if no decoder is configured.
  Future<Uint8List?> recordToWav(Duration duration) async {
    if (_decoder == null) return null;

    final allPcm = <int>[];
    final sub = pcmStream.listen((samples) => allPcm.addAll(samples));
    await Future.delayed(duration);
    await sub.cancel();

    return _buildWav(Int16List.fromList(allPcm));
  }

  /// Convert a list of raw 205-byte packets to WAV bytes.
  ///
  /// Requires a decoder to be set. Useful for offline conversion.
  Uint8List? packetsToWav(List<Uint8List> rawPackets) {
    if (_decoder == null) return null;

    final allPcm = <int>[];
    for (final packet in rawPackets) {
      final frames = AudioFrame.parsePacket(packet);
      for (final frame in frames) {
        try {
          final pcm = _decoder!(frame.data);
          allPcm.addAll(pcm);
        } catch (_) {}
      }
    }
    return _buildWav(Int16List.fromList(allPcm));
  }

  /// Build a WAV file from PCM samples (16kHz, 16-bit signed, mono).
  static Uint8List _buildWav(Int16List samples) {
    final numSamples = samples.length;
    final dataSize = numSamples * 2;
    final fileSize = 36 + dataSize;

    final buffer = ByteData(44 + dataSize);

    // RIFF header
    buffer.setUint8(0, 0x52); // R
    buffer.setUint8(1, 0x49); // I
    buffer.setUint8(2, 0x46); // F
    buffer.setUint8(3, 0x46); // F
    buffer.setUint32(4, fileSize, Endian.little);
    buffer.setUint8(8, 0x57); // W
    buffer.setUint8(9, 0x41); // A
    buffer.setUint8(10, 0x56); // V
    buffer.setUint8(11, 0x45); // E

    // fmt chunk
    buffer.setUint8(12, 0x66); // f
    buffer.setUint8(13, 0x6D); // m
    buffer.setUint8(14, 0x74); // t
    buffer.setUint8(15, 0x20); // (space)
    buffer.setUint32(16, 16, Endian.little); // chunk size
    buffer.setUint16(20, 1, Endian.little); // PCM format
    buffer.setUint16(22, 1, Endian.little); // mono
    buffer.setUint32(24, AudioFrame.sampleRate, Endian.little);
    buffer.setUint32(28, AudioFrame.sampleRate * 2, Endian.little); // byte rate
    buffer.setUint16(32, 2, Endian.little); // block align
    buffer.setUint16(34, 16, Endian.little); // bits per sample

    // data chunk
    buffer.setUint8(36, 0x64); // d
    buffer.setUint8(37, 0x61); // a
    buffer.setUint8(38, 0x74); // t
    buffer.setUint8(39, 0x61); // a
    buffer.setUint32(40, dataSize, Endian.little);

    for (int i = 0; i < numSamples; i++) {
      buffer.setInt16(44 + i * 2, samples[i], Endian.little);
    }

    return buffer.buffer.asUint8List();
  }

  /// Extract all raw LC3 frame bytes from a list of raw 205-byte packets.
  ///
  /// Returns concatenated 40-byte frames (no trailer).
  /// Useful for saving to file for offline decoding.
  static Uint8List extractAllFrames(List<Uint8List> rawPackets) {
    final allFrames = BytesBuilder();
    for (final packet in rawPackets) {
      if (packet.length != AudioFrame.packetSize) continue;
      for (int i = 0; i < AudioFrame.framesPerPacket; i++) {
        final offset = i * AudioFrame.frameSize;
        allFrames.add(packet.sublist(offset, offset + AudioFrame.frameSize));
      }
    }
    return allFrames.toBytes();
  }

  /// Reset the packet counter.
  void resetCounter() {
    _packetCount = 0;
  }

  /// Dispose streams.
  void dispose() {
    _frameController.close();
    _rawPacketController.close();
    _pcmController.close();
  }
}
