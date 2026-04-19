import 'dart:convert';
import 'dart:typed_data';
import '../transport/packet_builder.dart';

/// Display protocol for Even G2 glasses.
///
/// Supports two display modes:
/// - **Conversate**: Real-time text display with streaming support (service 0x0B-0x20)
/// - **Teleprompter**: Multi-page scrollable text display (service 0x06-0x20)
class Display {
  // =========================================================================
  // Conversate (service 0x0B-0x20)
  // =========================================================================

  /// Build a Conversate init packet (type=1, start session).
  ///
  /// [title] - Optional title shown at the top of the display.
  /// Must be sent before any Conversate text packets.
  static Uint8List buildConversateInit(int seq, int msgId, {String? title}) {
    final config = <int>[0x08, 0x01, 0x10, 0x01, 0x18, 0x00, 0x20, 0x01, 0x28, 0x00];
    final field3 = <int>[
      0x08, 0x01, // field1 = 1 (start mode)
      0x12, config.length, ...config, // field2 = display config
    ];

    // Add title if provided (field3 = { field1 = title, field2 = 1 })
    if (title != null) {
      final titleBytes = utf8.encode(title);
      final titleField = <int>[
        0x0A, ...Varint.encode(titleBytes.length), ...titleBytes, // field1 = title
        0x10, 0x01, // field2 = 1
      ];
      field3.addAll([0x1A, ...Varint.encode(titleField.length), ...titleField]); // field3 = title container
    }

    field3.addAll([0x20, 0x00]); // field4 = 0

    final msgIdVarint = Varint.encode(msgId);
    final payload = <int>[0x08, 0x01, 0x10, ...msgIdVarint, 0x1A, ...Varint.encode(field3.length), ...field3];
    return PacketBuilder.build(seq: seq, serviceHi: 0x0B, serviceLo: 0x20, payload: payload);
  }

  /// Build a Conversate stop/end packet (type=1, f3.f1=2).
  ///
  /// Matches Even app capture (2026-04-18 pkt#8678): `080110XX1a0408022000`.
  /// Ends the Conversate session entirely.
  static Uint8List buildConversateStop(int seq, int msgId) {
    final field3 = <int>[0x08, 0x02, 0x20, 0x00]; // f1=2 (stop), f4=0
    final msgIdVarint = Varint.encode(msgId);
    final payload = <int>[0x08, 0x01, 0x10, ...msgIdVarint, 0x1A, ...Varint.encode(field3.length), ...field3];
    return PacketBuilder.build(seq: seq, serviceHi: 0x0B, serviceLo: 0x20, payload: payload);
  }

  /// Build a Conversate pause packet (type=1, f3.f1=3).
  ///
  /// Matches Even app capture (2026-04-18 pkt#7860): `080110XX1a0408032000`.
  /// Pauses the session without ending it. Mic stops but session stays alive.
  static Uint8List buildConversatePause(int seq, int msgId) {
    final field3 = <int>[0x08, 0x03, 0x20, 0x00]; // f1=3 (pause), f4=0
    final msgIdVarint = Varint.encode(msgId);
    final payload = <int>[0x08, 0x01, 0x10, ...msgIdVarint, 0x1A, ...Varint.encode(field3.length), ...field3];
    return PacketBuilder.build(seq: seq, serviceHi: 0x0B, serviceLo: 0x20, payload: payload);
  }

  /// Build a Conversate continue/resume packet (type=1, f3.f1=4).
  ///
  /// Matches Even app capture (2026-04-18 pkt#8232):
  /// `080110XX1a100804120a080110011800200128002000`.
  /// Resumes a paused session. Re-sends the display config.
  static Uint8List buildConversateContinue(int seq, int msgId) {
    // Same config bytes as buildConversateInit
    final config = <int>[0x08, 0x01, 0x10, 0x01, 0x18, 0x00, 0x20, 0x01, 0x28, 0x00];
    final field3 = <int>[
      0x08, 0x04, // f1=4 (continue)
      0x12, config.length, ...config, // f2 = config
      0x20, 0x00, // f4=0
    ];
    final msgIdVarint = Varint.encode(msgId);
    final payload = <int>[0x08, 0x01, 0x10, ...msgIdVarint, 0x1A, ...Varint.encode(field3.length), ...field3];
    return PacketBuilder.build(seq: seq, serviceHi: 0x0B, serviceLo: 0x20, payload: payload);
  }

  /// Build a Conversate text packet.
  ///
  /// [text] - UTF-8 text to display.
  /// [isFinal] - true if this is the final text segment (shows as complete),
  ///             false for partial/streaming text.
  static Uint8List buildConversateText(int seq, int msgId, String text, {bool isFinal = true}) {
    final textBytes = utf8.encode(text);
    final textLenVarint = Varint.encode(textBytes.length);
    final inner = <int>[
      0x0A, ...textLenVarint, ...textBytes,
      0x10, isFinal ? 0x01 : 0x00,
    ];
    final msgIdVarint = Varint.encode(msgId);
    final innerLenVarint = Varint.encode(inner.length);
    final payload = <int>[0x08, 0x06, 0x10, ...msgIdVarint, 0x42, ...innerLenVarint, ...inner];
    return PacketBuilder.build(seq: seq, serviceHi: 0x0B, serviceLo: 0x20, payload: payload);
  }

