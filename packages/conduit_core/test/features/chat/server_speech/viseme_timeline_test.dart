import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/chat/server_speech/direct_server_speech.dart';
import 'package:conduit_core/features/chat/server_speech/direct_voice_provider_settings.dart';
import 'package:conduit_core/features/chat/server_speech/viseme_timeline.dart';
import 'package:conduit_core/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit_core/features/direct_connections/services/direct_http_client.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

Map<String, Object?> _body() => {
  'id': 'abcdef0123456789',
  'duration': 1.2,
  'shapes': [
    'closed',
    'slight',
    'mid',
    'open',
    'wide',
    'oo',
    'ee',
    'fv',
    'mbp',
  ],
  'timeline': [
    {'t': 0.0, 'shape': 'closed'},
    {'t': 0.1, 'shape': 'open'},
    {'t': 0.35, 'shape': 'wide'},
    {'t': 1.2, 'shape': 'closed'},
  ],
  'ms': 3,
};

VisemeTimeline _ready() =>
    (parseVisemeAnswer(200, _body()) as VisemeReady).timeline;

final class _Router implements HttpClientAdapter {
  _Router({this.visemeStatus = 200});

  final int visemeStatus;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelOnError,
  ) async {
    requests.add(options);
    if (options.path.contains('audio/visemes/')) {
      return ResponseBody.fromString(
        visemeStatus == 200 ? jsonEncode(_body()) : '{"pending":true}',
        visemeStatus,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
      );
    }
    return ResponseBody.fromBytes(
      [1, 2, 3, 4],
      200,
      headers: {
        Headers.contentTypeHeader: ['audio/mpeg'],
        'x-viseme-id': ['abcdef0123456789'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

DirectServerSpeech _speech(HttpClientAdapter adapter, {bool stream = false}) {
  final pool = DirectHttpClientPool(
    dioFactory: (profile) {
      final dio = Dio()..httpClientAdapter = adapter;
      const DirectHttpClientFactory().configure(dio, profile);
      return dio;
    },
  );
  addTearDown(pool.dispose);
  return DirectServerSpeech(
    profile: DirectConnectionProfile(
      id: 'voice',
      name: 'Relay',
      adapterKey: kOpenAiCompatibleAdapterKey,
      baseUrl: 'http://relay.test:1237/v1',
      apiKey: 'k',
    ),
    settings: DirectVoiceProviderSettings(
      profileId: 'voice',
      speechModel: 'custom',
      speechVoice: 'sample-voice-1',
      streamSpeech: stream,
    ),
    clientPool: pool,
  );
}

void main() {
  group('parseVisemeAnswer', () {
    test('200 with a timeline is ready, times in ms', () {
      final answer = parseVisemeAnswer(200, _body());
      check(answer).isA<VisemeReady>();
      final timeline = (answer as VisemeReady).timeline;
      check(timeline.id).equals('abcdef0123456789');
      check(timeline.durationMs).equals(1200);
      check(timeline.keys.map((k) => k.atMs).toList())
          .deepEquals([0, 100, 350, 1200]);
    });

    test('202 is pending', () {
      check(parseVisemeAnswer(202, {'pending': true})).isA<VisemePending>();
    });

    test('404, other statuses and unreadable bodies are unavailable', () {
      check(parseVisemeAnswer(404, {'error': 'x'})).isA<VisemeUnavailable>();
      check(parseVisemeAnswer(500, null)).isA<VisemeUnavailable>();
      check(parseVisemeAnswer(null, null)).isA<VisemeUnavailable>();
      check(parseVisemeAnswer(200, 'text')).isA<VisemeUnavailable>();
      check(parseVisemeAnswer(200, {'timeline': []})).isA<VisemeUnavailable>();
      check(
        parseVisemeAnswer(200, {
          'timeline': [
            {'t': 'x', 'shape': 1},
            {'shape': 'open'},
          ],
        }),
      ).isA<VisemeUnavailable>();
    });

    test('entries out of order are sorted, bad ones skipped', () {
      final answer = parseVisemeAnswer(200, {
        'timeline': [
          {'t': 0.5, 'shape': 'wide'},
          {'t': -1, 'shape': 'oo'},
          {'t': 0.0, 'shape': 'closed'},
        ],
      });
      final keys = (answer as VisemeReady).timeline.keys;
      check(keys.map((k) => k.shape).toList()).deepEquals(['closed', 'wide']);
    });
  });

  group('VisemeTimeline.shapeAt', () {
    test('a shape holds until the next entry', () {
      final t = _ready();
      check(t.shapeAt(0)).equals('closed');
      check(t.shapeAt(99)).equals('closed');
      check(t.shapeAt(100)).equals('open');
      check(t.shapeAt(349)).equals('open');
      check(t.shapeAt(350)).equals('wide');
      check(t.shapeAt(1199)).equals('wide');
    });

    test('at the end and past it the last entry holds', () {
      final t = _ready();
      check(t.shapeAt(1200)).equals('closed');
      check(t.shapeAt(60000)).equals('closed');
    });

    test('before the first entry there is no shape', () {
      check(_ready().shapeAt(-1)).isNull();
    });
  });

  group('VisemeStore', () {
    test('keeps the newest ids, tells listeners, ignores a null id', () {
      final store = VisemeStore(capacity: 2);
      var heard = 0;
      store.addListener(() => heard++);
      store.put('a', _ready());
      store.put('b', _ready());
      store.put('c', _ready());
      check(heard).equals(3);
      check(store['a']).isNull();
      check(store['b']).isNotNull();
      check(store['c']).isNotNull();
      check(store[null]).isNull();
    });
  });

  group('asking the relay', () {
    test(
      'a whole clip asks for visemes, keeps the id, fetches the timeline',
      () async {
        VisemeStore.instance.clear();
        final adapter = _Router();
        final speech = _speech(adapter);
        final clip = await speech.synthesize('hello');
        check(adapter.requests.first.headers['x-visemes']).equals('1');
        check(SpeechVisemes.idOf(clip.bytes)).equals('abcdef0123456789');
        await Future<void>.delayed(const Duration(milliseconds: 50));
        final fetch = adapter.requests.last;
        check(fetch.method).equals('GET');
        check(fetch.path).contains('audio/visemes/abcdef0123456789');
        check(fetch.queryParameters['wait']).equals(1500);
        check(VisemeStore.instance['abcdef0123456789']).isNotNull();
      },
    );

    test('a stream asks too and fetches after its last byte', () async {
      VisemeStore.instance.clear();
      final adapter = _Router();
      final speech = _speech(adapter, stream: true);
      final clip = await speech.synthesizeClip('hello');
      final progressive = clip.progressive!;
      check(adapter.requests.first.headers['x-visemes']).equals('1');
      check(progressive.visemeId).equals('abcdef0123456789');
      await Future<void>.delayed(const Duration(milliseconds: 80));
      check(progressive.isDone).isTrue();
      final fetch = adapter.requests.last;
      check(fetch.path).contains('audio/visemes/abcdef0123456789');
      check(fetch.queryParameters['wait']).equals(5000);
      check(VisemeStore.instance['abcdef0123456789']).isNotNull();
    });

    test('a pending answer leaves no timeline and does not throw', () async {
      VisemeStore.instance.clear();
      final adapter = _Router(visemeStatus: 202);
      await _speech(adapter).synthesize('hello');
      await Future<void>.delayed(const Duration(milliseconds: 80));
      check(VisemeStore.instance['abcdef0123456789']).isNull();
    });
  });
}
