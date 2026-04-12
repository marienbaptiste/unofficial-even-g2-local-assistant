import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:even_g2_sdk/even_g2_sdk.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

void main() => runApp(const G2App());

class G2App extends StatelessWidget {
  const G2App({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Even G2 Assistant',
    theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true, brightness: Brightness.dark),
    home: const G2Page(),
  );
}

class G2Page extends StatefulWidget {
  const G2Page({super.key});
  @override
  State<G2Page> createState() => _G2PageState();
}

class _G2PageState extends State<G2Page> {
  final _g2 = EvenG2();
  final _textCtrl = TextEditingController(text: 'Hello from Flutter!');

  // State
  String _phase = 'disconnected'; // disconnected, connecting, conversate
  String _status = 'Tap Connect to start';
  double _vuLevel = 0.0;
  String _currentPartial = '';
  final List<String> _finalizedLines = [];
  DateTime _lastDisplayUpdate = DateTime.now();

  // Service health
  static const _voiceUrl = 'http://localhost:8081';
  static const _voiceWsUrl = 'ws://localhost:8081';
  static const _openclawUrl = 'http://localhost:18789';
  static const _openclawToken = String.fromEnvironment('OPENCLAW_TOKEN',
      defaultValue: ''); // Set via --dart-define=OPENCLAW_TOKEN=your_token
  bool _whisperOnline = false;
  bool _whisperModelLoaded = false;
  bool _openclawOnline = false;
  Timer? _healthTimer;

  // AI conversation history (rolling window for context)
  final List<Map<String, String>> _aiHistory = [];
  bool _aiProcessing = false;

  // Streaming
  WebSocketChannel? _ws;
  StreamSubscription? _connSub;
  StreamSubscription? _levelSub;
  StreamSubscription? _micSub;

  @override
  void initState() {
    super.initState();
    _connSub = _g2.onConnectionChange.listen((connected) {
      if (!connected && _phase != 'disconnected') {
        _disconnectVoice();
        setState(() {
          _phase = 'disconnected';
          _status = 'Disconnected';
          _vuLevel = 0;
        });
      }
    });
    _checkHealth();
    _healthTimer = Timer.periodic(const Duration(seconds: 5), (_) => _checkHealth());
  }

  @override
  void dispose() {
    _healthTimer?.cancel();
    _connSub?.cancel();
    _levelSub?.cancel();
    _micSub?.cancel();
    _disconnectVoice();
    _textCtrl.dispose();
    _g2.dispose();
    super.dispose();
  }

  Future<void> _checkHealth() async {
    try {
      final resp = await http.get(Uri.parse('$_voiceUrl/api/health'))
          .timeout(const Duration(seconds: 2));
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        setState(() {
          _whisperOnline = true;
          _whisperModelLoaded = data['model_loaded'] == true;
        });
      } else {
        setState(() { _whisperOnline = false; _whisperModelLoaded = false; });
      }
    } catch (_) {
      setState(() { _whisperOnline = false; _whisperModelLoaded = false; });
    }

