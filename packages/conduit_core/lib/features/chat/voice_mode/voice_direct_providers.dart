library;

import 'package:riverpod/riverpod.dart';

import 'package:conduit_core/features/chat/server_speech/server_speech_providers.dart'
    show directVoiceProviderProvider;
import 'package:conduit_core/features/chat/voice_mode/voice_direct_client.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart'
    show directHttpClientPoolProvider;

/// Where a call gets its client for direct voice turns: the Voice provider's
/// host and key, relay port 1236. Null with no Voice provider set (the call
/// then uses the Open WebUI path). Tests override it with a fake server.
final voiceDirectAccessProvider = Provider<VoiceDirectAccess?>((ref) {
  final voice = ref.watch(directVoiceProviderProvider);
  if (voice == null) return null;
  return PooledVoiceDirectAccess(
    voice.profile,
    ref.watch(directHttpClientPoolProvider),
  );
});

/// The persona the call speaks as (sent as `persona_id`); the app binds it to
/// the Switchboard persona. Null leaves the choice to the relay.
final voiceDirectPersonaIdProvider = Provider<String?>((ref) => null);
