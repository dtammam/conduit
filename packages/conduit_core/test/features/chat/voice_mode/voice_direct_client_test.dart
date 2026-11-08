import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/chat/voice_mode/voice_call_history.dart';
import 'package:conduit_core/features/chat/voice_mode/voice_direct_client.dart';
import 'package:conduit_core/features/chat/voice_mode/voice_direct_turn.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

/// A relay stand-in on loopback. Each `/voice/turn` request is answered by the
/// next entry of [turnHandlers]; every request is recorded.
class _FakeRelay {
  _FakeRelay(this.turnHandlers);

  final List<Future<void> Function(HttpRequest, Map<String, Object?>)>
  turnHandlers;
  final List<String> requests = <String>[]; // "METHOD /path"
  final List<Map<String, Object?>> turnBodies = <Map<String, Object?>>[];
  final List<String?> authHeaders = <String?>[];
  late HttpServer server;
  int savedPending = 0;
  int savedCalls = 0;

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      requests.add('${request.method} ${request.uri.path}');
      authHeaders.add(request.headers.value('authorization'));
      if (request.uri.path == '/voice/saved') {
        savedCalls++;
        final pending = savedPending > 0 ? savedPending-- : 0;
        request.response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'pending': pending}));
        await request.response.close();
        return;
      }
      if (request.uri.path != '/voice/turn') {
        request.response.statusCode = 404;
        await request.response.close();
        return;
      }
      final raw = await utf8.decoder.bind(request).join();
      final body = (jsonDecode(raw) as Map).cast<String, Object?>();
      turnBodies.add(body);
      final index = turnBodies.length - 1;
      final handler = turnHandlers[index.clamp(0, turnHandlers.length - 1)];
      await handler(request, body);
    });
  }

  Uri get turnUri => Uri.parse('http://127.0.0.1:${server.port}/voice/turn');

  VoiceDirectClient client({int maxAttempts = 3}) => VoiceDirectClient(
    dio: Dio(
      BaseOptions(headers: {'Authorization': 'Bearer test-key'}),
    ),
    turnUri: turnUri,
    maxAttempts: maxAttempts,
    retryDelay: const Duration(milliseconds: 5),
  );

  Future<void> stop() => server.close(force: true);
}

String _sse(Map<String, Object?> json) => 'data: ${jsonEncode(json)}\n\n';