  /// Icon types for AI response lines.
  /// Values confirmed via live testing 2026-04-19 on firmware 2.1.1.12.
  /// Values 5+ crash the AI card render — do not use.
  static const int iconDocument = 1; // document icon
  static const int iconQuestion = 2; // question mark
  static const int iconPerson = 3;   // person icon
  static const int iconBulb = 4;     // lightbulb icon

  // Legacy aliases (deprecated — the earlier names were wrong)
  @Deprecated('Use iconDocument; value 1 is a document icon')
  static const int iconLink = 1;
  @Deprecated('Use iconQuestion; value 2 is a question mark')
  static const int iconAi = 2;
  @Deprecated('Use iconBulb; value 4 is a lightbulb')
  static const int iconLocation = 4;

  /// Build an AI response card (type=5).
  ///
  /// Shows a line on the glasses display with an icon and a message.
  /// Send multiple cards rapidly to stack them (up to 4).
  ///
  /// [icon] - Icon type: Display.iconBulb, Display.iconPerson, etc.
  /// [message] - The text shown on the card
  /// [isDone] - false while streaming, true for final
  static Uint8List buildAiResponse(int seq, int msgId, {
    int icon = 2,
    required String message,
    bool isDone = true,
  }) {
    final msgBytes = utf8.encode(message);
    final field7 = <int>[
      0x08, ...Varint.encode(icon), // field1 = icon type
      0x12, ...Varint.encode(msgBytes.length), ...msgBytes, // field2 (renders on glasses)
      0x1A, ...Varint.encode(msgBytes.length), ...msgBytes, // field3 (glasses require non-empty — mirror msg)
      0x20, isDone ? 0x01 : 0x00, // field4 = done flag
    ];
    final msgIdVarint = Varint.encode(msgId);
    final payload = <int>[0x08, 0x05, 0x10, ...msgIdVarint, 0x3A, ...Varint.encode(field7.length), ...field7];
    return PacketBuilder.build(seq: seq, serviceHi: 0x0B, serviceLo: 0x20, payload: payload);
  }

  /// Build a user prompt display (type=7).
  ///
  /// Shows the user's spoken command on the display.
  /// [text] - The transcribed user prompt
  static Uint8List buildUserPrompt(int seq, int msgId, String text) {
    final textBytes = utf8.encode(text);
    final field13 = <int>[
      0x08, 0x00, // field1 = 0
      0x12, ...Varint.encode(textBytes.length), ...textBytes, // field2 = prompt text
    ];
    final msgIdVarint = Varint.encode(msgId);
    final payload = <int>[0x08, 0x07, 0x10, ...msgIdVarint, 0x6A, ...Varint.encode(field13.length), ...field13];
    return PacketBuilder.build(seq: seq, serviceHi: 0x0B, serviceLo: 0x20, payload: payload);
  }

  /// Build a Conversate heartbeat packet.
  ///
  /// Matches Even app capture: `0x08 0xFF 0x01 0x10 <msgId> 0x5A 0x00`
  /// (type=255 varint, msgId, field11=empty bytes).
  static Uint8List buildConversateHeartbeat(int seq, int msgId) {
    final msgIdVarint = Varint.encode(msgId);
    final payload = <int>[0x08, 0xFF, 0x01, 0x10, ...msgIdVarint, 0x5A, 0x00];
    return PacketBuilder.build(seq: seq, serviceHi: 0x0B, serviceLo: 0x20, payload: payload);
  }

  // =========================================================================
  // Teleprompter (service 0x06-0x20)
  // =========================================================================

  /// Build a display config packet (service 0x0E-0x20).
  ///
  /// Must be sent before teleprompter init.
  static Uint8List buildDisplayConfig(int seq, int msgId) {
    // Exact config bytes from confirmed protocol
    final configHex = '0801121308021090'
        '4E1D00E094442500'
        '000000280030001213'
        '0803100D0F1D0040'
        '8D44250000000028'
        '0030001212080410'
        '001D0000884225'
        '00000000280030'
        '001212080510001D'
        '00009242250000'
        'A242280030001212'
        '080610001D0000C6'
        '42250000C4422800'
        '30001800';
    final config = _hexToBytes(configHex);
    final msgIdVarint = Varint.encode(msgId);
    final payload = <int>[0x08, 0x02, 0x10, ...msgIdVarint, 0x22, 0x6A, ...config];
    return PacketBuilder.build(seq: seq, serviceHi: 0x0E, serviceLo: 0x20, payload: payload);
  }

