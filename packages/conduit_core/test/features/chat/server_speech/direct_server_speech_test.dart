import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/chat/server_speech/direct_server_speech.dart';
import 'package:conduit_core/features/chat/server_speech/direct_voice_provider_settings.dart';
import 'package:conduit_core/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit_core/features/direct_connections/services/direct_http_client.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

final class _Adapter implements HttpClientAdapter {
  _Adapter(this.reply);

  final ResponseBody Function() reply;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelOnError,
  ) async {
    requests.add(options);
    return reply();
  }

  @override
  void close({bool force = false}) {}
}

const _settings = DirectVoiceProviderSettings(
  profileId: 'voice',
  transcriptionModel: 'gpt-4o-mini-transcribe',
  speechModel: 'gpt-4o-mini-tts',
  speechVoice: 'coral',
);

DirectServerSpeech _speech(
  HttpClientAdapter adapter, {
  DirectConnectionProfile? profile,
  DirectVoiceProviderSettings settings = _settings,
}) {
  final pool = DirectHttpClientPool(
    // The real configuration, so the key, headers and api-version are the
    // ones a chat request would carry.
    dioFactory: (profile) {
      final dio = Dio()..httpClientAdapter = adapter;
      const DirectHttpClientFactory().configure(dio, profile);
      return dio;
    },
  );
  addTearDown(pool.dispose);
  return DirectServerSpeech(
    profile:
        profile ??
        DirectConnectionProfile(
          id: 'voice',
          name: 'OpenAI',
          adapterKey: kOpenAiCompatibleAdapterKey,
          baseUrl: 'https://api.openai.com/v1',
          apiKey: 'sk-test',
        ),
    settings: settings,
    clientPool: pool,
  );
}

