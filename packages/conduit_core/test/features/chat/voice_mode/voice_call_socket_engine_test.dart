import 'dart:async';
import 'dart:typed_data';

import 'package:conduit_core/features/chat/realtime_call/realtime_call_state.dart';
import 'package:conduit_core/features/chat/server_speech/viseme_timeline.dart';
import 'package:conduit_core/features/chat/voice_mode/voice_call_history.dart';
import 'package:conduit_core/features/chat/voice_mode/voice_call_socket.dart';
import 'package:conduit_core/features/chat/voice_mode/voice_call_socket_engine.dart';
import 'package:test/test.dart';

import 'voice_call_socket_fakes.dart';

void main() {
  late FakeRelay relay;
  late FakeMic mic;
  late FakePlayer player;
  late VoiceCallHistory history;
  late VisemeStore visemes;
  late VoiceSocketCallEngine engine;

  VoiceSocketCallEngine make({
    List<Duration> reconnect = const [Duration(milliseconds: 20)],
  }) => VoiceSocketCallEngine(
    connector: ioVoiceSocketConnector,
    uri: relay.uri,
    headers: const {'Authorization': 'Bearer test'},
    mic: mic,
    player: player,
    chatId: 'chat-1',
    chatMessages: () => const [],
    history: history,
    visemes: visemes,
    callId: 'call-1',
    personaId: 'bmo',
    build: '194',
    tz: 'EST',
    reconnectDelays: reconnect,
    playedEvery: const Duration(milliseconds: 40),
    unduckAfter: const Duration(milliseconds: 150),
  );

  setUp(() async {
    relay = await FakeRelay.start();
    mic = FakeMic();
    player = FakePlayer();
    history = VoiceCallHistory();
    visemes = VisemeStore();
    engine = make();
  });
  tearDown(() async {
    await engine.end();
    await relay.close();
  });

  test('hello carries the call, chat, persona and pcm formats', () async {
    await engine.connect();
    expect(engine.state.phase, RealtimeCallPhase.live);
    final hello = relay.hellos.single;
    expect(hello['call_id'], 'call-1');
    expect(hello['chat_id'], 'chat-1');
    expect(hello['persona_id'], 'bmo');
    expect(hello['out'], 'pcm16');
    expect((hello['in']! as Map)['rate'], 16000);
    expect(hello['history'], isEmpty);
  });

  test('mic goes up as 0x01 + 640 bytes (20 ms) frames; mute stops it',
      () async {
    await engine.connect();
    mic.speak(50); // 1600 bytes: two whole frames, 320 left over
    await until(() => relay.micFrames.length >= 2, what: 'two frames');
    expect(relay.micFrames.first.length, 641);
    expect(relay.micFrames.first[0], 0x01);
    mic.speak(10); // 320 more: completes a third frame with the carry
    await until(() => relay.micFrames.length >= 3, what: 'third frame');
    final before = relay.micFrames.length;
    engine.setMuted(true);
    expect(engine.state.muted, isTrue);
    mic.speak(200);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(relay.micFrames.length, before);
    engine.setMuted(false);
    mic.speak(40);
    await until(() => relay.micFrames.length > before, what: 'frames again');
  });

  test('a full turn: partial, eot, parts, audio, visemes, played, done',
      () async {
    await engine.connect();
    relay.json({'type': 'partial', 'text': 'what time is'});
    await until(() => engine.state.userCaption == 'what time is');
    expect(engine.state.userSpeaking, isTrue);

    relay.json({
      'type': 'eot',
      'turn_id': 't1',
      'text': 'what time is it',
      'judge': 'text',
    });
    await until(() => engine.state.working);
    expect(engine.state.userCaption, 'what time is it');

    relay.json({'type': 'meta', 'turn_id': 't1', 'route': 'direct'});
    relay.json({
      'type': 'part',
      'turn_id': 't1',
      'part': 0,
      'text': 'It is noon.',
      'chars': [0, 11],
      'rate': 24000,
      'viseme_id': null,
    });
    relay.audio(0, 4800); // 100 ms
    await until(() => engine.state.assistantSpeaking, what: 'speaking');
    expect(player.log, containsAllInOrder(['reset', 'play']));
    expect(player.bytes[0], 4800);
    expect(engine.state.assistantCaption, 'It is noon.');

    relay.json({
      'type': 'visemes',
      'turn_id': 't1',
      'part': 0,
      'viseme_id': 'v1',
      'duration': 1.0,
      'shapes': ['a'],
      'timeline': [
        {'t': 0.0, 'shape': 'rest'},
        {'t': 0.2, 'shape': 'aa'},
      ],
    });
    await until(() => visemes['v1'] != null, what: 'viseme timeline');
    expect(visemes['v1']!.shapeAt(250), 'aa');
    expect(player.viseme[0], 'v1');
    expect(player.lastFlags[0], isTrue);

    player.pos = (part: 0, posMs: 50);
    await until(() => relay.played().isNotEmpty, what: 'played report');
    final p = relay.played().last;
    expect(p['turn_id'], 't1');
    expect(p['part'], 0);
    expect(p['ms'], 50);
    expect(p['chars'], 6); // half of 100 ms of an 11 character part

    relay.json({
      'type': 'done',
      'turn_id': 't1',
      'user_id': 'u1',
      'assistant_id': 'a1',
      'content': 'It is noon.',
      'interrupted': false,
    });
    await until(() => engine.turnsRecorded == 1, what: 'recorded');
    expect(history.turns.single.assistant!.content, 'It is noon.');
    expect(history.turns.single.user.content, 'what time is it');
    expect(engine.state.working, isFalse);
    expect(engine.state.assistantSpeaking, isTrue); // still playing
    player.ev.add(const VoicePlayerDrained());
    await until(() => !engine.state.assistantSpeaking, what: 'drained');
  });

  test('audio that finished playing before done does not leave it speaking',
      () async {
    await engine.connect();
    relay.json({'type': 'eot', 'turn_id': 't1', 'text': 'hi'});
    relay.json({
      'type': 'part',
      'turn_id': 't1',
      'part': 0,
      'text': 'Hello.',
      'chars': [0, 6],
    });
    relay.audio(0, 960);
    await until(() => engine.state.assistantSpeaking);
    player.ev.add(const VoicePlayerDrained());
    await Future<void>.delayed(const Duration(milliseconds: 30));
    relay.json({'type': 'done', 'turn_id': 't1', 'content': 'Hello.'});
    await until(() => !engine.state.assistantSpeaking, what: 'not speaking');
  });

  test('odd byte counts across frames are joined, never dropped', () async {
    await engine.connect();
    relay.json({'type': 'eot', 'turn_id': 't1', 'text': 'hi'});
    relay.json({
      'type': 'part',
      'turn_id': 't1',
      'part': 0,
      'text': 'Hello.',
      'chars': [0, 6],
    });
    relay.audio(0, 101);
    relay.audio(0, 99);
    relay.audio(0, 2);
    await until(() => (player.bytes[0] ?? 0) >= 202, what: 'bytes');
    expect(player.bytes[0], 202);
  });

  test('duck lowers the volume at once, then it comes back', () async {
    await engine.connect();
    relay.json({'type': 'eot', 'turn_id': 't1', 'text': 'tell me'});
    relay.json({
      'type': 'part',
      'turn_id': 't1',
      'part': 0,
      'text': 'A long story.',
      'chars': [0, 13],
    });
    relay.audio(0, 9600);
    await until(() => engine.state.assistantSpeaking);
    final sw = Stopwatch()..start();
    relay.json({'type': 'duck', 'turn_id': 't1'});
    await until(() => player.gains.isNotEmpty, what: 'duck');
    expect(sw.elapsedMilliseconds, lessThan(100));
    expect(player.gains.first, lessThan(0.5));
    await until(() => player.gains.length >= 2, what: 'unduck');
    expect(player.gains.last, 1.0);
  });

  test('stop halts playback within 200 ms; interrupted keeps what was heard',
      () async {
    await engine.connect();
    relay.json({'type': 'eot', 'turn_id': 't1', 'text': 'tell me a story'});
    relay.json({
      'type': 'part',
      'turn_id': 't1',
      'part': 0,
      'text': 'Once upon a time there was a dragon.',
      'chars': [0, 36],
    });
    relay.audio(0, 9600);
    await until(() => engine.state.assistantSpeaking);
    player.log.clear();
    final sw = Stopwatch()..start();
    relay.json({'type': 'stop', 'turn_id': 't1'});
    await until(() => player.log.contains('stop'), what: 'stop');
    expect(sw.elapsedMilliseconds, lessThan(200));
    expect(engine.state.assistantSpeaking, isFalse);

    // audio the relay had already sent for the stopped turn is not played
    final before = player.bytes[0];
    relay.audio(0, 960);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(player.bytes[0], before);

    relay.json({
      'type': 'interrupted',
      'turn_id': 't1',
      'kept': 'Once upon a time',
      'cut_at': 16,
      'source': 'server',
    });
    await until(() => engine.turnsRecorded == 1, what: 'recorded');
    expect(engine.state.assistantCaption, 'Once upon a time');
    final turn = history.turns.single;
    expect(turn.interrupted, isTrue);
    expect(turn.assistant!.content, startsWith('Once upon a time'));
    expect(turn.assistant!.content, contains('<!--interrupted-->'));

    // the next turn starts clean: reset, then audio plays
    relay.json({'type': 'eot', 'turn_id': 't2', 'text': 'continue'});
    relay.json({
      'type': 'part',
      'turn_id': 't2',
      'part': 0,
      'text': 'As I was saying.',
      'chars': [0, 16],
    });
    relay.audio(0, 4800);
    await until(() => engine.state.assistantSpeaking, what: 'speaks again');
    expect(player.log.where((e) => e == 'reset').length, greaterThan(0));
  });

  test('tapping interrupt sends barge with the characters heard', () async {
    await engine.connect();
    relay.json({'type': 'eot', 'turn_id': 't1', 'text': 'go'});
    relay.json({
      'type': 'part',
      'turn_id': 't1',
      'part': 0,
      'text': 'abcdefghij',
      'chars': [0, 10],
    });
    relay.audio(0, 48000); // 1 s
    await until(() => engine.state.assistantSpeaking);
    player.pos = (part: 0, posMs: 500);
    engine.interrupt();
    await until(
      () => relay.texts.any((t) => t['type'] == 'barge'),
      what: 'barge',
    );
    final barge = relay.texts.firstWhere((t) => t['type'] == 'barge');
    expect(barge['turn_id'], 't1');
    expect(barge['chars_heard'], 5);
    expect(player.log, contains('stop'));
  });

  test('a tool turn routed to Open WebUI ends the socket and hands over',
      () async {
    await engine.connect();
    relay.json({'type': 'eot', 'turn_id': 't1', 'text': 'add milk to the list'});
    relay.json({'type': 'meta', 'turn_id': 't1', 'route': 'owui'});
    await until(
      () => engine.state.phase == RealtimeCallPhase.ended,
      what: 'owui handover',
    );
    expect(engine.owuiText, 'add milk to the list');
    expect(engine.endKind, VoiceSocketEnd.owui);
    expect(engine.state.phase, RealtimeCallPhase.ended);
  });

  test('a refused upgrade (503 or 404) is unavailable, not a hang', () async {
    for (final status in [503, 404]) {
      relay.refuseWith = status;
      final e = make();
      Object? error;
      try {
        await e.connect();
      } catch (err) {
        error = err;
      }
      expect(error, isA<VoiceSocketUnavailable>());
      expect((error! as VoiceSocketUnavailable).status, status);
      expect((error as VoiceSocketUnavailable).isRefusal, isTrue);
      expect(mic.starts, 0);
    }
  });

  test('no ready within the time is unavailable', () async {
    relay.sayReady = false;
    final e = VoiceSocketCallEngine(
      connector: ioVoiceSocketConnector,
      uri: relay.uri,
      headers: const {},
      mic: mic,
      player: player,
      chatId: 'c',
      chatMessages: () => const [],
      history: history,
      readyTimeout: const Duration(milliseconds: 150),
    );
    await expectLater(e.connect(), throwsA(isA<VoiceSocketUnavailable>()));
  });

  test('a dropped socket reconnects with the same call and carries on',
      () async {
    await engine.connect();
    relay.json({'type': 'eot', 'turn_id': 't1', 'text': 'hello there'});
    relay.json({
      'type': 'done',
      'turn_id': 't1',
      'user_id': 'u1',
      'assistant_id': 'a1',
      'content': 'Hi.',
    });
    await until(() => engine.turnsRecorded == 1);
    await relay.ws.close(1011);
    await until(() => relay.hellos.length == 2, what: 'second hello');
    expect(relay.hellos.last['call_id'], 'call-1');
    // the new hello carries the turn the call already had
    final hist = relay.hellos.last['history']! as List;
    expect(hist.length, 2);
    await until(
      () => engine.state.phase == RealtimeCallPhase.live,
      what: 'live again',
    );
    expect(mic.starts, 1, reason: 'the microphone is not restarted');
    mic.speak(40);
    await until(() => relay.micFrames.isNotEmpty, what: 'mic flows again');
  });

  test('a socket that cannot come back ends as dropped, not stuck', () async {
    await engine.connect();
    relay.refuseWith = 503;
    await relay.ws.close(1011);
    await until(
      () => engine.state.phase == RealtimeCallPhase.ended,
      what: 'ended',
    );
    expect(engine.endKind, VoiceSocketEnd.dropped);
    expect(mic.stops, 1);
    expect(player.log, contains('dispose'));
  });

  test('a speaker failure ends the socket call as dropped', () async {
    await engine.connect();
    player.fail.add(StateError('engine'));
    await until(
      () => engine.state.phase == RealtimeCallPhase.ended,
      what: 'ended',
    );
    expect(engine.endKind, VoiceSocketEnd.dropped);
  });

  test('hang-up says bye and closes everything', () async {
    await engine.connect();
    await engine.end();
    await until(
      () => relay.texts.any((t) => t['type'] == 'bye'),
      what: 'bye',
    );
    expect(engine.endKind, VoiceSocketEnd.hangup);
    expect(mic.stops, 1);
  });

  group('playedChars', () {
    test('half of a finished part is half its characters', () {
      expect(
        playedChars(start: 10, length: 20, posMs: 500, audioMs: 1000, complete: true),
        20,
      );
    });
    test('never past the part, never negative', () {
      expect(
        playedChars(start: 0, length: 10, posMs: 5000, audioMs: 1000, complete: true),
        10,
      );
      expect(
        playedChars(start: 4, length: 10, posMs: 0, audioMs: 0, complete: false),
        4,
      );
    });
    test('a part still arriving uses a speaking rate floor, not the edge',
        () {
      // 100 ms received of a 70 character part; at 100 ms played the
      // naive ratio would say all 70 characters
      final c = playedChars(
        start: 0,
        length: 70,
        posMs: 100,
        audioMs: 100,
        complete: false,
      );
      expect(c, lessThan(5));
    });
  });

  test('frames and json helpers match the relay format', () {
    final f = micFrame(Uint8List(640));
    expect(f.length, 641);
    expect(f[0], 1);
    final a = parseAudioFrame([2, 0, 7, 1, 2, 3, 4])!;
    expect(a.part, 7);
    expect(a.pcm, [1, 2, 3, 4]);
    expect(parseAudioFrame([1, 0, 0, 0]), isNull);
    expect(parseSocketJson('{"type":"duck"}')!['type'], 'duck');
    expect(parseSocketJson('nope'), isNull);
  });
}
