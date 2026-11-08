
import 'package:checks/checks.dart';
import 'package:conduit/platform/engine_speech_playback.dart';
import 'package:conduit/platform/engine_voice_socket.dart';
import 'package:conduit_core/features/chat/voice_mode/voice_call_socket.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(EngineSpeechPlayback.channelName);
  late List<String> calls;
  late Map<String, Object?>? position;
  late List<Map<Object?, Object?>> appended;

  setUp(() {
    calls = <String>[];
    appended = <Map<Object?, Object?>>[];
    position = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          final args = call.arguments as Map?;
          switch (call.method) {
            case 'appendPcm16':
              appended.add(args!.cast<Object?, Object?>());
              calls.add(
                'pcm ${args['item']} ${(args['bytes'] as Uint8List).length}'
                '${args['isLast'] == true ? ' last' : ''}'
                ' @${args['sampleRate']}',
              );
            case 'playbackPosition':
              calls.add('position');
              return position;
            case 'setGain':
              calls.add('gain ${args!['gain']} ${args['rampMs']}');
            default:
              calls.add(call.method);
          }
          return true;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<void> engineEvent(Map<String, Object?> event) =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            channel.name,
            channel.codec.encodeMethodCall(MethodCall('event', event)),
            (_) {},
          );

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 5));

  test('PCM parts queue on the engine in order, with the 24 kHz rate', () async {
    final player = EngineVoiceCallPlayer();
    addTearDown(player.dispose);
    await player.reset();
    await player.appendPcm(0, Uint8List(4800));
    await player.appendPcm(0, Uint8List(960));
    await player.appendPcm(0, Uint8List(0), isLast: true);
    await player.appendPcm(1, Uint8List(2400));
    await player.play();
    check(calls).deepEquals([
      'reset',
      'pcm 0 4800 @24000.0',
      'pcm 0 960 @24000.0',
      'pcm 0 0 last @24000.0',
      'pcm 1 2400 @24000.0',
      'play',
    ]);
  });

  test('the played position is the engine item and its ms', () async {
    final player = EngineVoiceCallPlayer();
    addTearDown(player.dispose);
    check(await player.position()).isNull();
    position = {'item': 2, 'posMs': 340};
    final p = await player.position();
    check(p).isNotNull();
    check(p!.part).equals(2);
    check(p.posMs).equals(340);
  });

  test('item starts and the drain are reported to the call', () async {
    final player = EngineVoiceCallPlayer();
    addTearDown(player.dispose);
    final events = <VoicePlayerEvent>[];
    final sub = player.events.listen(events.add);
    addTearDown(sub.cancel);
    await engineEvent({'type': 'started', 'item': 0});
    await engineEvent({'type': 'started', 'item': 1});
    await engineEvent({'type': 'drained'});
    await settle();
    check(events.length).equals(3);
    check(events[0]).isA<VoicePlayerStarted>().has((e) => e.part, 'part').equals(0);
    check(events[1]).isA<VoicePlayerStarted>().has((e) => e.part, 'part').equals(1);
    check(events[2]).isA<VoicePlayerDrained>();
  });

  test('stop flushes at once and the gain ducks without a pause', () async {
    final player = EngineVoiceCallPlayer();
    addTearDown(player.dispose);
    await player.setGain(0.2);
    await player.setGain(1, ramp: const Duration(milliseconds: 150));
    calls.clear();
    final sw = Stopwatch()..start();
    await player.stop();
    check(calls).deepEquals(['stop']);
    check(sw.elapsedMilliseconds).isLessThan(200);
  });

  test('disposing the call player gives the engine events back', () async {
    final first = EngineSpeechPlayback();
    final seen = <int?>[];
    final sub = first.currentIndexChanges.listen(seen.add);
    addTearDown(sub.cancel);
    final player = EngineVoiceCallPlayer();
    await engineEvent({'type': 'started', 'item': 3});
    await settle();
    check(seen).isEmpty(); // the call's player has the events
    await player.dispose();
    await engineEvent({'type': 'started', 'item': 4});
    await settle();
    check(seen).deepEquals([4]);
  });
}
