import 'dart:async';
import 'package:flutter/material.dart';
import 'package:even_g2_sdk/even_g2_sdk.dart';

/// SDK Test tab — exercise every SDK feature interactively.
class TestTab extends StatefulWidget {
  final EvenG2 g2;
  const TestTab({super.key, required this.g2});

  @override
  State<TestTab> createState() => _TestTabState();
}

class _TestTabState extends State<TestTab> {
  EvenG2 get g2 => widget.g2;
  final _log = <String>[];
  final _scrollCtrl = ScrollController();
  final _textCtrl = TextEditingController(text: 'Hello from SDK test!');
  StreamSubscription? _gestureSub;
  StreamSubscription? _eventSub;

  @override
  void initState() {
    super.initState();
    _gestureSub = g2.gestureStream.listen((e) => _addLog('Gesture: ${e.type} pos=${e.position}'));
    _eventSub = g2.debugEvents.listen((e) => _addLog(
      'PKT svc=0x${e.packet.serviceHi.toRadixString(16).padLeft(2, "0")}-0x${e.packet.serviceLo.toRadixString(16).padLeft(2, "0")} [${e.packet.payload.length}B]',
    ));
  }

  @override
  void dispose() {
    _gestureSub?.cancel();
    _eventSub?.cancel();
    _textCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _addLog(String msg) {
    setState(() {
      _log.add('[${TimeOfDay.now().format(context)}] $msg');
      if (_log.length > 200) _log.removeAt(0);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(_scrollCtrl.position.maxScrollExtent,
            duration: const Duration(milliseconds: 100), curve: Curves.easeOut);
      }
    });
  }

