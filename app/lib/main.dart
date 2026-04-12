import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:even_g2_sdk/even_g2_sdk.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';
// import 'test_tab.dart';

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

  // Pre-connection mode: 'conversate' or 'even_ai'
  String _mode = 'conversate';

  // Even AI session state
  StreamSubscription? _wakeSub;
  bool _aiSessionActive = false;
  Timer? _dashboardHeartbeatTimer;

  // Service health
  static const _voiceUrl = 'http://localhost:8081';
  static const _voiceWsUrl = 'ws://localhost:8081';
  static const _openclawUrl = 'http://localhost:18789';
  static final _openclawToken = _loadOpenClawToken();

  static String _loadOpenClawToken() {
    // --dart-define takes priority
    const envToken = String.fromEnvironment('OPENCLAW_TOKEN', defaultValue: '');
    if (envToken.isNotEmpty) return envToken;
    // Auto-detect from ~/.openclaw/openclaw.json
    try {
      final home = Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '';
      final f = File('$home/.openclaw/openclaw.json');
      if (f.existsSync()) {
        final data = jsonDecode(f.readAsStringSync());
        final token = data['gateway']?['auth']?['token'];
        if (token is String && token.isNotEmpty) return token;
      }
    } catch (_) {}
    return '';
  }
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
    _wakeSub?.cancel();
    _dashboardHeartbeatTimer?.cancel();
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
        final text = segments.last['text'].toString().trim();
        final isPartial = data['partial'] == true;
        if (text.isNotEmpty) {
          if (_mode == 'even_ai') {
            _handleEvenAiTranscript(text, isPartial: isPartial);
          } else {
            _handleConversateTranscript(text, isPartial: isPartial);
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

  // -- Transcript handlers --

  void _handleConversateTranscript(String text, {required bool isPartial}) {
    if (isPartial) {
      setState(() => _currentPartial = text);
      final now = DateTime.now();
      if (now.difference(_lastDisplayUpdate).inMilliseconds > 500) {
        _lastDisplayUpdate = now;
        _safeDisplay(text, isFinal: false);
      }
    } else {
      _finalizedLines.add(text);
      if (_finalizedLines.length > 200) _finalizedLines.removeAt(0);
      setState(() => _currentPartial = '');
      final recent = _finalizedLines.length > 3
          ? _finalizedLines.sublist(_finalizedLines.length - 3)
          : _finalizedLines;
      _safeDisplay(recent.join('\n'), isFinal: true);
      _sendToOpenClaw(text);
    }
  }

  void _handleEvenAiTranscript(String text, {required bool isPartial}) {
    if (isPartial) {
      setState(() => _currentPartial = text);
      // Show live transcription on glasses via Dashboard
      final now = DateTime.now();
      if (now.difference(_lastDisplayUpdate).inMilliseconds > 500) {
        _lastDisplayUpdate = now;
        try {
          _g2.dashboard.sendTranscription(text);
        } catch (_) {}
      }
    } else {
      _finalizedLines.add(text);
      if (_finalizedLines.length > 200) _finalizedLines.removeAt(0);
      setState(() => _currentPartial = '');
      // Final transcription + AI response via Dashboard flow
      _runEvenAiResponse(text);
    }
  }

  Future<void> _runEvenAiResponse(String transcript) async {
    if (!_openclawOnline || _aiProcessing) return;

    _aiHistory.add({'role': 'user', 'content': 'This is a question that expects always an answer: $transcript'});
    while (_aiHistory.length > 20) _aiHistory.removeAt(0);

    _aiProcessing = true;
    setState(() => _status = 'Even AI: thinking...');

    try {
      // Signal transcription done + show thinking on glasses
      await _g2.dashboard.transcriptionDone();
      await Future.delayed(const Duration(milliseconds: 100));
      await _g2.dashboard.showThinking();

      final messages = [
        {'role': 'system', 'content': 'You are a personal AI assistant on smart glasses. '
            'You receive live transcripts of what the wearer says. '
            'ALWAYS respond to every message. '
            'Prefix responses with [AI]. Keep under 3 sentences.'},
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
          _aiHistory.add({'role': 'assistant', 'content': content});
          // Stream AI response via Dashboard protocol
          await _g2.dashboard.streamResponse(content);
          await Future.delayed(const Duration(milliseconds: 100));
          await _g2.dashboard.streamResponseDone();
          setState(() {
            _finalizedLines.add(content);
            if (_finalizedLines.length > 200) _finalizedLines.removeAt(0);
            _status = 'Even AI: ready';
          });
        } else {
          setState(() => _status = 'Even AI: ready');
        }
      }
    } catch (e) {
      debugPrint('Even AI error: $e');
      setState(() => _status = 'Even AI: error');
    } finally {
      _aiProcessing = false;
      _endEvenAiSession();
    }
  }

  void _endEvenAiSession() {
    _levelSub?.cancel();
    _levelSub = null;
    _disconnectVoice();
    if (_g2.mic.isActive) _g2.mic.stop().catchError((_) => <Uint8List>[]);
    // End session on glasses — stops auto-heartbeat and returns to idle
    try { _g2.dashboard.endSession(); } catch (_) {}
    _aiSessionActive = false;
    setState(() {
      _vuLevel = 0;
      _currentPartial = '';
      _status = 'Even AI: listening for "Hey Even"...';
    });
  }

  // -- OpenClaw AI (Conversate mode) --

  Future<void> _sendToOpenClaw(String transcript) async {
    if (!_openclawOnline || _aiProcessing) return;

    _aiHistory.add({'role': 'user', 'content': transcript});
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
          _aiHistory.add({'role': 'assistant', 'content': content});
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

      if (_mode == 'even_ai') {
        // Even AI: listen for "Hey Even" wake word via clean SDK stream
        _wakeSub = _g2.dashboard.onWake.listen((event) {
          debugPrint('Hey Even wake: $event');
          setState(() => _finalizedLines.add('>>> Hey Even detected'));
          _onEvenAiWake();
        });

        setState(() {
          _phase = 'conversate';
          _status = 'Even AI: listening for "Hey Even"...';
          _aiSessionActive = false;
        });
      } else {
        await _g2.display.show('Connected');
        // Conversate: start mic + Whisper immediately
        await _g2.mic.start();

        _levelSub = _g2.mic.levelStream.listen((level) {
          setState(() => _vuLevel = level);
        });

        _connectVoice();

        _micSub = _g2.mic.packetStream.listen((packet) {
          _ws?.sink.add(packet);
        });

        setState(() {
          _phase = 'conversate';
          _status = 'Streaming to Whisper';
        });
      }
    } catch (e) {
      setState(() { _phase = 'disconnected'; _status = 'Error: $e'; });
    }
  }

  /// Called when glasses send "Hey Even" wake word event.
  /// Replays the exact protocol from capture_20260412_234826 session 2.
  Future<void> _onEvenAiWake() async {
    if (_aiSessionActive) return;
    _aiSessionActive = true;

    setState(() => _status = 'Even AI: wake detected, replaying capture...');

    try {
      // Replay exact session 2 from capture_20260412_234826
      await _g2.dashboard.ackWake();
      setState(() => _status = 'Even AI: ack sent, sending transcription...');

      // Transcription (progressive, same as capture)
      await Future.delayed(const Duration(milliseconds: 500));
      await _g2.dashboard.sendTranscription('what');
      await Future.delayed(const Duration(milliseconds: 200));
      await _g2.dashboard.sendTranscription('what is');
      await Future.delayed(const Duration(milliseconds: 200));
      await _g2.dashboard.sendTranscription('what is the');
      await Future.delayed(const Duration(milliseconds: 200));
      await _g2.dashboard.sendTranscription('what is the temperature');
      await Future.delayed(const Duration(milliseconds: 300));
      await _g2.dashboard.sendTranscription('what is the temperature in geneva');
      await Future.delayed(const Duration(milliseconds: 200));
      await _g2.dashboard.sendTranscription('what is the temperature in geneva right now');
      await Future.delayed(const Duration(milliseconds: 300));
      await _g2.dashboard.sendTranscription('What is the temperature in Geneva right now?');
      setState(() => _status = 'Even AI: transcription done, thinking...');

      // End speech
      await Future.delayed(const Duration(milliseconds: 500));
      await _g2.dashboard.transcriptionDone();

      // AI thinking
      await Future.delayed(const Duration(milliseconds: 500));
      await _g2.dashboard.showThinking();

      // AI response (3 chunks, same as capture)
      await Future.delayed(const Duration(milliseconds: 1500));
      await _g2.dashboard.streamResponse(
        'The current temperature in Geneva is 9.5 degrees Celsius, though it feels more like 7.4 degrees Celsius due to the wind. There is currently slight');
      await Future.delayed(const Duration(milliseconds: 100));
      await _g2.dashboard.streamResponse(
        ' rain in the area with a humidity level of 83 percent.');
      await Future.delayed(const Duration(milliseconds: 100));
      await _g2.dashboard.streamResponseDone();

      setState(() {
        _finalizedLines.add('Replay complete!');
        _status = 'Even AI: replay done, waiting for timeout...';
      });
    } catch (e) {
      debugPrint('Even AI replay error: $e');
      setState(() => _status = 'Even AI: error — $e');
    } finally {
      _aiSessionActive = false;
    }
  }

  Future<void> _disconnect() async {
    _levelSub?.cancel();
    _levelSub = null;
    _wakeSub?.cancel();
    _wakeSub = null;
    _dashboardHeartbeatTimer?.cancel();
    _dashboardHeartbeatTimer = null;
    _aiSessionActive = false;
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

  Widget _serviceChip(String label, bool online) {
    return Chip(
      avatar: Container(
        width: 8, height: 8,
        decoration: BoxDecoration(shape: BoxShape.circle, color: online ? Colors.green : Colors.red),
      ),
      label: Text(label, style: const TextStyle(fontSize: 12)),
      visualDensity: VisualDensity.compact,
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

          if (_phase == 'disconnected') ...[
            // Mode selector
            Card(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Mode', style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 8),
                    RadioListTile<String>(
                      dense: true,
                      title: const Text('Conversate'),
                      subtitle: const Text('Always-on mic → Whisper → live transcription on glasses', style: TextStyle(fontSize: 11, color: Colors.grey)),
                      value: 'conversate',
                      groupValue: _mode,
                      onChanged: (v) => setState(() => _mode = v!),
                    ),
                    RadioListTile<String>(
                      dense: true,
                      title: const Text('Even AI'),
                      subtitle: Text(
                        'Mic → Whisper → OpenClaw (always answer) → Dashboard AI display'
                        '${!_openclawOnline ? '\nOpenClaw offline!' : ''}',
                        style: TextStyle(fontSize: 11, color: !_openclawOnline ? Colors.red : Colors.grey),
                      ),
                      value: 'even_ai',
                      groupValue: _mode,
                      onChanged: (v) => setState(() => _mode = v!),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            // Service status
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _serviceChip('Whisper', _whisperOnline && _whisperModelLoaded),
                const SizedBox(width: 8),
                _serviceChip('OpenClaw', _openclawOnline),
              ],
            ),
            const SizedBox(height: 16),
            Center(child: ElevatedButton.icon(
              onPressed: _connect,
              icon: const Icon(Icons.bluetooth),
              label: Text('Connect — ${_mode == 'even_ai' ? 'Even AI' : 'Conversate'}'),
              style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16)),
            )),
          ],

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
