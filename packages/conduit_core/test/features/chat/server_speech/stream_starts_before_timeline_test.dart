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

/// A relay whose stream sends a first chunk at once and holds the rest until
/// [release] is called, and whose timeline answer never comes until
/// [answerTimeline] is called.
final class _Slow implements HttpClientAdapter {
  final rest = Completer<void>();
  final timeline = Completer<void>();
  final List<String> log = [];

  void release() => rest.complete();
  void answerTimeline() => timeline.complete();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelOnError,
  ) async {
    if (options.path.contains('audio/visemes/')) {
      log.add('timeline-asked');
      await timeline.future;
      log.add('timeline-answered');
      return ResponseBody.fromString(
        jsonEncode(_body()),
        200,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
      );
    }
    Stream<Uint8List> chunks() async* {
      yield Uint8List.fromList([1, 2, 3, 4]);
      await rest.future;
      log.add('last-byte');
      yield Uint8List.fromList([5, 6]);
    }

    return ResponseBody(
      chunks(),
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
      speechVoice: 'uncle-ruckus-5',
      streamSpeech: stream,
    ),
    clientPool: pool,
  );
}

void main() {
  test(
    'a streamed chunk is readable before the last byte and before the '
    'timeline fetch resolves',
    () async {
      VisemeStore.instance.clear();
      final adapter = _Slow();
      final speech = _speech(adapter, stream: true);
      final clip = await speech
          .synthesizeClip('hello')
          .timeout(const Duration(seconds: 2));
      final progressive = clip.progressive!;
      final first = await progressive
          .read()
          .first
          .timeout(const Duration(seconds: 2));
      check(first).deepEquals([1, 2, 3, 4]);
      // Playback could start here: the stream is open, no timeline asked.
      check(progressive.isDone).isFalse();
      check(adapter.log).isEmpty();

      adapter.release();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      check(progressive.isDone).isTrue();
      // The timeline is asked for only after the last byte, never awaited, and
      // its answer still pending changes nothing about the finished clip.
      check(adapter.log).deepEquals(['last-byte', 'timeline-asked']);
      check(VisemeStore.instance['abcdef0123456789']).isNull();

      adapter.answerTimeline();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      check(VisemeStore.instance['abcdef0123456789']).isNotNull();
    },
  );
}