Future<void> _stream(HttpRequest request, List<String> chunks) async {
  request.response
    ..statusCode = 200
    ..headers.contentType = ContentType('text', 'event-stream', charset: 'utf-8');
  for (final chunk in chunks) {
    request.response.write(chunk);
    await request.response.flush();
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  await request.response.close();
}

final _meta = _sse({
  'type': 'meta',
  'turn_id': 't1',
  'lane': 'talk',
  'route': 'direct',
  'cache': 'warm',
});

String _done(String content) => _sse({
  'type': 'done',
  'turn_id': 't1',
  'user_id': 'uid',
  'assistant_id': 'aid',
  'content': content,
  'interrupted': false,
  'timings': {'first_delta_ms': 300},
});

ChatMessage _msg(String id, String role, String content) => ChatMessage(
  id: id,
  role: role,
  content: content,
  timestamp: DateTime(2026, 11, 8),
);

Future<VoiceDirectResult> _run(
  _FakeRelay relay,
  VoiceDirectTurnRunner runner, {
  List<ChatMessage> messages = const [],
  List<String>? acks,
  List<String>? deltas,
  String? turnId,
  int maxAttempts = 3,
}) {
  return runner.run(
    client: relay.client(maxAttempts: maxAttempts),
    callId: 'call-1',
    chatId: 'chat-1',
    text: 'what is on my calendar',
    chatMessages: messages,
    onAck: (t) => acks?.add(t),
    onDelta: (t) => deltas?.add(t),
    personaId: 'bmo',
    build: '1.0+1',
    tz: 'CST',
    turnId: turnId,
  );
}

void main() {
  late _FakeRelay relay;
  tearDown(() async => relay.stop());

  test('parses meta, ack, deltas and done; sends the contract body', () async {
    relay = _FakeRelay([
      (req, body) => _stream(req, [
        _meta,
        _sse({'type': 'ack', 'text': 'One sec.'}),
        // A delta split across two writes must still parse.
        'data: {"type":"delta","te',
        'xt":"You have "}\n\n',
        _sse({'type': 'delta', 'text': 'two things.'}),
        _done('You have two things.​<card/>'),
      ]),
    ]);
    await relay.start();
    final history = VoiceCallHistory();
    final acks = <String>[];
    final deltas = <String>[];
    const marked = 'Open card ​⁣[[card:abc]]⁣​';
    final result = await _run(
      relay,
      VoiceDirectTurnRunner(history: history),
      messages: [_msg('m1', 'user', 'hi'), _msg('m2', 'assistant', marked)],
      acks: acks,
      deltas: deltas,
    );
    check(result.outcome).equals(VoiceDirectOutcome.done);
    check(acks).deepEquals(['One sec.']);
    check(deltas).deepEquals(['You have ', 'two things.']);
    check(result.content).equals('You have two things.​<card/>');

    final body = relay.turnBodies.single;
    check(body['v']).equals(1);
    check((body['turn_id'] as String).length).equals(36);
    check(body['call_id']).equals('call-1');
    check(body['chat_id']).equals('chat-1');
    check(body['persona_id']).equals('bmo');
    check(body['text']).equals('what is on my calendar');
    check(body['build']).equals('1.0+1');
    check(body.containsKey('test')).isFalse();
    final sent = (body['history'] as List).cast<Map>();
    check(sent.length).equals(2);
    check(sent[1]['content']).equals(marked); // markers byte for byte
    check(relay.authHeaders.first).equals('Bearer test-key');

    // The turn is kept in the call's history, with the relay's ids.
    final next = history.build([
      _msg('m1', 'user', 'hi'),
      _msg('m2', 'assistant', marked),
    ]);
    check(next.map((e) => e.id).toList()).deepEquals(['m1', 'm2', 'uid', 'aid']);
  });

  test('SSE event: lines name the event when the JSON does not', () async {
    relay = _FakeRelay([
      (req, body) => _stream(req, [
        'event: meta\ndata: {"turn_id":"t1","route":"direct"}\n\n',
        'event: delta\ndata: {"text":"Hi."}\n\n',
        'event: done\ndata: {"turn_id":"t1","assistant_id":"a","content":"Hi."}\n\n',
      ]),
    ]);
    await relay.start();
    final deltas = <String>[];
    final result = await _run(
      relay,
      VoiceDirectTurnRunner(history: VoiceCallHistory()),
      deltas: deltas,
    );
    check(result.outcome).equals(VoiceDirectOutcome.done);
    check(deltas).deepEquals(['Hi.']);
  });

  test('route owui: ack spoken, stream ends, save queue drained, '
      'caller sends the old way', () async {
    relay = _FakeRelay([
      (req, body) => _stream(req, [
        _sse({
          'type': 'meta',
          'turn_id': 't1',
          'lane': 'calendar',
          'route': 'owui',
        }),
        _sse({'type': 'ack', 'text': 'Checking your calendar.'}),
      ]),
    ]);
    await relay.start();
    relay.savedPending = 2;
    final acks = <String>[];
    final deltas = <String>[];
    final history = VoiceCallHistory();
    final result = await _run(
      relay,
      VoiceDirectTurnRunner(history: history),
      acks: acks,
      deltas: deltas,
    );
    check(result.outcome).equals(VoiceDirectOutcome.owui);
    check(acks).deepEquals(['Checking your calendar.']);
    check(deltas).isEmpty();
    check(relay.savedCalls).equals(3); // pending 2, 1, then 0
    check(relay.turnBodies.length).equals(1); // not retried
    check(history.hasDirectTurns).isFalse(); // Open WebUI owns this turn
  });

  test('network error: retries with the same turn_id, never doubles '
      'a delta, and runs the turn once', () async {
    var firstAttemptDone = false;
    relay = _FakeRelay([
      (req, body) async {
        // Send meta and one delta, then drop the connection mid-stream.
        final socket = await req.response.detachSocket(writeHeaders: false);
        String chunk(String text) =>
            '${utf8.encode(text).length.toRadixString(16)}\r\n$text\r\n';
        socket.write(
          'HTTP/1.1 200 OK\r\n'
          'Content-Type: text/event-stream\r\n'
          'Transfer-Encoding: chunked\r\n\r\n',
        );
        socket.write(chunk(_meta));
        socket.write(chunk(_sse({'type': 'delta', 'text': 'First. '})));
        await socket.flush();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        firstAttemptDone = true;
        socket.destroy();
      },
      // The retry gets the stored stream replayed from the start.
      (req, body) => _stream(req, [
        _meta,
        _sse({'type': 'delta', 'text': 'First. '}),
        _sse({'type': 'delta', 'text': 'Second.'}),
        _done('First. Second.'),
      ]),
    ]);
    await relay.start();
    final deltas = <String>[];
    final result = await _run(
      relay,
      VoiceDirectTurnRunner(history: VoiceCallHistory()),
      deltas: deltas,
    );
    check(firstAttemptDone).isTrue();
    check(result.outcome).equals(VoiceDirectOutcome.done);
    check(deltas).deepEquals(['First. ', 'Second.']);
    check(relay.turnBodies.length).equals(2);
    check(relay.turnBodies[0]['turn_id']).equals(relay.turnBodies[1]['turn_id']);
  });

  test('a caller turn_id is kept across retries', () async {
    relay = _FakeRelay([
      (req, body) async {
        req.response.statusCode = 503;
        await req.response.close();
      },
      (req, body) => _stream(req, [_meta, _done('Ok.')]),
    ]);
    await relay.start();
    final result = await _run(
      relay,
      VoiceDirectTurnRunner(history: VoiceCallHistory()),
      turnId: 'fixed-turn-id',
    );
    check(result.outcome).equals(VoiceDirectOutcome.done);
    check(relay.turnBodies.map((b) => b['turn_id']).toList()).deepEquals([
      'fixed-turn-id',
      'fixed-turn-id',
    ]);
  });

  test('404 falls back and switches direct off for the call', () async {
    relay = _FakeRelay([
      (req, body) async {
        req.response.statusCode = 404;
        await req.response.close();
      },
    ]);
    await relay.start();
    final result = await _run(
      relay,
      VoiceDirectTurnRunner(history: VoiceCallHistory()),
    );
    check(result.outcome).equals(VoiceDirectOutcome.fallback);
    check(result.disableDirect).isTrue();
    check(relay.turnBodies.length).equals(1); // no retry on 404
  });

  test('the voice_direct switch off (error event) falls back', () async {
    relay = _FakeRelay([
      (req, body) => _stream(req, [
        _sse({
          'type': 'error',
          'code': 'voice_direct_off',
          'message': 'direct voice is off',
        }),
      ]),
    ]);
    await relay.start();
    final result = await _run(
      relay,
      VoiceDirectTurnRunner(history: VoiceCallHistory()),
    );
    check(result.outcome).equals(VoiceDirectOutcome.fallback);
    check(result.disableDirect).isTrue();
  });

  test('every try failing before any answer falls back, once per try', () async {
    relay = _FakeRelay([
      (req, body) async {
        req.response.statusCode = 502;
        await req.response.close();
      },
    ]);
    await relay.start();
    final result = await _run(
      relay,
      VoiceDirectTurnRunner(history: VoiceCallHistory()),
      maxAttempts: 3,
    );
    check(result.outcome).equals(VoiceDirectOutcome.fallback);
    check(result.disableDirect).isFalse();
    check(relay.turnBodies.length).equals(3);
  });

  test('an error after deltas fails the turn, not a second send', () async {
    relay = _FakeRelay([
      (req, body) => _stream(req, [
        _meta,
        _sse({'type': 'delta', 'text': 'Part one.'}),
        _sse({'type': 'error', 'code': 'engine', 'message': 'engine died'}),
      ]),
    ]);
    await relay.start();
    final result = await _run(
      relay,
      VoiceDirectTurnRunner(history: VoiceCallHistory()),
    );
    check(result.outcome).equals(VoiceDirectOutcome.failed);
    check(result.content).equals('Part one.');
    check(result.error).equals('engine died');
  });

  test('cancel mid-stream keeps what was heard in the history', () async {
    final gate = Completer<void>();
    final heard = Completer<void>();
    relay = _FakeRelay([
      (req, body) async {
        req.response
          ..bufferOutput = false
          ..statusCode = 200
          ..headers.contentType = ContentType(
            'text',
            'event-stream',
            charset: 'utf-8',
          )
          ..write(_meta)
          ..write(_sse({'type': 'delta', 'text': 'Well, '}));
        await req.response.flush();
        await gate.future.timeout(const Duration(seconds: 3), onTimeout: () {});
        await req.response.close().catchError((Object _) {});
      },
    ]);
    await relay.start();
    final history = VoiceCallHistory();
    final runner = VoiceDirectTurnRunner(history: history);
    final result = runner.run(
      client: relay.client(),
      callId: 'c',
      chatId: 'chat-1',
      text: 'tell me a story',
      chatMessages: const [],
      onAck: (_) {},
      onDelta: (_) {
        if (!heard.isCompleted) heard.complete();
      },
    );
    await heard.future.timeout(const Duration(seconds: 3));
    runner.cancel();
    final done = await result.timeout(const Duration(seconds: 4));
    gate.complete();
    check(done.outcome).equals(VoiceDirectOutcome.cancelled);
    check(history.turns.single.interrupted).isTrue();
    check(history.turns.single.assistant!.content).equals('Well, ');
  });

  test('Musey writes nothing to Open WebUI on the direct path', () async {
    relay = _FakeRelay([
      (req, body) => _stream(req, [_meta, _done('Hi.')]),
      (req, body) => _stream(req, [
        _sse({'type': 'meta', 'turn_id': 't2', 'route': 'owui'}),
      ]),
    ]);
    await relay.start();
    final runner = VoiceDirectTurnRunner(history: VoiceCallHistory());
    await _run(relay, runner);
    await _run(relay, runner);
    // Only the relay's voice routes were touched; no chat save, no message
    // upsert, no completion.
    check(
      relay.requests.toSet(),
    ).deepEquals({'POST /voice/turn', 'GET /voice/saved'});

    for (final file in [
      'lib/features/chat/voice_mode/voice_direct_client.dart',
      'lib/features/chat/voice_mode/voice_direct_turn.dart',
      'lib/features/chat/voice_mode/voice_call_history.dart',
    ]) {
      final source = File(file).readAsStringSync();
      check(source).not((s) => s.contains('durableSend'));
      check(source).not((s) => s.contains('apiServiceProvider'));
      check(source).not((s) => s.contains('chat_send'));
    }
  });

  group('VoiceCallHistory', () {
    test('puts direct turns back in order among the chat messages', () {
      final history = VoiceCallHistory()
        ..record(
          atIndex: 2,
          user: const VoiceHistoryEntry(id: 'u1', role: 'user', content: 'a'),
          assistant: const VoiceHistoryEntry(
            id: 'a1',
            role: 'assistant',
            content: 'b',
          ),
        )
        ..record(
          atIndex: 2,
          user: const VoiceHistoryEntry(id: 'u2', role: 'user', content: 'c'),
          assistant: const VoiceHistoryEntry(
            id: 'a2',
            role: 'assistant',
            content: 'd',
          ),
        );
      // An owui-routed turn later added m3, m4 to the chat itself.
      final built = history.build([
        _msg('m1', 'user', 'x'),
        _msg('m2', 'assistant', 'y'),
        _msg('m3', 'user', 'z'),
        _msg('m4', 'assistant', 'w'),
      ]);
      check(
        built.map((e) => e.id).toList(),
      ).deepEquals(['m1', 'm2', 'u1', 'a1', 'u2', 'a2', 'm3', 'm4']);
    });

    test('skips streaming and empty messages, and caps the length', () {
      final history = VoiceCallHistory();
      final messages = [
        for (var i = 0; i < 60; i++) _msg('m$i', 'user', 'text $i'),
        _msg('empty', 'assistant', ''),
        _msg('s', 'assistant', 'x').copyWith(isStreaming: true),
      ];
      final built = history.build(messages);
      check(built.length).equals(VoiceCallHistory.maxEntries);
      check(built.last.id).equals('m59');
    });
  });

  test('newVoiceTurnId is a UUID v4', () {
    final id = newVoiceTurnId();
    check(
      RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      ).hasMatch(id),
    ).isTrue();
    check(newVoiceTurnId()).not((s) => s.equals(id));
  });
}
