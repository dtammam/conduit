import 'package:conduit_core/features/chat/server_speech/server_speech_providers.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:flutter/widgets.dart';
import 'package:riverpod/riverpod.dart';

import '../services/reply_audio_flow.dart';
import '../services/reply_audio_prefetch.dart';
import '../services/reply_mp3_export.dart';
import '../services/tts_manager.dart';
import 'text_to_speech_provider.dart';

/// Prepares each finished reply's audio in the background (see
/// [ReplyAudioPrefetcher]) through the relay's non-streamed export, the same
/// call Share and Try again use.
final replyAudioPrefetcherProvider = Provider<ReplyAudioPrefetcher>((ref) {
  ReplyAudioRequest requestFor(ReplyAudioPrefetchItem item) =>
      ReplyAudioRequest.forReply(
        messageId: item.messageId,
        text: item.text,
        chatId: item.chatId,
        voice: ref.read(directVoiceProviderProvider)?.settings,
        heardKey: TtsManager.instance.voiceKey,
      );

  ReplyAudioFlow flow() {
    final voice = ref.read(directVoiceProviderProvider);
    final pool = ref.read(directHttpClientPoolProvider);
    return ReplyAudioFlow(
      exporter: ReplyMp3Export(
        startRelayExport: voice == null
            ? null
            : (text) async {
                final lease = pool.acquire(voice.profile);
                try {
                  return await ReplyMp3Export.startWith(lease.dio, text);
                } finally {
                  lease.release();
                }
              },
        // No plain-speech fallback in the background: an older relay without
        // export is simply not prepared ahead.
        render: (text) async =>
            throw StateError('No relay export for background audio'),
      ),
    );
  }

  return ReplyAudioPrefetcher(
    // Needs the relay's export, so a Voice provider; the toggle is the user's.
    enabled: () =>
        ref.read(appSettingsProvider).prepareReplyAudio &&
        ref.read(directVoiceProviderProvider) != null,
    liveSpeechBusy: () {
      final tts = ref.read(textToSpeechControllerProvider);
      return tts.status != TtsPlaybackStatus.idle &&
              tts.status != TtsPlaybackStatus.error ||
          TtsManager.instance.isPlaying ||
          TtsManager.instance.voiceCallActive;
    },
    appActive: () {
      final state = WidgetsBinding.instance.lifecycleState;
      return state == null || state == AppLifecycleState.resumed;
    },
    requestFor: requestFor,
    savedTake: (request) => flow().savedTake(request),
    render: (request, {required stillWanted}) =>
        flow().render(request, stillWanted: stillWanted, onlyIfMissing: true),
  );
});