  Future<void> _run(String label, Future<void> Function() fn) async {
    _addLog('$label...');
    try {
      await fn();
      _addLog('$label OK');
    } catch (e) {
      _addLog('$label ERROR: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final connected = g2.isConnected;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Status
          Row(children: [
            Container(
              width: 10, height: 10,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: connected ? Colors.green : Colors.red,
              ),
            ),
            const SizedBox(width: 8),
            Text(connected ? 'Connected' : 'Disconnected',
                style: Theme.of(context).textTheme.titleSmall),
            const Spacer(),
            TextButton(onPressed: () => setState(() => _log.clear()), child: const Text('Clear Log')),
          ]),
          const SizedBox(height: 8),

          // Text input
          Row(children: [
            Expanded(child: TextField(
              controller: _textCtrl,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                isDense: true,
                hintText: 'Text for display tests...',
              ),
            )),
          ]),
          const SizedBox(height: 12),

          // Test buttons
          Wrap(spacing: 8, runSpacing: 8, children: [
            _section('Display'),
            _btn('Show Text', () => _run('show', () => g2.display.show(_textCtrl.text)), connected),
            _btn('Show Partial', () => _run('partial', () => g2.display.showPartial(_textCtrl.text)), connected),
            _btn('Show Final', () => _run('final', () => g2.display.showFinal(_textCtrl.text)), connected),
            _btn('Clear', () => _run('clear', () => g2.display.clear()), connected),
            _btn('AI Card', () => _run('ai-card', () => g2.display.showAiResponse(
              title: 'Test Card', body: _textCtrl.text, icon: Display.iconAi,
            )), connected),
            _btn('User Prompt', () => _run('prompt', () => g2.display.showUserPrompt(_textCtrl.text)), connected),
            _btn('Teleprompter', () => _run('teleprompter', () => g2.display.teleprompter(
              'This is a long teleprompter text to test scrolling. '
              'The glasses should show multiple pages that the user can scroll through. '
              'Each page contains about 10 lines of wrapped text. '
              'The SDK handles all the pagination and formatting automatically. '
              'Try scrolling on the touchpad to navigate between pages. '
              'This text should be long enough to span at least 2-3 pages of content.',
            )), connected),
            _btn('Stop Display', () => _run('stop', () => g2.display.stop()), connected),
            _btn('Heartbeat', () => _run('heartbeat', () => g2.display.heartbeat()), connected),

            _section('Dashboard AI'),
            _btn('Ack Wake', () => _run('dash-ack', () => g2.dashboard.ackWake()), connected),
            _btn('Transcription', () => _run('dash-transcript', () => g2.dashboard.sendTranscription(_textCtrl.text)), connected),
            _btn('Transcription Done', () => _run('dash-transdone', () => g2.dashboard.transcriptionDone()), connected),
            _btn('AI Thinking', () => _run('dash-thinking', () => g2.dashboard.showThinking()), connected),
            _btn('AI Response', () => _run('dash-response', () => g2.dashboard.streamResponse(_textCtrl.text)), connected),
            _btn('Response Done', () => _run('dash-respdone', () => g2.dashboard.streamResponseDone()), connected),
            _btn('End Session', () => _run('dash-end', () => g2.dashboard.endSession()), connected),
            _btn('Heartbeat', () => _run('dash-heartbeat', () => g2.dashboard.heartbeat()), connected),
            _btn('Full AI Flow', () => _runFullAiFlow(), connected),

            _section('Mic'),
            _btn('Start Mic', () => _run('mic-start', () => g2.mic.start()), connected),
            _btn('Stop Mic', () async {
              _addLog('mic-stop...');
              try {
                final pkts = await g2.mic.stop();
                _addLog('mic-stop OK: ${pkts.length} packets');
              } catch (e) {
                _addLog('mic-stop ERROR: $e');
              }
            }, connected),

            _section('Settings'),
            _btn('Wear ON', () => _run('wear-on', () => g2.settings.wearDetection(true)), connected),
            _btn('Wear OFF', () => _run('wear-off', () => g2.settings.wearDetection(false)), connected),

            _section('EvenHub'),
            _btn('Create Page', () => _run('hub-create', () => g2.hub.createPage(PageLayout(
              textContainers: [
                TextContainer(id: 0, x: 10, y: 10, width: 268, height: 120, content: _textCtrl.text, captureEvents: true),
              ],
            ))), connected),
            _btn('Update Text', () => _run('hub-text', () => g2.hub.updateText(0, _textCtrl.text)), connected),
            _btn('Close Page', () => _run('hub-close', () => g2.hub.closePage()), connected),
            _btn('Audio ON', () => _run('hub-audio-on', () async {
              await g2.sendRaw(EvenHub.buildAudioControl(g2.nextSeq(), g2.nextMsgId(), true));
            }), connected),
            _btn('Audio OFF', () => _run('hub-audio-off', () async {
              await g2.sendRaw(EvenHub.buildAudioControl(g2.nextSeq(), g2.nextMsgId(), false));
            }), connected),
          ]),

          const SizedBox(height: 12),

          // Log output
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Colors.grey.shade800),
              ),
              child: ListView.builder(
                controller: _scrollCtrl,
                padding: const EdgeInsets.all(8),
                itemCount: _log.length,
                itemBuilder: (context, i) {
                  final line = _log[i];
                  final color = line.contains('ERROR') ? Colors.red
                      : line.contains('OK') ? Colors.green
                      : line.contains('Gesture') ? Colors.amber
                      : line.contains('PKT') ? Colors.grey.shade600
                      : Colors.white70;
                  return Text(line, style: TextStyle(
                    fontFamily: 'Consolas',
                    fontSize: 11,
                    color: color,
                  ));
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _runFullAiFlow() async {
    if (!g2.isConnected) return;
    _addLog('Full AI flow...');
    try {
      // 1. Acknowledge wake (config + boundary + listening)
      await g2.dashboard.ackWake();
      _addLog('  ackWake sent');
      await Future.delayed(const Duration(milliseconds: 200));

      // 2. Simulate progressive transcription
      await g2.dashboard.sendTranscription('What is');
      await Future.delayed(const Duration(milliseconds: 300));
      await g2.dashboard.sendTranscription('What is the weather');
      await Future.delayed(const Duration(milliseconds: 300));
      await g2.dashboard.sendTranscription('What is the weather today?');
      await Future.delayed(const Duration(milliseconds: 500));

      // 3. Signal transcription done
      await g2.dashboard.transcriptionDone();
      _addLog('  transcriptionDone sent');
      await Future.delayed(const Duration(milliseconds: 200));

      // 4. Show thinking indicator
      await g2.dashboard.showThinking();
      _addLog('  showThinking sent');
      await Future.delayed(const Duration(milliseconds: 1000));

      // 5. Stream AI response in chunks
      await g2.dashboard.streamResponse('The weather today is sunny');
      await Future.delayed(const Duration(milliseconds: 300));
      await g2.dashboard.streamResponse(' with a high of 22 degrees celsius.');
      await Future.delayed(const Duration(milliseconds: 300));
      await g2.dashboard.streamResponse(' Perfect for a walk outside!');
      await Future.delayed(const Duration(milliseconds: 100));

      // 6. Signal response done
      await g2.dashboard.streamResponseDone();
      _addLog('  streamResponseDone sent');
      await Future.delayed(const Duration(milliseconds: 200));

      // 7. End session
      await g2.dashboard.endSession();
      _addLog('Full AI flow OK');
    } catch (e) {
      _addLog('Full AI flow ERROR: $e');
    }
  }

  Widget _section(String label) => Padding(
    padding: const EdgeInsets.only(top: 4),
    child: Text(label, style: const TextStyle(fontSize: 11, color: Colors.grey, fontWeight: FontWeight.bold)),
  );

  Widget _btn(String label, VoidCallback onPressed, bool enabled) => SizedBox(
    height: 32,
    child: ElevatedButton(
      onPressed: enabled ? onPressed : null,
      style: ElevatedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        textStyle: const TextStyle(fontSize: 12),
      ),
      child: Text(label),
    ),
  );
}
