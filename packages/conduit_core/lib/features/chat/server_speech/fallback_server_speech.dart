import 'dart:typed_data';

import 'package:conduit_core/utils/debug_logger.dart';

import 'server_speech.dart';

/// The Voice provider in front of a chat's own backend.
///
/// Every request goes to [primary] first. When it is not set up for the job
/// or the request fails, the same request goes to [fallback] and the failure
/// is logged, so voice keeps working when the Voice provider is down.
final class FallbackServerSpeech implements StreamingServerSpeech {
  const FallbackServerSpeech({required this.primary, required this.fallback});

  final ServerSpeechProvider primary;
  final ServerSpeechProvider fallback;

  @override
  ServerSpeechSource get source =>
      primary.canSynthesize || primary.canTranscribe
      ? primary.source
      : fallback.source;

  @override
  bool get canTranscribe => primary.canTranscribe || fallback.canTranscribe;

  @override
  bool get canSynthesize => primary.canSynthesize || fallback.canSynthesize;

  /// The voice follows whoever speaks: the primary's own voice when it can,
  /// else the fallback's list.
  @override
  bool get offersVoiceChoice =>
      !primary.canSynthesize && fallback.offersVoiceChoice;

  @override
  bool get streamsSpeech {
    final primary = this.primary;
    return primary is StreamingServerSpeech && primary.streamsSpeech;
  }

  @override
  Future<String> transcribe(
    Uint8List audio, {
    required String fileName,
    required String mimeType,
    String? language,
  }) async {
    if (primary.canTranscribe) {
      try {
        return await primary.transcribe(
          audio,
          fileName: fileName,
          mimeType: mimeType,
          language: language,
        );
      } catch (error) {
        _logFallback('transcribe', error);
      }
    }
    return fallback.transcribe(
      audio,
      fileName: fileName,
      mimeType: mimeType,
      language: language,
    );
  }

  @override
  Future<SynthesizedSpeech> synthesize(
    String text, {
    String? preferredVoice,
    double? speed,
  }) async {
    if (primary.canSynthesize) {
      try {
        return await primary.synthesize(
          text,
          preferredVoice: preferredVoice,
          speed: speed,
        );
      } catch (error) {
        _logFallback('synthesize', error);
      }
    }
    return fallback.synthesize(
      text,
      preferredVoice: preferredVoice,
      speed: speed,
    );
  }

  @override
  Future<SpeechClip> synthesizeClip(
    String text, {
    String? preferredVoice,
    double? speed,
  }) async {
    final primary = this.primary;
    if (primary.canSynthesize) {
      try {
        if (primary is StreamingServerSpeech) {
          return await primary.synthesizeClip(
            text,
            preferredVoice: preferredVoice,
            speed: speed,
          );
        }
        return SpeechClip.whole(
          await primary.synthesize(
            text,
            preferredVoice: preferredVoice,
            speed: speed,
          ),
        );
      } catch (error) {
        _logFallback('synthesize', error);
      }
    }
    return SpeechClip.whole(
      await fallback.synthesize(
        text,
        preferredVoice: preferredVoice,
        speed: speed,
      ),
    );
  }

  void _logFallback(String operation, Object error) {
    DebugLogger.warning(
      'voice-provider-fallback',
      scope: 'speech',
      data: {
        'operation': operation,
        'error': error.toString(),
        'fallback': fallback.source.name,
      },
    );
  }
}