void main() {
  streamingTests();

  test('transcribes through audio/transcriptions with the model', () async {
    final adapter = _Adapter(
      () => ResponseBody.fromString(
        '{"text":"Hello there"}',
        200,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
      ),
    );

    final transcript = await _speech(adapter).transcribe(
      Uint8List.fromList([1, 2]),
      fileName: 'clip.wav',
      mimeType: 'audio/wav',
      language: 'en',
    );

    check(transcript).equals('Hello there');
    final request = adapter.requests.single;
    check(request.uri.toString())
        .equals('https://api.openai.com/v1/audio/transcriptions');
    check(request.headers['Authorization']).equals('Bearer sk-test');
    final form = request.data as FormData;
    check(Map.fromEntries(form.fields)).deepEquals({
      'model': 'gpt-4o-mini-transcribe',
      'language': 'en',
      'response_format': 'verbose_json',
    });
    check(form.files.single.value.filename).equals('clip.wav');
  });

  test('speaks through audio/speech with the chosen voice', () async {
    final adapter = _Adapter(
      () => ResponseBody.fromBytes(
        [7, 7, 7],
        200,
        headers: {
          Headers.contentTypeHeader: ['audio/mpeg'],
        },
      ),
    );

    final speech = await _speech(adapter)
        .synthesize('Hi.', preferredVoice: 'an-open-webui-voice', speed: 1.25);

    check(speech.bytes).deepEquals([7, 7, 7]);
    check(speech.mimeType).equals('audio/mpeg');
    final request = adapter.requests.single;
    check(request.uri.path).equals('/v1/audio/speech');
    check(request.headers['Accept']).equals('audio/mpeg');
    // The voice picked for another backend never reaches this one.
    check(request.data).isA<Map<String, dynamic>>().deepEquals({
      'model': 'gpt-4o-mini-tts',
      'input': 'Hi.',
      'voice': 'coral',
      'response_format': 'mp3',
      'speed': 1.25,
    });
  });

  test('an Azure connection keeps its key header and api-version', () async {
    final adapter = _Adapter(
      () => ResponseBody.fromString(
        '{"text":"ok"}',
        200,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
      ),
    );

    await _speech(
      adapter,
      profile: DirectConnectionProfile(
        id: 'voice',
        name: 'Azure',
        adapterKey: kOpenAiCompatibleAdapterKey,
        baseUrl: 'https://example.openai.azure.com/openai/v1',
        apiKey: 'azure-key',
        apiKeyAuthMode: DirectApiKeyAuthMode.apiKeyHeader,
        apiVersion: 'preview',
      ),
    ).transcribe(
      Uint8List.fromList([1]),
      fileName: 'clip.wav',
      mimeType: 'audio/wav',
    );

    final request = adapter.requests.single;
    check(request.headers['api-key']).equals('azure-key');
    check(request.headers.containsKey('Authorization')).isFalse();
    check(request.uri.queryParameters).deepEquals({'api-version': 'preview'});
  });

  test('a direction without its models is not offered or sent', () async {
    final adapter = _Adapter(() => throw StateError('no request expected'));
    final speech = _speech(
      adapter,
      settings: const DirectVoiceProviderSettings(
        profileId: 'voice',
        transcriptionModel: 'whisper-1',
        speechModel: 'tts-1',
      ),
    );

    check(speech.canTranscribe).isTrue();
    check(speech.canSynthesize).isFalse();
    await check(speech.synthesize('Hi.')).throws<StateError>();
    check(adapter.requests).isEmpty();
  });

  test('choosing a connection fills OpenAI models and keeps edits', () {
    DirectConnectionProfile profile(String id, String url) =>
        DirectConnectionProfile(
          id: id,
          name: id,
          adapterKey: kOpenAiCompatibleAdapterKey,
          baseUrl: url,
        );
    final openAi = profile('openai', 'https://api.openai.com/v1');
    final groq = profile('groq', 'https://api.groq.com/openai/v1');

    final filled = DirectVoiceProviderSettings.forConnection(openAi);
    check(filled.canTranscribe).isTrue();
    check(filled.canSynthesize).isTrue();

    // Another server's model names are its own to enter.
    final blank = DirectVoiceProviderSettings.forConnection(
      groq,
      current: filled,
    );
    check(blank).equals(const DirectVoiceProviderSettings(profileId: 'groq'));

    // Picking the same connection again keeps what was typed.
    final edited = blank.withField(
      DirectVoiceProviderField.transcriptionModel,
      '  whisper-large-v3 ',
    );
    check(edited.transcriptionModel).equals('whisper-large-v3');
    check(DirectVoiceProviderSettings.forConnection(groq, current: edited))
        .equals(edited);
    check(
      edited
          .withField(DirectVoiceProviderField.transcriptionModel, '  ')
          .transcriptionModel,
    ).isNull();
  });

  test('settings survive a round trip and need a connection', () {
    const settings = DirectVoiceProviderSettings(
      profileId: 'voice',
      transcriptionModel: 'whisper-1',
      realtimeModel: 'gpt-realtime',
      realtimeInstructions: '  Be brief.\n',
    );

    check(
      DirectVoiceProviderSettings.fromJson(
        jsonDecode(jsonEncode(settings.toJson())),
      ),
    ).equals(settings);
    check(DirectVoiceProviderSettings.fromJson({'profile_id': ' '})).isNull();
    check(DirectVoiceProviderSettings.fromJson('garbage')).isNull();
  });
}

