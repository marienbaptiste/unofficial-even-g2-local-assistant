import 'lib/src/protocol/dashboard.dart';
import 'lib/src/transport/packet_builder.dart';

String hex(List<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join('');

void main() {
  // Use same seq/msgId values as capture for comparison
  // Capture: #20859 seq=118 payload: 08011081011a020803
  final wakeAck = Dashboard.buildVoiceState(118, 129, Dashboard.stateBoundary);
  final wakePayload = hex(wakeAck.sublist(8, wakeAck.length - 2));
  print('Wake ack ours:    $wakePayload');
  print('Wake ack capture: 08011081011a020803');
  print('Match: ${wakePayload == '08011081011a020803'}');
  print('');

  // Capture: #23723 seq=168 payload: 080a10b3016a0408001050
  final config = Dashboard.buildConfig(168, 179);
  final configPayload = hex(config.sublist(8, config.length - 2));
  print('Config ours:    $configPayload');
  print('Config capture: 080a10b3016a0408001050');
  print('Match: ${configPayload == '080a10b3016a0408001050'}');
  print('');

  // Capture: #23775 seq=172 payload: 080110b7011a020802
  final listen = Dashboard.buildVoiceState(172, 183, Dashboard.stateListeningActive);
  final listenPayload = hex(listen.sublist(8, listen.length - 2));
  print('Listen ours:    $listenPayload');
  print('Listen capture: 080110b7011a020802');
  print('Match: ${listenPayload == '080110b7011a020802'}');
  print('');

  // Capture: #24075 seq=186 payload: 080310c5012a0a08001000220477686174
  final trans = Dashboard.buildTranscription(186, 197, 'what');
  final transPayload = hex(trans.sublist(8, trans.length - 2));
  print('Trans ours:    $transPayload');
  print('Trans capture: 080310c5012a0a08001000220477686174');
  print('Match: ${transPayload == '080310c5012a0a08001000220477686174'}');
  print('');

  // Capture: #24519 seq=194 payload: 080210cd0122020802
  final tdone = Dashboard.buildTranscriptionDone(194, 205);
  final tdonePayload = hex(tdone.sublist(8, tdone.length - 2));
  print('TransDone ours:    $tdonePayload');
  print('TransDone capture: 080210cd0122020802');
  print('Match: ${tdonePayload == '080210cd0122020802'}');
  print('');

  // Capture: #25263 seq=195 payload: 080410ce013200
  final think = Dashboard.buildAiThinking(195, 206);
  final thinkPayload = hex(think.sublist(8, think.length - 2));
  print('Thinking ours:    $thinkPayload');
  print('Thinking capture: 080410ce013200');
  print('Match: ${thinkPayload == '080410ce013200'}');
  print('');

  // Capture: #26311 seq=200 payload: 080510d3013a080800100022003001
  final rdone = Dashboard.buildAiResponseDone(200, 211);
  final rdonePayload = hex(rdone.sublist(8, rdone.length - 2));
  print('RespDone ours:    $rdonePayload');
  print('RespDone capture: 080510d3013a080800100022003001');
  print('Match: ${rdonePayload == '080510d3013a080800100022003001'}');
}