  /// Build a teleprompter init packet.
  ///
  /// [totalLines] - Total number of lines to display.
  /// [manualMode] - true for manual scroll, false for auto scroll.
  static Uint8List buildTeleprompterInit(int seq, int msgId, {
    int totalLines = 10,
    bool manualMode = true,
  }) {
    final mode = manualMode ? 0x00 : 0x01;

    // Scale content height based on line count (140 lines = 2665)
    final contentHeight = (totalLines * 2665) ~/ 140;
    final contentHeightVarint = Varint.encode(contentHeight > 0 ? contentHeight : 1);

    final display = <int>[
      0x08, 0x01, 0x10, 0x00, 0x18, 0x00, 0x20, 0x8B, 0x02, // Fixed settings
      0x28, ...contentHeightVarint,                            // Content height
      0x30, 0xE6, 0x01,                                        // Line height = 230
      0x38, 0x8E, 0x0A,                                        // Viewport = 1294
      0x40, 0x05, 0x48, mode,                                  // Font size + mode
    ];

    final settings = <int>[0x08, 0x01, 0x12, display.length, ...display];
    final msgIdVarint = Varint.encode(msgId);
    final payload = <int>[0x08, 0x01, 0x10, ...msgIdVarint, 0x1A, settings.length, ...settings];
    return PacketBuilder.build(seq: seq, serviceHi: 0x06, serviceLo: 0x20, payload: payload);
  }

  /// Build a teleprompter content page packet.
  ///
  /// [pageNum] - Zero-indexed page number.
  /// [text] - Text content for this page (already formatted with newlines).
  static Uint8List buildContentPage(int seq, int msgId, int pageNum, String text) {
    final textBytes = utf8.encode('\n$text');
    final pageVarint = Varint.encode(pageNum);
    final textLenVarint = Varint.encode(textBytes.length);

    final inner = <int>[
      0x08, ...pageVarint,
      0x10, 0x0A, // 10 lines per page
      0x1A, ...textLenVarint, ...textBytes,
    ];

    final innerLenVarint = Varint.encode(inner.length);
    final msgIdVarint = Varint.encode(msgId);
    final payload = <int>[0x08, 0x03, 0x10, ...msgIdVarint, 0x2A, ...innerLenVarint, ...inner];
    return PacketBuilder.build(seq: seq, serviceHi: 0x06, serviceLo: 0x20, payload: payload);
  }

  /// Build a mid-stream marker packet (sent after page 9).
  static Uint8List buildMarker(int seq, int msgId) {
    final msgIdVarint = Varint.encode(msgId);
    final payload = <int>[0x08, 0xFF, 0x01, 0x10, ...msgIdVarint, 0x6A, 0x04, 0x08, 0x00, 0x10, 0x06];
    return PacketBuilder.build(seq: seq, serviceHi: 0x06, serviceLo: 0x20, payload: payload);
  }

  /// Build a sync/trigger packet (service 0x80-0x00).
  static Uint8List buildSync(int seq, int msgId) {
    final msgIdVarint = Varint.encode(msgId);
    final payload = <int>[0x08, 0x0E, 0x10, ...msgIdVarint, 0x6A, 0x00];
    return PacketBuilder.build(seq: seq, serviceHi: 0x80, serviceLo: 0x00, payload: payload);
  }

  // =========================================================================
  // Text Formatting
  // =========================================================================

  /// Format text into pages suitable for the teleprompter.
  ///
  /// Returns a list of page strings, each containing [linesPerPage] lines
  /// wrapped to [charsPerLine] characters.
  static List<String> formatText(String text, {
    int charsPerLine = 25,
    int linesPerPage = 10,
  }) {
    // Split and word-wrap lines
    final wrapped = <String>[];
    for (final line in text.split('\n')) {
      if (line.trim().isEmpty) {
        wrapped.add('');
        continue;
      }
      final words = line.split(' ');
      var current = '';
      for (final word in words) {
        if (current.length + word.length + 1 > charsPerLine) {
          if (current.isNotEmpty) {
            wrapped.add(current.trim());
          }
          current = '$word ';
        } else {
          current += '$word ';
        }
      }
      if (current.trim().isNotEmpty) {
        wrapped.add(current.trim());
      }
    }

    if (wrapped.isEmpty) {
      wrapped.add(text);
    }

    // Pad to at least linesPerPage
    while (wrapped.length < linesPerPage) {
      wrapped.add(' ');
    }

    // Split into pages
    final pages = <String>[];
    for (int i = 0; i < wrapped.length; i += linesPerPage) {
      final pageLines = wrapped.sublist(i, (i + linesPerPage).clamp(0, wrapped.length));
      while (pageLines.length < linesPerPage) {
        pageLines.add(' ');
      }
      pages.add('${pageLines.join('\n')} \n');
    }

    // Pad to minimum 14 pages
    while (pages.length < 14) {
      pages.add('${List.filled(linesPerPage, ' ').join('\n')} \n');
    }

    return pages;
  }

  static List<int> _hexToBytes(String hex) {
    final result = <int>[];
    for (int i = 0; i < hex.length; i += 2) {
      result.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return result;
  }
}