/// A server whose audio body is held open by the test, so what the client does
/// before the body ends can be seen.
final class _StreamingAdapter implements HttpClientAdapter {
  final body = StreamController<Uint8List>();
  final List<RequestOptions> requests = [];
  bool cancelled = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelOnError,
  ) async {
    requests.add(options);
    unawaited(
      cancelOnError?.then((_) {
        cancelled = true;
        if (!body.isClosed) body.close();
      }),
    );
    return ResponseBody(
      body.stream,
      200,
      headers: {
        Headers.contentTypeHeader: ['audio/mpeg'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

const _streamingSettings = DirectVoiceProviderSettings(
  profileId: 'voice',
  speechModel: 'tts-model',
  speechVoice: 'a-voice',
  streamSpeech: true,
);

void streamingTests() {
  group('streamed speech', () {
    test('asks for a stream and plays before the body ends', () async {
      final adapter = _StreamingAdapter();
      final speech = _speech(adapter, settings: _streamingSettings);
      check(speech.streamsSpeech).isTrue();

      final pending = speech.synthesizeClip('Hi there.');
      adapter.body.add(Uint8List.fromList([1, 2, 3]));
      final clip = await pending;

      // The body has not ended, yet the clip is already handed over.
      final audio = clip.progressive!;
      check(audio.isDone).isFalse();
      check(audio.length).equals(3);
      check(audio.mimeType).equals('audio/mpeg');
      check(adapter.requests.single.data)
          .isA<Map<String, dynamic>>()
          .deepEquals({
            'model': 'tts-model',
            'input': 'Hi there.',
            'voice': 'a-voice',
            'response_format': 'mp3',
            'stream': true,
            'streaming_interval': 0.5,
          });

      final heard = <int>[];
      final reading = audio.read().listen(heard.addAll);
      adapter.body.add(Uint8List.fromList([4, 5]));
      await adapter.body.close();
      await reading.asFuture<void>();
      check(heard).deepEquals([1, 2, 3, 4, 5]);
      check(audio.isDone).isTrue();
    });

    test('cancelling the clip cancels the request', () async {
      final adapter = _StreamingAdapter();
      final speech = _speech(adapter, settings: _streamingSettings);
      final pending = speech.synthesizeClip('Hi there.');
      adapter.body.add(Uint8List.fromList([1]));
      final audio = (await pending).progressive!;

      audio.cancel();
      await pumpEventQueue();

      check(adapter.cancelled).isTrue();
      check(audio.isDone).isTrue();
    });

    test('a response with no audio fails so the caller can retry', () async {
      final adapter = _StreamingAdapter();
      final speech = _speech(adapter, settings: _streamingSettings);
      final pending = speech.synthesizeClip('Hi there.');
      final outcome = check(pending).throws<StateError>();
      await adapter.body.close();
      await outcome;
    });

    test('streaming off asks for a whole clip with no stream fields', () async {
      final adapter = _Adapter(
        () => ResponseBody.fromBytes(
          [7, 7],
          200,
          headers: {
            Headers.contentTypeHeader: ['audio/mpeg'],
          },
        ),
      );
      final speech = _speech(
        adapter,
        settings: _streamingSettings.withStreamSpeech(false),
      );

      check(speech.streamsSpeech).isFalse();
      final clip = await speech.synthesizeClip('Hi.');

      check(clip.progressive).isNull();
      check(clip.whole!.bytes).deepEquals([7, 7]);
      check(adapter.requests.single.data as Map)
          .not((it) => it.containsKey('stream'));
    });

    test('a body that is not chunked plays the same', () async {
      final adapter = _Adapter(
        () => ResponseBody.fromBytes(
          [1, 2, 3, 4],
          200,
          headers: {
            Headers.contentTypeHeader: ['audio/mpeg'],
          },
        ),
      );
      final clip = await _speech(
        adapter,
        settings: _streamingSettings,
      ).synthesizeClip('Hi.');

      final audio = clip.progressive!;
      check(await audio.read().expand((piece) => piece).toList())
          .deepEquals([1, 2, 3, 4]);
    });

    test('streaming is stored with the settings and off by default', () {
      check(const DirectVoiceProviderSettings(profileId: 'voice').streamSpeech)
          .isFalse();
      final stored = _streamingSettings.toJson();
      check(stored['stream_speech']).equals(true);
      check(DirectVoiceProviderSettings.fromJson(stored))
          .isNotNull()
          .has((it) => it.streamSpeech, 'streamSpeech')
          .isTrue();
      check(const DirectVoiceProviderSettings(profileId: 'voice').toJson())
          .not((it) => it.containsKey('stream_speech'));
    });
  });
}