    // OpenClaw
    try {
      final resp = await http.get(Uri.parse('$_openclawUrl/healthz'))
          .timeout(const Duration(seconds: 2));
      setState(() => _openclawOnline = resp.statusCode == 200);
    } catch (_) {
      setState(() => _openclawOnline = false);
    }
  }

  // -- Voice service WebSocket --

  void _connectVoice() {
    if (!_whisperModelLoaded) return;

    _ws = WebSocketChannel.connect(Uri.parse('$_voiceWsUrl/ws/stream'));

    // Configure for LC3 input
    _ws!.sink.add(jsonEncode({
      'action': 'config',
      'input_format': 'lc3',
    }));

    // Listen for transcription results
    _ws!.stream.listen((message) {
      final data = jsonDecode(message as String);

      if (data['segments'] != null) {
        final segments = data['segments'] as List;
        if (segments.isEmpty) return;
        // WhisperLive sends all segments each time — only take the last one
        final text = segments.last['text'].toString().trim();
        final isPartial = data['partial'] == true;
        if (text.isNotEmpty) {
          if (isPartial) {
            setState(() => _currentPartial = text);
            // Throttle partial updates to glasses (max every 500ms)
            final now = DateTime.now();
            if (now.difference(_lastDisplayUpdate).inMilliseconds > 500) {
              _lastDisplayUpdate = now;
              _safeDisplay(text, isFinal: false);
            }
          } else {
            _finalizedLines.add(text);
            if (_finalizedLines.length > 200) _finalizedLines.removeAt(0);
            setState(() => _currentPartial = '');
            // Only show the last 3 finalized lines on glasses
            final recent = _finalizedLines.length > 3
                ? _finalizedLines.sublist(_finalizedLines.length - 3)
                : _finalizedLines;
            _safeDisplay(recent.join('\n'), isFinal: true);

            // Send finalized text to OpenClaw for AI response
            _sendToOpenClaw(text);
          }
        }
      }

    }, onError: (e) {
      setState(() => _status = 'Voice stream error: $e');
    }, onDone: () {
      _ws = null;
    });
  }

  void _safeDisplay(String text, {required bool isFinal}) {
    try {
      if (isFinal) {
        _g2.display.showFinal(text);
      } else {
        _g2.display.showPartial(text);
      }
      _lastDisplayUpdate = DateTime.now();
    } catch (e) {
      // Don't let display errors kill the voice stream
      debugPrint('Display error: $e');
    }
  }

  void _disconnectVoice() {
    _micSub?.cancel();
    _micSub = null;
    _ws?.sink.close();
    _ws = null;
  }

  // -- OpenClaw AI --

  Future<void> _sendToOpenClaw(String transcript) async {
    if (!_openclawOnline || _aiProcessing) return;

    // Add to conversation history
    _aiHistory.add({'role': 'user', 'content': transcript});
    // Keep last 20 messages for context
    while (_aiHistory.length > 20) _aiHistory.removeAt(0);

    _aiProcessing = true;

    try {
      final messages = [
        {'role': 'system', 'content': 'You are a personal AI assistant on smart glasses. '
            'You receive live transcripts of what the wearer says. '
            'Only respond if directly addressed or if there is an action item. '
            'Prefix responses with [AI]. Keep under 3 sentences. '
            'If not addressed, respond with exactly: [SILENT]'},
        ..._aiHistory,
      ];

      final resp = await http.post(
        Uri.parse('$_openclawUrl/v1/chat/completions'),
        headers: {
          'Authorization': 'Bearer $_openclawToken',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'model': 'openclaw', 'messages': messages}),
      ).timeout(const Duration(seconds: 15));

      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        final content = data['choices']?[0]?['message']?['content']?.toString().trim() ?? '';

        if (content.isNotEmpty && content != '[SILENT]' && !content.contains('[SILENT]')) {
          // AI wants to respond — show on glasses and in chat
          _aiHistory.add({'role': 'assistant', 'content': content});
          // Show as regular text on glasses (more reliable than AI card)
          _safeDisplay(content, isFinal: true);
          setState(() {
            _finalizedLines.add(content);
            if (_finalizedLines.length > 200) _finalizedLines.removeAt(0);
          });
        }
      }
    } catch (e) {
      debugPrint('OpenClaw error: $e');
    } finally {
      _aiProcessing = false;
    }
  }

  // -- Actions --

  Future<void> _connect() async {
    setState(() { _phase = 'connecting'; _status = 'Scanning...'; });
    try {
      await _g2.connectToNearest();
      setState(() { _status = 'Entering Conversate...'; });

      await _g2.display.show('Connected');

      await _g2.mic.start();

      // VU meter
      _levelSub = _g2.mic.levelStream.listen((level) {
        setState(() => _vuLevel = level);
      });

      // Connect to voice service and stream mic audio
      _connectVoice();

      // Forward raw LC3 BLE packets to voice service
      _micSub = _g2.mic.packetStream.listen((packet) {
        _ws?.sink.add(packet);
      });

      setState(() { _phase = 'conversate'; _status = 'Streaming to Whisper'; });
    } catch (e) {
      setState(() { _phase = 'disconnected'; _status = 'Error: $e'; });
    }
  }

  Future<void> _disconnect() async {
    _levelSub?.cancel();
    _levelSub = null;
    _disconnectVoice();
    if (_g2.mic.isActive) await _g2.mic.stop();
    await _g2.disconnect();
    setState(() {
      _phase = 'disconnected';
      _status = 'Disconnected';
      _vuLevel = 0;
      _currentPartial = '';
      _finalizedLines.clear();
    });
  }

  Future<void> _send() async {
    final text = _textCtrl.text.trim();
    if (text.isEmpty) return;
    try {
      await _g2.display.show(text);
      setState(() => _status = 'Sent: $text');
    } catch (e) {
      setState(() => _status = 'Send error: $e');
    }
  }

  Future<void> _testAiCards() async {
    try {
      setState(() => _status = 'Sending AI cards...');
      // Send multiple AI response lines with different icons — like the Even tutorial
      await _g2.display.showAiResponse(
        icon: Display.iconLink, title: 'Meeting Summary', body: 'Q2 planning session', isDone: false);
      await Future.delayed(const Duration(milliseconds: 200));
      await _g2.display.showAiResponse(
        icon: Display.iconPerson, title: 'Participants', body: 'Alice, Bob, Charlie', isDone: false);
      await Future.delayed(const Duration(milliseconds: 200));
      await _g2.display.showAiResponse(
        icon: Display.iconAi, title: 'Key Decision', body: 'Launch date moved to Q3', isDone: false);
      await Future.delayed(const Duration(milliseconds: 200));
      await _g2.display.showAiResponse(
        icon: Display.iconPerson, title: 'Action Item', body: 'Alice to prepare deck by Friday', isDone: true);
      setState(() => _status = 'AI cards sent!');
    } catch (e) {
      setState(() => _status = 'AI card error: $e');
    }
  }

  // -- UI --

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Even G2 Assistant'),
        actions: [
          _serviceIndicator('Whisper', _whisperOnline, _whisperModelLoaded),
          _serviceIndicator('OpenClaw', _openclawOnline, _openclawOnline),
          const SizedBox(width: 8),
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Tooltip(
              message: 'G2 Glasses: $_phase',
              child: Container(
                width: 10, height: 10,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _phase == 'conversate' ? Colors.green
                      : _phase == 'connecting' ? Colors.orange
                      : Colors.red,
                ),
              ),
            ),
          ),
        ],
      ),
      body: Row(
        children: [
          Expanded(child: _buildContent()),
          if (_phase == 'conversate') _buildVuMeter(),
        ],
      ),
    );
  }

  Widget _serviceIndicator(String label, bool online, bool ready) {
    final color = !online ? Colors.red : ready ? Colors.green : Colors.orange;
    final status = !online ? 'offline' : ready ? 'ready' : 'loading...';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Tooltip(
        message: '$label: $status',
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8, height: 8,
              decoration: BoxDecoration(shape: BoxShape.circle, color: color),
            ),
            const SizedBox(width: 4),
            Text(label, style: const TextStyle(fontSize: 11, color: Colors.grey)),
          ],
        ),
      ),
    );
  }

  Widget _buildContent() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(_status, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.grey)),
          const SizedBox(height: 16),

          if (_phase == 'disconnected')
            Center(child: ElevatedButton.icon(
              onPressed: _connect,
              icon: const Icon(Icons.bluetooth),
              label: const Text('Connect'),
              style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16)),
            )),

          if (_phase == 'connecting')
            const Center(child: CircularProgressIndicator()),

          if (_phase == 'conversate') ...[
            Row(children: [
              Expanded(child: TextField(
                controller: _textCtrl,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: 'Type text to display on glasses...',
                ),
                onSubmitted: (_) => _send(),
              )),
              const SizedBox(width: 8),
              ElevatedButton(onPressed: _send, child: const Text('Send')),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                onPressed: _testAiCards,
                icon: const Icon(Icons.auto_awesome, size: 16),
                label: const Text('AI Cards'),
              ),
            ]),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(onPressed: _disconnect, child: const Text('Disconnect')),
            ),

            // Live transcription
            if (_finalizedLines.isNotEmpty || _currentPartial.isNotEmpty) ...[
              const SizedBox(height: 16),
              Expanded(
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Live Transcription', style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Colors.grey)),
                        const SizedBox(height: 4),
                        Expanded(
                          child: ListView.builder(
                            reverse: true,
                            itemCount: _finalizedLines.length + (_currentPartial.isNotEmpty ? 1 : 0),
                            itemBuilder: (context, index) {
                              if (_currentPartial.isNotEmpty && index == 0) {
                                return Padding(
                                  padding: const EdgeInsets.only(bottom: 4),
                                  child: Text(_currentPartial, style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: Colors.grey)),
                                );
                              }
                              final lineIndex = _finalizedLines.length - 1 - (index - (_currentPartial.isNotEmpty ? 1 : 0));
                              if (lineIndex < 0 || lineIndex >= _finalizedLines.length) return const SizedBox.shrink();
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 4),
                                child: Text(_finalizedLines[lineIndex], style: Theme.of(context).textTheme.bodyLarge),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],

          ],
        ],
      ),
    );
  }

  Widget _buildVuMeter() {
    return Container(
      width: 24,
      margin: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade700),
        borderRadius: BorderRadius.circular(4),
      ),
      child: LayoutBuilder(builder: (context, constraints) {
        final fillHeight = constraints.maxHeight * _vuLevel;
        return Stack(
          alignment: Alignment.bottomCenter,
          children: [
            Container(color: Colors.transparent),
            AnimatedContainer(
              duration: const Duration(milliseconds: 50),
              height: fillHeight,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(3),
                color: _vuLevel > 0.7 ? Colors.red
                    : _vuLevel > 0.4 ? Colors.yellow
                    : Colors.green,
              ),
            ),
          ],
        );
      }),
    );
  }
}
