import 'package:dio/dio.dart';
import 'package:riverpod/riverpod.dart';

import 'package:conduit_core/features/chat/server_speech/server_speech_providers.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';

import 'voice_event_log.dart';

/// A sender that posts to `/musey/voice-log` on the host of the Voice
/// provider (the speech relay), with the provider's own client: same address,
/// key, headers and certificates its speech requests use. Null when no Voice
/// provider is set, so there is nowhere to send and the call is not logged.
VoiceEventSender? voiceEventSenderFor(Ref ref) {
  final voice = ref.read(directVoiceProviderProvider);
  if (voice == null) return null;
  final pool = ref.read(directHttpClientPoolProvider);
  final profile = voice.profile;
  return (body) async {
    final lease = pool.acquire(profile);
    try {
      final base = profile.requestBaseUri();
      final url = base.replace(
        path: '/musey/voice-log',
        query: '',
        fragment: '',
      );
      final response = await lease.dio.postUri<Object?>(
        url,
        data: body,
        options: Options(
          sendTimeout: const Duration(seconds: 5),
          receiveTimeout: const Duration(seconds: 5),
        ),
      );
      final status = response.statusCode ?? 0;
      return status >= 200 && status < 300;
    } finally {
      lease.release();
    }
  };
}
