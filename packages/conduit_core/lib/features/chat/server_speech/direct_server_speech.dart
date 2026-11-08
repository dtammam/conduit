import 'transcription_confidence.dart';

import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'package:conduit_core/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit_core/features/direct_connections/services/direct_http_client.dart';
import 'package:conduit_core/features/chat/voice_mode/voice_event_log.dart';
import 'package:conduit_core/ports/progressive_audio.dart';
import 'package:conduit_core/utils/debug_logger.dart';

import 'direct_voice_provider_settings.dart';
import 'viseme_timeline.dart';
import 'server_speech.dart';
import 'transcription_response.dart';

/// Speech through the Voice provider's OpenAI-compatible audio endpoints,
/// reached with the same client, key, headers and certificates its chats use.
final class DirectServerSpeech
    implements StreamingServerSpeech, SpeechVoiceIdentity {
  const DirectServerSpeech({
    required DirectConnectionProfile profile,
    required DirectVoiceProviderSettings settings,
    required DirectHttpClientPool clientPool,
  }) : _profile = profile,
       _settings = settings,
       _clientPool = clientPool;

  final DirectConnectionProfile _profile;
  final DirectVoiceProviderSettings _settings;
  final DirectHttpClientPool _clientPool;

  @override
  ServerSpeechSource get source => ServerSpeechSource.direct;

  @override
  bool get canTranscribe => _settings.canTranscribe;

  @override
  bool get canSynthesize => _settings.canSynthesize;

  @override
  bool get offersVoiceChoice => false;

  @override
  bool get streamsSpeech => _settings.streamSpeech && _settings.canSynthesize;

  @override
  String get voiceKey =>
      'direct|${_settings.speechModel ?? ''}|${_settings.speechVoice ?? ''}';

  /// The interval, in seconds, a streaming server cuts its audio at.
  static const double streamingIntervalSeconds = 0.5;

  @override
  Future<String> transcribe(
    Uint8List audio, {
    required String fileName,
    required String mimeType,
    String? language,
  }) async {
    final model = _settings.transcriptionModel;
    if (!_settings.canTranscribe || model == null) {
      throw StateError('The Voice provider has no transcription model.');
    }
    final lease = _clientPool.acquire(_profile);
    try {
      Future<Response<Object?>> post(String format) => lease.dio.post<Object?>(
        'audio/transcriptions',
        data: FormData.fromMap({
          'file': MultipartFile.fromBytes(
            audio,
            filename: fileName,
            contentType: DioMediaType.parse(mimeType),
          ),
          'model': model,
          if (language != null && language.trim().isNotEmpty)
            'language': language.trim(),
          'response_format': format,
        }),
        options: Options(headers: VoiceEventLog.instance.turnHeaders),
      );
      // The verbose answer carries Whisper's confidence, which tells a real
      // interruption from the assistant's own voice; a server that does not
      // offer it gets the plain request.
      Response<Object?> response;
      try {
        response = await post('verbose_json');
      } on DioException catch (error) {
        final status = error.response?.statusCode;
        if (status != 400 && status != 422) rethrow;
        response = await post('json');
      }
      final data = response.data;
      if (data is! Map) return '';
      final json = data.map((key, value) => MapEntry(key.toString(), value));
      final text = transcriptionResponseText(json) ?? '';
      final confidence = TranscriptionConfidence.fromVerboseJson(json);
      if (confidence != null) {
        TranscriptionConfidenceLog.instance.record(text, confidence);
      }
      return text;
    } finally {
      lease.release();
    }
  }

  @override
  Future<SynthesizedSpeech> synthesize(
    String text, {
    String? preferredVoice,
    double? speed,
  }) async {
    final model = _settings.speechModel;
    final voice = _settings.speechVoice;
    if (!_settings.canSynthesize || model == null || voice == null) {
      throw StateError('The Voice provider has no speech model and voice.');
    }
    final lease = _clientPool.acquire(_profile);
    try {
      final response = await lease.dio.post<List<int>>(
        'audio/speech',
        data: {
          'model': model,
          'input': text,
          'voice': voice,
          'response_format': 'mp3',
          'speed': ?speed,
        },
        options: Options(
          responseType: ResponseType.bytes,
          headers: {
            'Accept': 'audio/mpeg',
            'x-visemes': '1',
            ...VoiceEventLog.instance.turnHeaders,
          },
        ),
      );
      final bytes = response.data;
      if (bytes == null || bytes.isEmpty) {
        throw StateError('The Voice provider returned no audio.');
      }
      final visemeId = response.headers.value('x-viseme-id');
      if (visemeId != null && visemeId.isNotEmpty) {
        // A whole clip's timeline is ready within milliseconds.
        unawaited(_fetchVisemes(visemeId, 1500));
      }
      final contentType = response.headers.value(Headers.contentTypeHeader);
      final audio = Uint8List.fromList(bytes);
      SpeechVisemes.tag(audio, visemeId);
      return (
        bytes: audio,
        mimeType: contentType != null && contentType.startsWith('audio/')
            ? contentType.split(';').first.trim()
            : 'audio/mpeg',
      );
    } finally {
      lease.release();
    }
  }

  @override
  Future<SpeechClip> synthesizeClip(
    String text, {
    String? preferredVoice,
    double? speed,
  }) async {
    if (!streamsSpeech) {
      return SpeechClip.whole(
        await synthesize(text, preferredVoice: preferredVoice, speed: speed),
      );
    }
    final model = _settings.speechModel!;
    final voice = _settings.speechVoice!;
    final lease = _clientPool.acquire(_profile);
    final cancel = CancelToken();
    var leaseReleased = false;
    void release() {
      if (leaseReleased) return;
      leaseReleased = true;
      lease.release();
    }

    final firstBytes = Completer<void>();
    try {
      final response = await lease.dio.post<ResponseBody>(
        'audio/speech',
        data: {
          'model': model,
          'input': text,
          'voice': voice,
          'response_format': 'mp3',
          'stream': true,
          'streaming_interval': streamingIntervalSeconds,
          'speed': ?speed,
        },
        cancelToken: cancel,
        options: Options(
          responseType: ResponseType.stream,
          headers: {
            'Accept': 'audio/mpeg',
            'x-visemes': '1',
            ...VoiceEventLog.instance.turnHeaders,
          },
        ),
      );
      final body = response.data;
      if (body == null) {
        throw StateError('The Voice provider returned no audio.');
      }
      final contentType = response.headers.value(Headers.contentTypeHeader);
      final mimeType = contentType != null && contentType.startsWith('audio/')
          ? contentType.split(';').first.trim()
          : 'audio/mpeg';
      final streamed = ProgressiveAudio(
        mimeType: mimeType,
        onCancel: () {
          if (!cancel.isCancelled) cancel.cancel('speech cancelled');
        },
      )..visemeId = response.headers.value('x-viseme-id');
      unawaited(
        _pump(body.stream, streamed, firstBytes, release).catchError((_) {}),
      );
      await firstBytes.future;
      return SpeechClip.progressive(streamed);
    } catch (_) {
      release();
      rethrow;
    }
  }

  Future<void> _pump(
    Stream<Uint8List> body,
    ProgressiveAudio into,
    Completer<void> firstBytes,
    void Function() release,
  ) async {
    try {
      await for (final piece in body) {
        if (into.isCancelled) break;
        into.add(piece);
        if (!firstBytes.isCompleted && into.length > 0) firstBytes.complete();
      }
      if (!firstBytes.isCompleted) {
        firstBytes.completeError(
          StateError('The Voice provider returned no audio.'),
        );
      }
      into.close();
      // A stream's timeline is built when its last byte has been sent.
      final visemeId = into.visemeId;
      if (visemeId != null && visemeId.isNotEmpty && !into.isCancelled) {
        unawaited(_fetchVisemes(visemeId, 5000));
      }
    } catch (error) {
      if (!firstBytes.isCompleted) {
        firstBytes.completeError(error);
      } else if (!into.isCancelled) {
        DebugLogger.warning(
          'voice-provider-stream-cut',
          data: {'error': error.toString()},
        );
      }
      into.close(error);
    } finally {
      release();
    }
  }

  /// Fetches the viseme timeline [id] into [VisemeStore.instance], holding
  /// the request up to [waitMs] while the relay builds it. Never throws: no
  /// timeline just means the mouth keeps following loudness.
  Future<void> _fetchVisemes(String id, int waitMs) async {
    final lease = _clientPool.acquire(_profile);
    try {
      for (var attempt = 0; attempt < 2; attempt++) {
        final response = await lease.dio.get<Object?>(
          'audio/visemes/$id',
          queryParameters: {'wait': waitMs},
          options: Options(
            validateStatus: (status) => status != null && status < 500,
            receiveTimeout: Duration(milliseconds: waitMs + 3000),
          ),
        );
        final answer = parseVisemeAnswer(response.statusCode, response.data);
        switch (answer) {
          case VisemeReady(:final timeline):
            VisemeStore.instance.put(id, timeline);
            return;
          case VisemePending():
            continue;
          case VisemeUnavailable():
            return;
        }
      }
    } catch (_) {
      // Loudness mode.
    } finally {
      lease.release();
    }
  }
}
