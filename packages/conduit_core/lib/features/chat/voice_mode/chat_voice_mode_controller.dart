/// The voice-call ("voice mode") controller: the turn-taking state machine
/// behind the voice-call surface.
///
/// Moved from the app's `lib/features/chat/voice_mode/` so the call logic is
/// tested without Flutter. Everything it touches that belongs to a host (the recognizer, the speech engine, the system call UI,
/// the audio session, the background lease, platform permissions) is a port
/// in `voice_mode_ports.dart`, bound by the app's composition root.
library;

import 'dart:async';
import 'dart:collection';

import 'package:meta/meta.dart';
import 'package:riverpod/riverpod.dart';

import 'package:conduit_core/voice/voice_session.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/model.dart';

import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/providers/app_providers.dart'
    show
        activeConversationProvider,
        isDirectLocalConversation,
        isTemporaryChat,
        isActiveConversationInPlaceRemap,
        selectedModelProvider,
        socketServiceProvider;

import 'package:conduit_core/providers/host_ports.dart'
    show appLifecycleProvider;
import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/services/socket_service.dart'
    show SocketBackgroundActivityLease, SocketService;

import 'package:conduit_core/utils/debug_logger.dart';
import 'package:conduit_core/features/chat/server_speech/transcription_confidence.dart';
import 'package:conduit_core/voice/barge_in_echo.dart';
import 'package:conduit_core/voice/voice_route.dart';
import 'package:conduit_core/voice/barge_in_onset.dart';

import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/chat/realtime_call/bridge_call_engine.dart';
import 'package:conduit_core/features/chat/realtime_call/bridge_call_host.dart';
import 'package:conduit_core/features/chat/realtime_call/gpt_live_call_engine.dart';
import 'package:conduit_core/features/chat/realtime_call/chat_bridge_call_host.dart';
import 'package:conduit_core/features/chat/realtime_call/realtime_bridge_transport.dart';
import 'package:conduit_core/features/chat/realtime_call/realtime_call_availability.dart';
import 'package:conduit_core/features/chat/realtime_call/realtime_call_state.dart';
import 'package:conduit_core/features/chat/voice_call/voice_call_eligibility.dart';
import 'package:conduit_core/features/chat/voice_mode/voice_call_history.dart';
import 'package:conduit_core/features/chat/voice_mode/voice_direct_client.dart';
import 'package:conduit_core/features/chat/voice_mode/voice_call_socket.dart';
import 'package:conduit_core/features/direct_connections/services/direct_http_client.dart'
    show directRequestHeaders;
import 'package:conduit_core/features/chat/voice_mode/voice_call_socket_engine.dart';
import 'package:conduit_core/features/chat/voice_mode/voice_call_socket_providers.dart';
import 'package:conduit_core/features/chat/voice_mode/voice_direct_providers.dart';
import 'package:conduit_core/features/chat/voice_mode/voice_direct_turn.dart';
import 'package:conduit_core/database/local_conversation_loader.dart'
    show pullChatOrFetch;
import 'package:conduit_core/features/chat/voice_mode/voice_event_log.dart';
import 'package:conduit_core/features/chat/voice_mode/voice_event_sender.dart';
import 'package:conduit_core/features/chat/voice_mode/voice_mode_ports.dart';
import 'package:conduit_core/features/chat/server_speech/server_speech_providers.dart'
    show directVoiceProviderProvider;

import 'package:conduit_core/features/tools/providers/tools_providers.dart';

export 'package:conduit_core/voice/voice_session.dart';
export 'package:conduit_core/features/chat/voice_mode/voice_call_socket_providers.dart';
export 'package:conduit_core/features/chat/voice_mode/voice_direct_providers.dart';
export 'package:conduit_core/features/chat/voice_mode/voice_mode_ports.dart';

final class _ChatVoiceModeStartCancelled implements Exception {
  const _ChatVoiceModeStartCancelled();
}

/// A start failure with a known [kind], so the panel can say why in the
/// user's language. [toString] stays the log text.
final class _ChatVoiceModeFailure implements Exception {
  const _ChatVoiceModeFailure(this.kind, this.message);

  final ChatVoiceModeError kind;
  final String message;

  @override
  String toString() => message;
}

ChatVoiceModeError _errorKindOf(Object error) =>
    error is _ChatVoiceModeFailure ? error.kind : ChatVoiceModeError.other;

/// Where a realtime call in [callChatId] stands once [nextChatId] is open.
/// It follows only its own chat: the one its first send created
/// ([createdByCall]), and that chat's server id given in place ([remapped]).
/// Any other chat, or none, ends it.
@visibleForTesting
({bool ends, String? chatId}) realtimeCallChatAfter(
  String? callChatId,
  String? nextChatId, {
  bool createdByCall = false,
  bool remapped = false,
}) {
  if (nextChatId == callChatId) return (ends: false, chatId: callChatId);
  if (nextChatId != null &&
      ((callChatId == null && createdByCall) || remapped)) {
    return (ends: false, chatId: nextChatId);
  }
  return (ends: true, chatId: callChatId);
}

final chatVoiceModeControllerProvider =
    NotifierProvider<ChatVoiceModeController, ChatVoiceModeSnapshot>(
      ChatVoiceModeController.new,
    );

@visibleForTesting
final chatVoiceModeServiceLifecycleTimeoutProvider = Provider<Duration>((ref) {
  return const Duration(seconds: 30);
});

final _chatVoiceModeServiceLifecycleGateProvider =
    Provider<_ChatVoiceModeServiceLifecycleGate>((ref) {
      return _ChatVoiceModeServiceLifecycleGate(
        timeout: ref.watch(chatVoiceModeServiceLifecycleTimeoutProvider),
      );
    });

class _ChatVoiceModeServiceLifecycleGate {
  _ChatVoiceModeServiceLifecycleGate({required Duration timeout})
    : _timeout = timeout;

  final Duration _timeout;
  Future<void> _tail = Future<void>.value();

  Future<T> runExclusive<T>(Future<T> Function() operation) =>
      _runExclusive(operation, keepQueuedAfterTimeout: false);

  Future<void> runCleanupExclusive(Future<void> Function() operation) =>
      _runExclusive(operation, keepQueuedAfterTimeout: true);

  Future<T> _runExclusive<T>(
    Future<T> Function() operation, {
    required bool keepQueuedAfterTimeout,
  }) {
    var started = false;
    var cancelledBeforeStart = false;
    final rawResult = _tail.then<T>((_) {
      if (cancelledBeforeStart) {
        throw TimeoutException(
          'Voice service lifecycle operation expired while queued',
          _timeout,
        );
      }
      started = true;
      return operation();
    });

    // Preserve the raw operation as the serialization tail. A Future timeout
    // does not cancel its source, so advancing the tail to the bounded wrapper
    // would let stale teardown overlap a replacement using the same services.
    _tail = rawResult.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return rawResult.timeout(
      _timeout,
      onTimeout: () {
        // An expired user operation must not start later merely because the
        // operation ahead of it settles. Mandatory cleanup is different: its
        // caller may stop waiting, but the raw cleanup must remain in the tail
        // so captured platform resources are eventually released in order.
        if (!started && !keepQueuedAfterTimeout) {
          cancelledBeforeStart = true;
        }
        throw TimeoutException(
          started
              ? 'Voice service lifecycle operation timed out'
              : 'Timed out waiting for voice service lifecycle ownership',
          _timeout,
        );
      },
    );
  }
}

class ChatVoiceModeController extends Notifier<ChatVoiceModeSnapshot> {
  static const int _maxEmptyTranscriptRestarts = 4;
  static const int _emptyTranscriptBaseDelayMs = 250;
  static const int _emptyTranscriptMaxDelayMs = 2000;
  static const Duration _backgroundKeepAliveInterval = Duration(minutes: 5);

  /// On-device barge-in: how long after playback starts a partial transcript
  /// may interrupt, and how many words it needs.
  static const Duration _onDeviceOnsetGrace = BargeInOnsetDetector.defaultGrace;
  static const int _onDeviceOnsetMinWords = 2;

  Future<void> _serial = Future<void>.value();
  int _token = 0;
  int _stopRequestGeneration = 0;
  int _emptyTranscriptRestarts = 0;
  bool _disposed = false;
  Completer<void>? _pendingStartReadinessCancellation;

  StreamSubscription<VoiceTranscriptEvent>? _transcriptSub;
  StreamSubscription<int>? _intensitySub;
  StreamSubscription<Object>? _responseCaptureFailureSub;
  StreamSubscription<Object>? _audioResponseCaptureFailureSub;
  StreamSubscription<TtsEvent>? _ttsSub;

  /// Server barge-in: the held recorder's levels while the assistant speaks,
  /// and the detector judging them.
  StreamSubscription<VoiceCaptureLevel>? _bargeInLevelSub;
  BargeInOnsetDetector? _bargeInDetector;

  /// Set while a server barge-in has paused the assistant and its take is
  /// still being heard: the transcript decides whether it was the user
  /// ([isBargeInEcho] false, the assistant stops) or the assistant's own
  /// voice coming back through the microphone (playback resumes).
  bool _bargeInProvisional = false;

  /// The last `speech-stopped` reason, so the next `listening-start` can say
  /// whether it followed a failure or a clean finish.
  String? _lastSpeechStopReason;

  /// What the barge-in detector saw at the onset, for the call log.
  Map<String, Object?> _onsetInfo = const <String, Object?>{};

  String _listeningSource(String why) => switch (why) {
    'barge-in-provisional' => 'onset',
    'after-assistant-speech' =>
      (_lastSpeechStopReason ?? '').startsWith('tts-error')
          ? 'tts-error'
          : 'completed',
    'call-start' => 'call-start',
    _ => 'resume',
  };

  /// The reply preview when a provisional barge-in began, restored on resume.
  String _previewBeforeBargeIn = '';

  /// How long a provisional barge-in may hold playback paused with no sign of
  /// the user talking before it is treated as the assistant's own echo.
  /// 2026-11-01: on the loudspeaker a take could hear one word of the
  /// assistant, never end, and leave playback paused for 25 s.
  @visibleForTesting
  static const Duration provisionalBargeInTimeout = Duration(
    milliseconds: 1500,
  );

  /// The longest a provisional barge-in is kept alive while the user is
  /// audibly talking (the transcript is then due).
  static const Duration _provisionalBargeInHardLimit = Duration(seconds: 12);

  /// Loudness (0 to 10, the listen's own meter) that counts as the user
  /// talking while the assistant is paused.
  static const int _provisionalSpeechIntensity = 3;

  /// 2026-11-05: a provisional barge-in used to pause the assistant, so every
  /// echo-triggered check left 2.0 to 2.6 s of silence mid-sentence. The
  /// assistant now keeps playing at this fraction of its volume while the
  /// take decides, and a confirmed interruption stops it as before.
  @visibleForTesting
  static const double provisionalDuckLevel = 0.28;
  static const Duration _duckDownRamp = Duration(milliseconds: 80);
  static const Duration _duckUpRamp = Duration(milliseconds: 150);

  /// True while the assistant is ducked (not paused) for a provisional check.
  bool _provisionalDucked = false;

  /// 2026-11-05 (+173): ducking is itself the test. Echo falls by about
  /// 11 dB when the player ducks to [provisionalDuckLevel] (and the echo
  /// canceller's reference falls with it); the user's voice does not. After
  /// the ramp, [bargeProbeWindow] of live microphone frames are averaged and
  /// compared with the frames just before the onset. A fall under
  /// [bargeProbeSpeechDropDb] is probable speech: the assistant is paused
  /// (so it can resume) while the take goes on to the transcript. A larger
  /// fall is echo: the volume is restored at once. Starting values from
  /// 3 logged events, not tuned: the midpoint between 0 dB (voice) and 11 dB
  /// (echo) is about 5.5.
  @visibleForTesting
  static const Duration bargeProbeSettle = Duration(milliseconds: 150);
  @visibleForTesting
  static const Duration bargeProbeWindow = Duration(milliseconds: 350);
  @visibleForTesting
  static const double bargeProbeSpeechDropDb = 6;
  static const int _bargeProbeMinFrames = 6;
  static const int _bargeProbePreFrames = 8;
  static const double _bargeProbeFloorDb = -50;

  /// True while the assistant is paused (and ducked) on probable speech.
  bool _probePaused = false;
  StreamSubscription<VoiceCaptureLevel>? _probeSub;
  Timer? _probeTimer;
  final List<double> _recentHeldDb = <double>[];
  final List<double> _probeDb = <double>[];
  DateTime? _probeOnsetAt;
  double? _probePreDb;

  Timer? _provisionalWatchdog;
  DateTime? _provisionalStartedAt;
  DateTime? _lastProvisionalSpeechAt;

  /// The last take dropped as echo, so a second report of it is dropped too.
  String? _ignoredEchoTranscript;
  DateTime? _assistantSpeechStartedAt;
  StreamSubscription<VoiceCallKitEvent>? _callKitSub;
  StreamSubscription<bool>? _speakerphoneRouteSub;
  StreamSubscription<VoiceAudioSessionEvent>? _sessionEventSub;
  ProviderSubscription<SocketService?>? _socketServiceSub;
  ProviderSubscription<Model?>? _selectedModelSub;
  Timer? _elapsedTimer;
  Timer? _backgroundKeepAliveTimer;

  String _currentTranscript = '';
  String _lastFedAssistantText = '';
  String? _backgroundLeaseId;
  String? _activeCallId;
  String? _activeAssistantMessageId;
  SocketBackgroundActivityLease? _socketBackgroundLease;
  VoiceBackgroundPort? _backgroundCoordinator;
  VoiceAudioSessionPort? _audioSessionCoordinator;
  VoiceModePlatformPort _platform = const HostVoiceModePlatform();
  late _ChatVoiceModeServiceLifecycleGate _serviceLifecycleGate;
  VoiceModeInput? _voiceInput;
  VoiceModeSpeech? _textToSpeech;
  VoiceCallKitPort? _callKit;
  Set<String> _assistantMessageIdsBeforeTurn = <String>{};
  bool _awaitingAssistant = false;
  bool _assistantFinalized = false;
  bool _streamingTtsStarted = false;
  bool _iosAudioSessionManagedExternally = false;
  bool _markedCallConnected = false;

  /// The realtime voice of a call that has one; the turn-by-turn input and
  /// speech are then unused.
  RealtimeCallEngine? _realtime;

  /// Carries on a call on the direct or old path from where its realtime
  /// socket ended (dropped, or the relay handed a turn back). Null otherwise.
  Future<void> Function(String? sendText)? _standardFallback;

  /// What a socket call keeps after the relay hands a turn back (or the
  /// socket drops): the way back onto the old path, so the next turn can try
  /// the realtime socket again. Cleared at call end.
  Future<void> Function(String? sendText)? _socketReopenFallback;

  /// Reopens that failed in this call; two and it stops trying (no flapping).
  int _socketReopenFailures = 0;
  bool _socketReopening = false;
  ChatBridgeCallHost? _realtimeHost;
  StreamSubscription<RealtimeCallState>? _realtimeSub;
  ProviderSubscription<Conversation?>? _realtimeChatSub;
  bool _pausedDuringSpeech = false;
  bool _pausedDuringAssistantTurn = false;
  bool _mutedDuringSpeech = false;
  bool _assistantFinalizationDeferred = false;
  String? _pendingPausedAssistantText;
  String? _pendingPausedAssistantFinalText;
  final Queue<String> _pendingFinalTranscripts = Queue<String>();
  String? _lastSubmittedTranscript;
  bool _stoppingFromCallKit = false;

  /// Why the call is ending, the phase it was in and whether the system call
  /// UI was on, noted by the first path to end it (it wins) and written on the
  /// log's `call-end` by [_disposeResources].
  String? _endReason;
  String? _endPhase;
  bool _endCallKitOn = false;

  void _noteEnd(String reason) {
    if (_endReason != null) return;
    _endReason = reason;
    _endPhase = state.phase.name;
    _endCallKitOn = _activeCallId != null;
  }

  /// Whether this call runs without the system call UI: the app owns the
  /// audio session and answers interruptions and lost routes itself.
  bool _appOwnsSession = false;
  bool _pausedByInterruption = false;
  bool _pausedByRouteLoss = false;
  bool _sendingTranscript = false;

  // Direct voice turns (Contract A, ~/srv/docs/VOICE-REALTIME.md 12.1). The
  // relay is the single writer of a direct turn's chat; these hold only what
  // the call shows and sends.
  late final VoiceCallHistory _directHistory = VoiceCallHistory();
  late final VoiceDirectTurnRunner _directRunner = VoiceDirectTurnRunner(
    history: _directHistory,
  );
  bool _directDisabled = false;
  bool _directTurnActive = false;
  String? _directCallId;
  String? _directChatId;

  /// Spoken before the reply text of the turn: the relay's ack clip.
  String _speechPrefix = '';
  bool _usesOpenWebUiTransport = false;
  List<String> _assistantSpeechChunks = const <String>[];
  int _activeAssistantSpeechChunkIndex = -1;

  @override
  ChatVoiceModeSnapshot build() {
    _disposed = false;
    _backgroundCoordinator = ref.read(
      chatVoiceModeBackgroundCoordinatorProvider,
    );
    _audioSessionCoordinator = ref.read(voiceAudioSessionProvider);
    _platform = ref.read(voiceModePlatformProvider);
    _serviceLifecycleGate = ref.read(
      _chatVoiceModeServiceLifecycleGateProvider,
    );
    ref.listen<String?>(streamingContentProvider, (_, next) {
      if (next != null) {
        _handleAssistantContentChanged();
      }
    });

    ref.listen<List<ChatMessage>>(chatMessagesProvider, (_, next) {
      _handleChatMessagesChanged(next);
    });

    // The app going to the background or coming back while a call is live is
    // the first thing to read when speech stops (the log only records inside
    // a call).
    final lifecycleSub = ref.read(appLifecycleProvider).changes.listen((phase) {
      VoiceEventLog.instance.add('app-lifecycle', <String, Object?>{
        'state': phase.name,
        'phase': state.phase.name,
      });
    }, onError: (Object _) {});
    ref.onDispose(() => unawaited(lifecycleSub.cancel()));

    ref.onDispose(() {
      // Invalidate every detached transcript/TTS continuation before tearing
      // down its subscriptions. Async work must use only dependencies captured
      // while the provider was alive; reading Ref from this point is invalid.
      _disposed = true;
      ++_stopRequestGeneration;
      _cancelPendingStartReadiness();
      ++_token;
      _elapsedTimer?.cancel();
      _backgroundKeepAliveTimer?.cancel();
      final transcriptSub = _transcriptSub;
      final intensitySub = _intensitySub;
      final responseCaptureFailureSub = _responseCaptureFailureSub;
      final audioResponseCaptureFailureSub = _audioResponseCaptureFailureSub;
      final ttsSub = _ttsSub;
      final callKitSub = _callKitSub;
      final speakerphoneRouteSub = _speakerphoneRouteSub;
      final sessionEventSub = _sessionEventSub;
      _sessionEventSub = null;
      unawaited(_cancelSubscriptionAfterDispose(sessionEventSub));
      final socketServiceSub = _socketServiceSub;
      final selectedModelSub = _selectedModelSub;
      final bargeInLevelSub = _bargeInLevelSub;
      _bargeInLevelSub = null;
      _bargeInDetector = null;
      unawaited(_cancelSubscriptionAfterDispose(bargeInLevelSub));
      _speakerphoneRouteSub = null;
      _socketServiceSub = null;
      _selectedModelSub = null;
      final input = _voiceInput;
      final tts = _textToSpeech;
      final backgroundCoordinator = _backgroundCoordinator;
      final audioSessionCoordinator = _audioSessionCoordinator;
      final callKit = _callKit;
      final callId = _activeCallId;
      final socketBackgroundLease = _socketBackgroundLease;
      final realtime = _realtime;
      final realtimeSub = _realtimeSub;
      final realtimeChatSub = _realtimeChatSub;
      _realtime = null;
      _standardFallback = null;
      _realtimeHost = null;
      _realtimeSub = null;
      _realtimeChatSub = null;
      realtimeChatSub?.close();
      // The voice's microphone and connection end with the provider; the
      // host skips the chat writes a disposed provider can no longer make.
      unawaited(realtimeSub?.cancel());
      unawaited(realtime?.end());
      _activeCallId = null;
      _usesOpenWebUiTransport = false;
      selectedModelSub?.close();
      socketServiceSub?.close();
      _socketBackgroundLease = null;
      socketBackgroundLease?.dispose();
      unawaited(
        _serviceLifecycleGate
            .runCleanupExclusive(() async {
              await _cancelSubscriptionAfterDispose(transcriptSub);
              await _cancelSubscriptionAfterDispose(intensitySub);
              await _cancelSubscriptionAfterDispose(responseCaptureFailureSub);
              await _cancelSubscriptionAfterDispose(
                audioResponseCaptureFailureSub,
              );
              await _stopVoiceInputAfterDispose(input);
              await _endResponseWaitCaptureAfterDispose(
                audioSessionCoordinator,
              );
              await _cancelSubscriptionAfterDispose(ttsSub);
              await _stopTtsAfterDispose(tts);
              // The engine is shared with read-aloud, which belongs on the
              // media stream. Nothing survives provider disposal to hand it
              // back, so it happens here.
              tts?.setVoiceCallActive(false);
              await _stopBackgroundVoiceLeaseAfterDispose(
                backgroundCoordinator,
              );
              await _deactivateAudioSessionAfterDispose(
                audioSessionCoordinator,
              );
              await _cancelSubscriptionAfterDispose(callKitSub);
              await _cancelSubscriptionAfterDispose(speakerphoneRouteSub);
              if (callId != null) {
                await _endCallAfterDispose(callKit, callId);
              }
            })
            .catchError((Object error, StackTrace stackTrace) {
              DebugLogger.error(
                'dispose-lifecycle-timeout',
                scope: 'chat/voice_mode',
                error: error,
                stackTrace: stackTrace,
              );
            }),
      );
    });

    return const ChatVoiceModeSnapshot();
  }

  Future<ChatVoiceModeStartResult> start({
    required bool startNewConversation,
    bool Function()? shouldStart,
    Model? admittedModel,
  }) async {
    final stopGenerationAtRequest = _stopRequestGeneration;
    // The chat the call is for, as the user asked for it: the open one, or
    // the new one it starts.
    final callChatId = startNewConversation
        ? null
        : ref.read(activeConversationProvider)?.id;
    bool cancellationRequested() =>
        _disposed || stopGenerationAtRequest != _stopRequestGeneration;

    var result = ChatVoiceModeStartResult.failed;
    await _enqueue(() async {
      if (cancellationRequested()) {
        result = ChatVoiceModeStartResult.cancelled;
        return;
      }

      int? token;
      final readinessCancellation = admittedModel == null
          ? Completer<void>()
          : null;

      try {
        await _serviceLifecycleGate.runExclusive(() async {
          if (cancellationRequested()) {
            result = ChatVoiceModeStartResult.cancelled;
            return;
          }
          if (state.isActive) {
            result = ChatVoiceModeStartResult.alreadyActive;
            return;
          }

          final VoiceCallEligibility eligibility;
          if (admittedModel != null) {
            eligibility = VoiceCallEligibility.eligible(admittedModel);
          } else {
            _pendingStartReadinessCancellation = readinessCancellation;
            eligibility = await resolveVoiceCallEligibility(
              ref,
              cancellationSignal: readinessCancellation!.future,
              cancellationRequested: cancellationRequested,
            );
          }
          if (cancellationRequested()) {
            result = ChatVoiceModeStartResult.cancelled;
            return;
          }
          if (!eligibility.canStart) {
            _setError(eligibility.errorMessage!, ChatVoiceModeError.message);
            return;
          }
          if (shouldStart != null && !shouldStart()) {
            result = ChatVoiceModeStartResult.cancelled;
            return;
          }

          final model = eligibility.model!;

          final startToken = ++_token;
          token = startToken;
          _resetRuntime();

          void cancelIfRequested() {
            if (cancellationRequested() ||
                (shouldStart != null && !shouldStart())) {
              throw const _ChatVoiceModeStartCancelled();
            }
          }

          bool lostOwnership() {
            if (_isCurrent(startToken)) return false;
            result = ChatVoiceModeStartResult.cancelled;
            return true;
          }

          // Keep the inactive overlay lightweight. These services can reach
          // authenticated storage and platform channels, so capture them only
          // when a voice session actually starts. The retained references also
          // let disposal finish without reading Ref after invalidation.
          final VoiceModeInput input =
              _voiceInput ?? ref.read(voiceModeInputProvider);
          _voiceInput = input;
          final VoiceModeSpeech tts =
              _textToSpeech ?? ref.read(voiceModeSpeechProvider);
          _textToSpeech = tts;
          _callKit ??= ref.read(voiceCallKitProvider);
          final settings = ref.read(appSettingsProvider);

          state = state.copyWith(
            phase: ChatVoiceModePhase.starting,
            startedAt: DateTime.now(),
            elapsed: Duration.zero,
            clearErrorMessage: true,
            isCollapsed: storedVoiceModeCollapsed(),
            isMuted: false,
            isSpeakerphoneEnabled: false,
          );

          _socketServiceSub = ref.listen<SocketService?>(
            socketServiceProvider,
            (_, next) => _replaceSocketBackgroundLease(next),
          );
          _selectedModelSub = ref.listen<Model?>(
            selectedModelProvider,
            (_, next) => _updateVoiceTransport(next),
          );
          _updateVoiceTransport(ref.read(selectedModelProvider) ?? model);

          final inputReady = await input.initialize();
          if (lostOwnership()) return;
          cancelIfRequested();
          if (!inputReady) {
            throw const _ChatVoiceModeFailure(
              ChatVoiceModeError.inputUnavailable,
              'Voice input initialization failed.',
            );
          }
          if (!await input.checkPermissions()) {
            throw const _ChatVoiceModeFailure(
              ChatVoiceModeError.microphoneDenied,
              'Microphone permission denied.',
            );
          }
          if (lostOwnership()) return;
          cancelIfRequested();

          await _requestAndroidVoiceRoutingPermission();
          if (lostOwnership()) return;
          cancelIfRequested();
          await _bindAppOwnedSession(settings.voiceCallKitEnabled);
          if (lostOwnership()) return;
          cancelIfRequested();
          await _applyDefaultSpeakerphoneRoute();
          if (lostOwnership()) return;
          cancelIfRequested();

          final realtime = await _resolveRealtime(
            model,
            newChat: startNewConversation,
          );
          if (lostOwnership()) return;
          cancelIfRequested();
          if (realtime != null) {
            await _startCallKit(model.name, startToken);
            if (lostOwnership()) return;
            cancelIfRequested();
            await _startBackgroundVoiceLease(input, startToken);
            if (lostOwnership()) return;
            cancelIfRequested();
            _startElapsedTimer(startToken);
            if (startNewConversation) {
              startNewChat(ref, modelForNewConversation: model);
            }
            // Both directions at once, on the voice-chat route that cancels
            // echo.
            await _audioSessionCoordinator?.configureForBargeInSpeaking();
            if (lostOwnership()) return;
            cancelIfRequested();
            try {
              await _startRealtime(realtime, startToken, chatId: callChatId);
            } catch (_) {
              // Hung up while it connected: the stop ended it, which is no
              // failure.
              cancelIfRequested();
              rethrow;
            }
            if (lostOwnership()) return;
            cancelIfRequested();
            if (_isCurrent(startToken) && state.isActive) {
              result = ChatVoiceModeStartResult.started;
            }
            return;
          }

          Future<void> runStandard({
            required bool callStarted,
            String? sendText,
          }) async {
            await _initializeTts(tts, settings);
            if (lostOwnership()) return;
            cancelIfRequested();
            _listenForTtsEvents(tts, startToken);
            await _listenForResponseCaptureFailures(
              input,
              _audioSessionCoordinator,
              startToken,
            );
            if (!callStarted) {
              await _startCallKit(model.name, startToken);
              if (lostOwnership()) return;
              cancelIfRequested();
              await _startBackgroundVoiceLease(input, startToken);
              if (lostOwnership()) return;
              cancelIfRequested();
              _startElapsedTimer(startToken);
              await _beginVoiceEventLog(settings);
            }
            await _startListening(
              startToken,
              why: callStarted ? 'socket-fallback' : 'call-start',
              beforeAcceptingTranscripts: startNewConversation
                  ? () {
                      cancelIfRequested();
                      startNewChat(ref, modelForNewConversation: model);
                    }
                  : null,
            );
            if (lostOwnership()) return;
            cancelIfRequested();
            if (sendText != null && sendText.isNotEmpty) {
              // The relay handed this turn back (a tool turn): it goes the
              // direct or Open WebUI way from here.
              await _sendTranscript(sendText, startToken);
            }
            if (_isCurrent(startToken) && state.isActive) {
              result = ChatVoiceModeStartResult.started;
            }
          }

          // The realtime socket (Contract B) carries a standard call on an
          // open chat when the relay takes it; refused or silent, the call
          // goes on the direct or old path exactly as before.
          final VoiceSocketCallEngine? socket = realtime == null
              ? await _prepareSocketCall(callChatId, startToken)
              : null;
          if (lostOwnership()) return;
          cancelIfRequested();
          if (socket != null) {
            _standardFallback = (text) =>
                runStandard(callStarted: true, sendText: text);
            _socketReopenFallback = _standardFallback;
            await _startCallKit(model.name, startToken);
            if (lostOwnership()) return;
            cancelIfRequested();
            await _startBackgroundVoiceLease(input, startToken);
            if (lostOwnership()) return;
            cancelIfRequested();
            _startElapsedTimer(startToken);
            await _beginVoiceEventLog(settings);
            await _audioSessionCoordinator?.configureForBargeInSpeaking();
            if (lostOwnership()) return;
            cancelIfRequested();
            try {
              await _startSocketCall(socket, startToken, chatId: callChatId!);
            } on VoiceSocketUnavailable catch (error) {
              cancelIfRequested();
              VoiceEventLog.instance.add('socket-fallback', <String, Object?>{
                'why': error.reason,
              });
              await _discardSocket(socket);
              _standardFallback = null;
              await runStandard(callStarted: true);
              return;
            } catch (_) {
              cancelIfRequested();
              rethrow;
            }
            if (lostOwnership()) return;
            cancelIfRequested();
            if (_isCurrent(startToken) && state.isActive) {
              result = ChatVoiceModeStartResult.started;
            }
            return;
          }

          await runStandard(callStarted: false);
        });
      } catch (error, stackTrace) {
        final startToken = token;
        if (_disposed || (startToken != null && !_isCurrent(startToken))) {
          result = ChatVoiceModeStartResult.cancelled;
          return;
        }
        if (error is _ChatVoiceModeStartCancelled ||
            error is VoiceCallEligibilityResolutionCancelled) {
          result = ChatVoiceModeStartResult.cancelled;
          if (startToken != null) {
            await _stopInternal(endCallKit: true, reason: 'start-cancelled');
          }
          return;
        }
        DebugLogger.error(
          'start-failed',
          scope: 'chat/voice_mode',
          error: error,
          stackTrace: stackTrace,
        );
        if (error is TimeoutException) {
          if (startToken != null) {
            final cleanupToken = ++_token;
            unawaited(
              _disposeResources(endCallKit: true, ownershipToken: cleanupToken),
            );
          }
          _setError(
            'Voice services timed out. Try again.',
            ChatVoiceModeError.timeout,
          );
          return;
        }
        if (startToken == null) {
          _setError(error.toString(), _errorKindOf(error));
          return;
        }
        await _fail(error.toString(), startToken, _errorKindOf(error));
      } finally {
        if (identical(
          _pendingStartReadinessCancellation,
          readinessCancellation,
        )) {
          _pendingStartReadinessCancellation = null;
        }
      }
    });
    return result;
  }

  /// How to build the realtime voice for a call with [model], or null when
  /// the call is a Standard one: the user chose Standard, the device cannot
  /// run the voice's audio, or the model's backend offers no realtime voice.
  Future<RealtimeCallEngine Function(BridgeCallHost host)?> _resolveRealtime(
    Model model, {
    required bool newChat,
  }) async {
    final RealtimeCallRoute route;
    try {
      route = await ref.read(realtimeCallRouteResolverProvider)(
        model,
        newChat: newChat,
      );
    } catch (error) {
      // What cannot be read keeps the call Standard, like anything unknown.
      DebugLogger.warning(
        'realtime-route-failed',
        scope: 'chat/voice_mode',
        data: {'errorType': error.runtimeType.toString()},
      );
      return null;
    }
    final bridge = route.bridge;
    if (bridge != null) {
      final audio = ref.read(realtimePcmAudioFactoryProvider)();
      if (audio != null) {
        return (host) =>
            BridgeCallEngine(transport: bridge, audio: audio, host: host);
      }
      await bridge.close();
    }
    final hermes = route.hermes;
    if (hermes != null) {
      final media = ref.read(realtimeWebRtcMediaFactoryProvider)();
      if (media != null) {
        // Built after a new chat has started, so the voice never hears the
        // chat the call left.
        return (host) => GptLiveCallEngine(
          media: media,
          host: host,
          history: gptLiveHistory(ref.read(chatMessagesProvider)),
          open: (offer, history) async => (await hermes.createVoiceLiveSession(
            sdp: offer,
            history: history,
          )).answerSdp,
        );
      }
    }
    DebugLogger.log(
      'realtime-unavailable',
      scope: 'chat/voice_mode',
      data: {'reason': route.block?.name ?? 'no-device-audio'},
    );
    return null;
  }

  Future<void> _startRealtime(
    RealtimeCallEngine Function(BridgeCallHost host) build,
    int token, {
    required String? chatId,
  }) async {
    // Another chat opened while the call set up: its voice was made for the
    // one the user left.
    final openChatId = ref.read(activeConversationProvider)?.id;
    if (openChatId != chatId &&
        !isActiveConversationInPlaceRemap(ref, chatId, openChatId)) {
      throw const _ChatVoiceModeStartCancelled();
    }
    final host = ChatBridgeCallHost(
      ref,
      onNotice: (notice) {
        if (!_isCurrent(token) || _disposed) return;
        state = state.copyWith(
          notice: notice,
          noticeCount: state.noticeCount + 1,
        );
      },
    );
    final engine = build(host);
    _realtime = engine;
    _realtimeHost = host;
    // Followed from before it connects: a chat opened while it connects
    // ends it too.
    _followRealtimeChat(host, token);
    try {
      await engine.connect();
    } on RealtimeBridgeException catch (error) {
      // The start fails with this; the engine's own ending is not a second
      // failure.
      throw _ChatVoiceModeFailure(ChatVoiceModeError.message, error.message);
    }
    _realtimeSub = engine.states.listen(
      (realtime) => _onRealtimeState(realtime, token),
    );
    _onRealtimeState(engine.state, token);
    final callId = state.activeCallId;
    if (_isCurrent(token) && !_markedCallConnected && callId != null) {
      _markedCallConnected = true;
      unawaited(_callKit!.markCallConnected(callId));
    }
  }

  /// The socket engine for this call, with the socket open and the relay
  /// ready; null when the call cannot use it (no host kit, no Voice
  /// provider, a new or temporary chat, a refusal). A refusal (503 when
  /// `voice_call_socket` is off, 404 when the relay lacks it) is logged and
  /// the call goes on the direct or old path.
  Future<VoiceSocketCallEngine?> _prepareSocketCall(
    String? chatId,
    int token,
  ) async {
    final kit = ref.read(voiceCallSocketKitProvider);
    final voice = ref.read(directVoiceProviderProvider);
    final conversation = ref.read(activeConversationProvider);
    if (kit == null ||
        voice == null ||
        chatId == null ||
        _directDisabled ||
        !_usesOpenWebUiTransport ||
        conversation == null ||
        conversation.id != chatId ||
        isTemporaryChat(conversation.id) ||
        isDirectLocalConversation(conversation)) {
      if (kit != null) {
        VoiceEventLog.instance.add('socket-skipped', <String, Object?>{
          'voice': voice != null,
          'chat': chatId != null,
          'direct': !_directDisabled,
          'owui': _usesOpenWebUiTransport,
          'open': conversation?.id == chatId,
        });
      }
      return null;
    }
    _directChatId = chatId;
    _directCallId ??= newVoiceTurnId();
    final engine = VoiceSocketCallEngine(
      connector: kit.connector,
      uri: voiceCallSocketUri(voice.profile),
      headers: directRequestHeaders(voice.profile),
      mic: kit.mic(),
      player: kit.player(),
      chatId: chatId,
      chatMessages: () => ref.read(chatMessagesProvider),
      history: _directHistory,
      callId: _directCallId,
      personaId: ref.read(voiceDirectPersonaIdProvider),
      build: VoiceEventLog.instance.build,
      tz: DateTime.now().timeZoneName,
    );
    try {
      await engine.preflight();
    } on VoiceSocketUnavailable catch (error) {
      VoiceEventLog.instance.add('socket-unavailable', <String, Object?>{
        'why': error.reason,
        'status': error.status,
      });
      await engine.end();
      return null;
    }
    if (!_isCurrent(token)) {
      await engine.end();
      return null;
    }
    _realtime = engine;
    return engine;
  }

  /// After a turn the relay handed back (a tool turn) has played or been
  /// interrupted: goes back to the realtime socket for the next turn, with the
  /// same call id and the history rebuilt from the chat (the tool turn is in
  /// it). True when the socket took the call over; false leaves the call on
  /// the direct path. Waits for the relay's save queue first, as the direct
  /// path does. Two failed reopens in a call stop further tries.
  Future<bool> _tryReopenSocket(int token) async {
    final fallback = _socketReopenFallback;
    if (fallback == null ||
        _socketReopening ||
        _socketReopenFailures >= 2 ||
        _realtime != null ||
        _directTurnActive ||
        _disposed ||
        !state.isActive ||
        state.isMuted ||
        state.phase == ChatVoiceModePhase.paused ||
        !_isCurrent(token)) {
      return false;
    }
    final chatId = ref.read(activeConversationProvider)?.id;
    if (chatId == null) return false;
    _socketReopening = true;
    VoiceSocketCallEngine? engine;
    try {
      final access = ref.read(voiceDirectAccessProvider);
      if (access != null) {
        final lease = access.acquire();
        try {
          if (!await lease.client.waitSaved(chatId)) {
            // Not drained yet: stay on the direct path for this turn.
            VoiceEventLog.instance.add('socket-reopen-wait');
            return false;
          }
        } finally {
          lease.release();
        }
        if (!_isCurrent(token)) return false;
      }
      engine = await _prepareSocketCall(chatId, token);
      if (engine == null) {
        if (_isCurrent(token)) _socketReopenFailures++;
        VoiceEventLog.instance.add('socket-reopen-failed', <String, Object?>{
          'failures': _socketReopenFailures,
        });
        return false;
      }
      // Nothing of the old path may keep listening under the socket's mic.
      await _detachListeningSubscriptions();
      final input = _voiceInput;
      if (input != null && !input.isHoldingServerRecorderForResponse) {
        try {
          await input.stopListening();
        } catch (_) {}
      }
      if (!_isCurrent(token)) {
        await _discardSocket(engine);
        return false;
      }
      _standardFallback = fallback;
      await _audioSessionCoordinator?.configureForBargeInSpeaking();
      _assistantFinalized = true;
      _awaitingAssistant = false;
      try {
        await _startSocketCall(engine, token, chatId: chatId);
      } on VoiceSocketUnavailable catch (error) {
        VoiceEventLog.instance.add('socket-reopen-failed', <String, Object?>{
          'why': error.reason,
        });
        _socketReopenFailures++;
        _standardFallback = null;
        await _discardSocket(engine);
        return false;
      }
      VoiceEventLog.instance.add('socket-reopened');
      return true;
    } catch (error) {
      if (_isCurrent(token)) _socketReopenFailures++;
      VoiceEventLog.instance.add('socket-reopen-failed', <String, Object?>{
        'why': '$error',
      });
      if (engine != null && identical(_realtime, engine)) {
        _standardFallback = null;
        await _discardSocket(engine);
      }
      return false;
    } finally {
      _socketReopening = false;
    }
  }

  @visibleForTesting
  Future<bool> debugReopenSocketForTest() => _tryReopenSocket(_token);

  /// Starts the microphone and the call's snapshot on [engine] (socket open).
  Future<void> _startSocketCall(
    VoiceSocketCallEngine engine,
    int token, {
    required String chatId,
  }) async {
    _followSocketChat(chatId, token);
    await engine.connect();
    _realtimeSub = engine.states.listen(
      (realtime) => _onRealtimeState(realtime, token),
    );
    _onRealtimeState(engine.state, token);
    final callId = state.activeCallId;
    if (_isCurrent(token) && !_markedCallConnected && callId != null) {
      _markedCallConnected = true;
      unawaited(_callKit!.markCallConnected(callId));
    }
  }

  void _followSocketChat(String chatId, int token) {
    _realtimeChatSub = ref.listen<Conversation?>(activeConversationProvider, (
      _,
      next,
    ) {
      if (!_isCurrent(token)) return;
      if (next?.id == chatId ||
          isActiveConversationInPlaceRemap(ref, chatId, next?.id)) {
        return;
      }
      unawaited(stop());
    });
  }

  /// Drops a socket engine that never went live.
  Future<void> _discardSocket(VoiceSocketCallEngine engine) async {
    final sub = _realtimeSub;
    _realtimeSub = null;
    if (identical(_realtime, engine)) _realtime = null;
    _realtimeChatSub?.close();
    _realtimeChatSub = null;
    await sub?.cancel();
    await engine.end();
  }

  /// The socket ended without the user hanging up: it dropped and did not
  /// come back, or the relay handed a tool turn back. Carry the call on the
  /// direct or old path; nothing stays stuck.
  Future<void> _socketFallback(VoiceSocketCallEngine engine, int token) async {
    if (!_isCurrent(token) || _disposed) return;
    VoiceEventLog.instance.add('socket-fallback', <String, Object?>{
      'why': engine.endKind.name,
    });
    final fallback = _standardFallback;
    await _discardSocket(engine);
    _standardFallback = null;
    if (!_isCurrent(token) || _disposed) return;
    if (fallback == null) {
      await _fail('Voice connection lost.', token, ChatVoiceModeError.message);
      return;
    }
    state = state.copyWith(
      phase: ChatVoiceModePhase.starting,
      assistantPreview: '',
      clearErrorMessage: true,
    );
    try {
      await fallback(engine.owuiText);
    } on _ChatVoiceModeStartCancelled {
      return;
    } catch (error, stackTrace) {
      if (!_isCurrent(token)) return;
      DebugLogger.error(
        'socket-fallback-failed',
        scope: 'chat/voice_mode',
        error: error,
        stackTrace: stackTrace,
      );
      await _fail(error.toString(), token, _errorKindOf(error));
    }
  }

  /// Ends a realtime call when the user leaves its chat: the voice talks
  /// about that chat, and a request it handed over is answered there. The
  /// chat the call's own send creates, and that chat's server id, stay the
  /// call's.
  void _followRealtimeChat(ChatBridgeCallHost host, int token) {
    _realtimeChatSub = ref.listen<Conversation?>(activeConversationProvider, (
      _,
      next,
    ) {
      if (!_isCurrent(token)) return;
      final callChatId = host.chatId;
      final followed = realtimeCallChatAfter(
        callChatId,
        next?.id,
        createdByCall: host.createdChat(next),
        remapped: isActiveConversationInPlaceRemap(ref, callChatId, next?.id),
      );
      if (followed.ends) {
        unawaited(stop());
      } else {
        host.followChat(next);
      }
    });
  }

  /// Shows the realtime call in the same snapshot a Standard call uses.
  void _onRealtimeState(RealtimeCallState realtime, int token) {
    if (!_isCurrent(token) || _disposed) return;
    if (realtime.phase == RealtimeCallPhase.ended) {
      final engine = _realtime;
      if (engine is VoiceSocketCallEngine &&
          (engine.endKind == VoiceSocketEnd.dropped ||
              engine.endKind == VoiceSocketEnd.owui)) {
        unawaited(_socketFallback(engine, token));
        return;
      }
      final error = realtime.error;
      if (error != null) {
        unawaited(_fail(error, token, ChatVoiceModeError.message));
      } else {
        unawaited(stop());
      }
      return;
    }
    final level = realtime.assistantSpeaking
        ? realtime.outputLevel
        : realtime.inputLevel;
    state = state.copyWith(
      phase: switch (realtime) {
        RealtimeCallState(phase: RealtimeCallPhase.connecting) =>
          ChatVoiceModePhase.starting,
        RealtimeCallState(muted: true) => ChatVoiceModePhase.muted,
        RealtimeCallState(assistantSpeaking: true) =>
          ChatVoiceModePhase.speaking,
        RealtimeCallState(working: true) => ChatVoiceModePhase.sending,
        _ => ChatVoiceModePhase.listening,
      },
      transcript: realtime.userCaption,
      assistantPreview: realtime.assistantCaption,
      intensity: (level * 40).round().clamp(0, 10),
      isMuted: realtime.muted,
    );
  }

  /// Starts accessory-free calls on the loudspeaker, and follows the route the
  /// coordinator reads back for the rest of the call.
  ///
  /// The snapshot only ever moves on a route the coordinator confirms, so the
  /// overlay's speaker button never lights up for a move the platform refused,
  /// and goes back down when the platform moves the call off the loudspeaker.
  Future<void> _applyDefaultSpeakerphoneRoute() async {
    final coordinator = _audioSessionCoordinator;
    if (coordinator == null) {
      return;
    }
    unawaited(_speakerphoneRouteSub?.cancel());
    _speakerphoneRouteSub = coordinator.speakerphoneRouteChanges.listen((
      enabled,
    ) {
      if (_disposed || !state.isActive) return;
      // Every configure pass reports the route, mostly unchanged.
      if (state.isSpeakerphoneEnabled == enabled) return;
      state = state.copyWith(isSpeakerphoneEnabled: enabled);
    });
    await coordinator.applyDefaultSpeakerphoneRoute();
  }

  Future<void> _requestAndroidVoiceRoutingPermission() async {
    if (!_platform.isAndroid) {
      return;
    }

    try {
      await _platform.requestCallRoutingPermission();
    } catch (error, stackTrace) {
      DebugLogger.error(
        'bluetooth-connect-request-failed',
        scope: 'chat/voice_mode',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  @visibleForTesting
  bool get isWaitingForStartReadiness =>
      _pendingStartReadinessCancellation != null;

  /// Ends the call. [reason] names who asked (overlay-end, pill-end, carplay,
  /// ...) and goes on the call's `call-end` event.
  Future<void> stop({String reason = 'stop'}) {
    if (state.isActive || state.phase == ChatVoiceModePhase.error) {
      _noteEnd(reason);
    }
    _cancelStart();
    return _enqueue(() => _stopInternal(endCallKit: true, reason: reason));
  }

  /// Stops a start under way before it goes further. A realtime voice still
  /// connecting ends now: its microphone and connection must not wait for
  /// the start queued ahead of the stop.
  void _cancelStart() {
    ++_stopRequestGeneration;
    _cancelPendingStartReadiness();
    final realtime = _realtime;
    if (realtime != null &&
        realtime.state.phase == RealtimeCallPhase.connecting) {
      // Teardown awaits this same ending, and reports what it throws.
      unawaited(realtime.end().catchError((Object _) {}));
    }
  }

  Future<void> pause() {
    return _enqueue(() async {
      if (!state.canPause) return;
      await _pauseNow();
    });
  }

  Future<void> _pauseNow() async {
    {
      final realtime = _realtime;
      if (realtime != null) {
        // Stops talking and listening, and holds its answers until resume.
        realtime
          ..setPaused(true)
          ..setMuted(true);
        return;
      }

      final wasAwaitingAssistant = _awaitingAssistant;
      _pausedDuringSpeech = state.phase == ChatVoiceModePhase.speaking;
      _pausedDuringAssistantTurn = wasAwaitingAssistant;
      await _cancelListening();
      await _audioSessionCoordinator?.endResponseWaitCapture();
      if (_disposed) return;
      if (wasAwaitingAssistant) {
        await _textToSpeech!.pause();
      }

      if (_disposed) return;

      state = state.copyWith(phase: ChatVoiceModePhase.paused);
    }
  }

  Future<void> resume() {
    return _enqueue(() async {
      if (!state.canResume) return;
      await _resumeNow();
    });
  }

  Future<void> _resumeNow() async {
    {
      if (_pausedByInterruption || _pausedByRouteLoss) {
        // The system took the session or the route while the call was
        // paused; take the session and the route back before carrying on.
        _pausedByInterruption = false;
        _pausedByRouteLoss = false;
        await _audioSessionCoordinator?.configureForListening();
        if (_disposed) return;
      }
      final realtime = _realtime;
      if (realtime != null) {
        realtime
          ..setMuted(false)
          ..setPaused(false);
        return;
      }

      final token = _token;
      state = state.copyWith(
        phase: ChatVoiceModePhase.starting,
        isMuted: false,
        clearErrorMessage: true,
      );

      if (_pausedDuringAssistantTurn) {
        await _resumePausedAssistantTurn(token);
        return;
      }

      if (_pausedDuringSpeech) {
        _pausedDuringSpeech = false;
        await _textToSpeech!.resume();
        if (_disposed) return;
        state = state.copyWith(phase: ChatVoiceModePhase.speaking);
        return;
      }

      await _startListening(token, why: 'resume-from-pause');
    }
  }

  /// Starts the call without the system call UI when the setting asks for it
  /// (iOS only), and listens for what the system does to the audio meanwhile.
  Future<void> _bindAppOwnedSession(bool callKitEnabled) async {
    final coordinator = _audioSessionCoordinator;
    _appOwnsSession = _platform.isIOS && !callKitEnabled;
    _pausedByInterruption = false;
    _pausedByRouteLoss = false;
    final previous = _sessionEventSub;
    _sessionEventSub = null;
    await previous?.cancel();
    if (coordinator == null) return;
    await coordinator.setAppOwnsSession(_appOwnsSession);
    if (!_appOwnsSession) return;
    _sessionEventSub = coordinator.sessionEvents.listen(
      _handleAudioSessionEvent,
    );
  }

  void _handleAudioSessionEvent(VoiceAudioSessionEvent event) {
    if (_disposed || !_appOwnsSession) return;
    switch (event) {
      case VoiceAudioInterruptionBegan():
        // A phone call, Siri or an alarm has the session. Hold the call; it
        // goes on when the system says it may.
        VoiceEventLog.instance.add('interruption-began', <String, Object?>{
          'phase': state.phase.name,
        });
        unawaited(
          _enqueue(() async {
            if (!state.canPause) return;
            _pausedByInterruption = true;
            await _pauseNow();
          }),
        );
      case VoiceAudioInterruptionEnded(:final shouldResume):
        VoiceEventLog.instance.add('interruption-ended', <String, Object?>{
          'shouldResume': shouldResume,
          'phase': state.phase.name,
        });
        unawaited(
          _enqueue(() async {
            if (!shouldResume) {
              // The system will not give the session back on its own, but
              // the call is not ours to end: hold it paused (the pause the
              // interruption began, or one made now) and let the person
              // resume or end it from the call screen.
              if (state.canPause) {
                _pausedByInterruption = true;
                await _pauseNow();
              }
              return;
            }
            // Carries on only a pause the interruption made. One the user
            // made, or a lost route, waits for the user.
            if (!_pausedByInterruption || _pausedByRouteLoss) return;
            if (!state.canResume) return;
            await _resumeNow();
          }),
        );
      case VoiceAudioRouteLost():
        // Headphones or AirPods went away. Stop talking and wait, like the
        // system apps; the reply must not come out of the loudspeaker. A call
        // already on the loudspeaker lost nothing.
        if (state.isSpeakerphoneEnabled) return;
        unawaited(
          _enqueue(() async {
            if (!state.canPause) return;
            _pausedByRouteLoss = true;
            await _pauseNow();
          }),
        );
    }
  }

  Future<void> toggleMute() {
    return _enqueue(() async {
      if (!state.isActive && state.phase != ChatVoiceModePhase.paused) {
        return;
      }
      final realtime = _realtime;
      if (realtime != null) {
        if (realtime.state.muted) {
          // Unmuting ends a pause too: the call is back.
          realtime
            ..setPaused(false)
            ..setMuted(false);
        } else {
          realtime.setMuted(true);
        }
        return;
      }

      if (!state.isMuted) {
        final token = _token;
        final phaseBeforeMute = state.phase;
        try {
          final keepAssistantAlive =
              _awaitingAssistant && state.phase != ChatVoiceModePhase.paused;
          if (keepAssistantAlive) {
            await _serviceLifecycleGate.runExclusive(() async {
              if (!_isCurrent(token)) return;
              await _detachListeningSubscriptions();
              if (!_isCurrent(token)) return;
              final inputOwnsCapture =
                  await _voiceInput?.prepareResponseWaitHandoff() ?? false;
              if (!_isCurrent(token)) return;
              if (!inputOwnsCapture) {
                await _audioSessionCoordinator?.beginResponseWaitCapture(
                  callKitCallId: _activeCallId,
                );
              }
            });
          } else {
            await _cancelListening();
            await _audioSessionCoordinator?.endResponseWaitCapture();
          }
          if (!_isCurrent(token)) return;
          _mutedDuringSpeech =
              phaseBeforeMute == ChatVoiceModePhase.speaking ||
              state.phase == ChatVoiceModePhase.speaking;
          state = state.copyWith(
            phase: ChatVoiceModePhase.muted,
            isMuted: true,
            intensity: 0,
          );
        } catch (error, stackTrace) {
          if (!_isCurrent(token)) return;
          DebugLogger.error(
            'mute-background-audio-failed',
            scope: 'chat/voice_mode',
            error: error,
            stackTrace: stackTrace,
          );
          await _fail(error.toString(), token, _errorKindOf(error));
        }
        return;
      }

      final resumeBargeIn =
          _awaitingAssistant &&
          ref.read(appSettingsProvider).voiceBargeInEnabled &&
          (_voiceInput?.willUseNativeLocalStt ?? false);
      if (_pausedDuringAssistantTurn) {
        _mutedDuringSpeech = false;
        state = state.copyWith(
          phase: ChatVoiceModePhase.starting,
          isMuted: false,
          clearErrorMessage: true,
        );
        await _resumePausedAssistantTurn(_token);
        return;
      }
      if (_awaitingAssistant && !resumeBargeIn) {
        final resumeSpeaking =
            _mutedDuringSpeech || state.phase == ChatVoiceModePhase.speaking;
        _mutedDuringSpeech = false;
        state = state.copyWith(
          phase: resumeSpeaking
              ? ChatVoiceModePhase.speaking
              : ChatVoiceModePhase.sending,
          isMuted: false,
          clearErrorMessage: true,
        );
        // Muting stopped listening for a barge-in; playback that went on
        // meanwhile will not announce itself again.
        _watchForServerBargeIn(_token, armNow: resumeSpeaking);
        return;
      }

      _mutedDuringSpeech = false;
      state = state.copyWith(
        phase: ChatVoiceModePhase.starting,
        isMuted: false,
        clearErrorMessage: true,
      );
      await _startListening(_token, why: 'unmute');
    });
  }

  Future<void> toggleSpeakerphone() {
    return _enqueue(() async {
      if (!state.isActive) return;
      final coordinator = _audioSessionCoordinator;
      if (coordinator == null) return;
      final enabled = !state.isSpeakerphoneEnabled;
      final applied = await coordinator.setSpeakerphoneEnabled(enabled);
      if (_disposed) return;
      // A route the platform refused leaves audio where it was, so the button
      // stays where it was too rather than promising a route nobody is hearing.
      // That holds both ways: the coordinator reads the route back on and off
      // the loudspeaker, and reports the route it finds on every configure
      // pass, so the button shows the real route and the next press always
      // asks for the other one.
      if (!applied) return;
      state = state.copyWith(isSpeakerphoneEnabled: enabled);
    });
  }

  Future<void> cancelSpeaking() {
    return _enqueue(() async {
      final realtime = _realtime;
      if (realtime != null) {
        realtime.interrupt();
        return;
      }
      final tts = _textToSpeech;
      if (tts == null) return;
      _logSpeechStopped('cancel-speaking');
      await tts.stopStreamingTts();
      await tts.stop();
      if (_disposed) return;
      _streamingTtsStarted = false;
      _assistantFinalized = true;
      if (state.isActive && !state.isMuted) {
        await _startListening(_token, why: 'cancel-speaking');
      }
    });
  }

  void collapse() {
    if (state.isActive) {
      state = state.copyWith(isCollapsed: true);
      _storeCollapsed(true);
    }
  }

  void expand() {
    if (state.isActive) {
      state = state.copyWith(isCollapsed: false);
      _storeCollapsed(false);
    }
  }

  void toggleCollapsed() {
    if (state.isActive) {
      final next = !state.isCollapsed;
      state = state.copyWith(isCollapsed: next);
      _storeCollapsed(next);
    }
  }

  /// Remembers the view Dean picked last, so voice mode reopens in it.
  void _storeCollapsed(bool collapsed) {
    if (!PreferencesStore.isReady) return;
    unawaited(
      PreferencesStore.putAll({
        PreferenceKeys.voiceModeCollapsed: collapsed,
        PreferenceKeys.voiceModeViewVersion: _voiceModeViewVersion,
      }),
    );
  }

  /// Starts the call's timing log (voice_event_log.dart) when a Voice
  /// provider can take it. Reads only; nothing here touches the audio.
  Future<void> _beginVoiceEventLog(AppSettings settings) async {
    try {
      final sender = voiceEventSenderFor(ref);
      if (sender == null) return;
      final voice = ref.read(directVoiceProviderProvider);
      final route = await _currentRouteClass();
      VoiceEventLog.instance.start(
        sender: sender,
        info: <String, Object?>{
          'silenceMs': settings.voiceSilenceDuration,
          'bargeIn': settings.voiceBargeInEnabled,
          'streamSpeech': voice?.settings.streamSpeech,
          'echoCancel': settings.voiceEngineEchoCancel,
          'firstClause': settings.voiceShortFirstClause,
          'prefetch': kTtsServerPrefetchParallelism,
          'route': route.name,
          'stt': settings.sttPreference.name,
          'sttServer': _voiceInput?.prefersServerOnly,
        },
      );
    } catch (_) {
      // A call is never held up by its log.
    }
  }

  Future<void> _initializeTts(VoiceModeSpeech tts, AppSettings settings) {
    tts.setVoiceCallActive(true);
    return tts.initialize(
      deviceVoice: settings.ttsVoice,
      serverVoice: settings.ttsServerVoiceId,
      speechRate: settings.ttsSpeechRate,
      pitch: settings.ttsPitch,
      volume: settings.ttsVolume,
      engine: settings.ttsEngine,
    );
  }

  Future<void> _startCallKit(String modelName, int token) async {
    // Without the system call UI the call is the app's own.
    if (_appOwnsSession) return;
    final callKit = _callKit!;
    if (!callKit.isAvailable) {
      return;
    }

    await callKit.checkAndCleanActiveCalls();
    if (!_isCurrent(token)) return;

    await callKit.requestPermissions();
    if (!_isCurrent(token)) return;

    final callId = await callKit.startOutgoingVoiceCall(
      calleeName: modelName,
      handle: 'Conduit AI',
    );
    if (callId == null) {
      return;
    }
    if (!_isCurrent(token)) {
      await _endCallAfterDispose(callKit, callId);
      return;
    }

    _activeCallId = callId;
    state = state.copyWith(activeCallId: callId);
    await _audioSessionCoordinator?.setActiveCallKitCallId(callId);
    if (!_isCurrent(token)) return;
    await _callKitSub?.cancel();
    _callKitSub = callKit.events.listen((event) {
      _handleCallKitEvent(event);
    });
  }

  /// A `speech-stopped` event: the controller's view of why assistant speech
  /// ended or handed back to listening, with the part it was on and how many
  /// parts were still waiting.
  void _logSpeechStopped(
    String reason, [
    Map<String, Object?> extra = const {},
  ]) {
    _lastSpeechStopReason = reason;
    final total = _assistantSpeechChunks.length;
    final index = _activeAssistantSpeechChunkIndex;
    VoiceEventLog.instance.add('speech-stopped', <String, Object?>{
      'reason': reason,
      'part': index,
      'queued': total == 0 || index < 0
          ? 0
          : (total - index - 1).clamp(0, total),
      'phase': state.phase.name,
      ...extra,
    });
  }

  void _handleCallKitEvent(VoiceCallKitEvent event) {
    if (_disposed) return;
    final callId = _activeCallId;
    if (callId == null) return;

    switch (event) {
      case VoiceCallKitEnded(callId: final endedCallId):
        if (endedCallId == callId) {
          _stoppingFromCallKit = true;
          _noteEnd('callkit');
          _cancelStart();
          unawaited(
            _enqueue(() => _stopInternal(endCallKit: false, reason: 'callkit')),
          );
        }
      case VoiceCallKitMuteToggled(callId: final mutedCallId, :final isMuted):
        if (mutedCallId == callId && isMuted != state.isMuted) {
          unawaited(toggleMute());
        }
    }
  }

  void _listenForTtsEvents(VoiceModeSpeech tts, int token) {
    unawaited(_ttsSub?.cancel());
    _ttsSub = tts.events.listen((event) {
      if (!_isCurrent(token)) return;

      switch (event) {
        case TtsStarted():
          if (_awaitingAssistant && state.phase != ChatVoiceModePhase.paused) {
            _assistantSpeechStartedAt ??= DateTime.now();
            _bargeInDetector?.arm();
            if (_activeAssistantSpeechChunkIndex < 0 &&
                _assistantSpeechChunks.isNotEmpty) {
              _handleTtsChunkStarted(0);
            }
            state = state.copyWith(phase: ChatVoiceModePhase.speaking);
          }
        case TtsCompleted():
          if (_assistantFinalized && _awaitingAssistant) {
            unawaited(_resumeAfterAssistantSpeech(token));
          }
        case TtsCancelled():
          break;
        case TtsError(:final message):
          _logSpeechStopped('tts-error', <String, Object?>{
            'error': message.length > 160 ? message.substring(0, 160) : message,
          });
          VoiceEventLog.instance.add('tts-error', <String, Object?>{
            'message': message.length > 160
                ? message.substring(0, 160)
                : message,
            'phase': state.phase.name,
          });
          state = state.copyWith(
            errorMessage: message,
            errorKind: ChatVoiceModeError.other,
          );
          // Failed speech still ends the assistant turn. Without this the
          // recognizer stopped for playback is never restarted, leaving voice
          // mode active with no way to accept the next utterance.
          if (_awaitingAssistant) {
            _assistantFinalized = true;
            unawaited(_resumeAfterAssistantSpeech(token));
          }
        case TtsPaused():
        case TtsResumed():
          break;
        case TtsChunkStarted(:final chunkIndex):
          _handleTtsChunkStarted(chunkIndex);
          // A chunk starting is speech playing, even when the player kept
          // playing across a gap (a tool call mid-reply) and so never
          // reported a fresh start: the panel must not stay on "Thinking".
          if (_awaitingAssistant &&
              chunkIndex >= 0 &&
              state.phase == ChatVoiceModePhase.sending) {
            _assistantSpeechStartedAt ??= DateTime.now();
            _bargeInDetector?.arm();
            state = state.copyWith(phase: ChatVoiceModePhase.speaking);
          }
        case TtsWordProgress(:final start, :final end):
          _handleTtsWordProgress(start, end);
      }
    });
  }

  Future<void> _listenForResponseCaptureFailures(
    VoiceModeInput input,
    VoiceAudioSessionPort? audioSessionCoordinator,
    int token,
  ) async {
    await _responseCaptureFailureSub?.cancel();
    await _audioResponseCaptureFailureSub?.cancel();

    void handleFailure(Object error) {
      if (!_isCurrent(token)) return;
      DebugLogger.error(
        'response-capture-failed',
        scope: 'chat/voice_mode',
        error: error,
      );
      unawaited(_fail(error.toString(), token, _errorKindOf(error)));
    }

    _responseCaptureFailureSub = input.responseCaptureFailures.listen(
      handleFailure,
      onError: handleFailure,
    );
    _audioResponseCaptureFailureSub = audioSessionCoordinator
        ?.responseCaptureFailures
        .listen(handleFailure, onError: handleFailure);
  }

  Future<void> _startBackgroundVoiceLease(
    VoiceModeInput input,
    int token,
  ) async {
    await _stopBackgroundVoiceLease();
    if (!_isCurrent(token)) return;

    final leaseId = 'chat-voice-mode-$token';
    final requiresMicrophone = _requiresNativeBackgroundMicrophone(input);
    final background = _backgroundCoordinator!;

    _backgroundLeaseId = leaseId;
    _iosAudioSessionManagedExternally = true;

    await background.setExternalAudioSessionOwner(!requiresMicrophone);
    if (!_isCurrent(token)) {
      if (_backgroundLeaseId == leaseId) {
        _backgroundLeaseId = null;
      }
      await background.setExternalAudioSessionOwner(false);
      return;
    }

    try {
      await background.startVoiceLease(
        leaseId: leaseId,
        requiresMicrophone: requiresMicrophone,
      );
    } catch (error, stackTrace) {
      DebugLogger.error(
        'background-start-failed',
        scope: 'chat/voice_mode',
        error: error,
        stackTrace: stackTrace,
        data: {'requiresMicrophone': requiresMicrophone},
      );
    }
    if (!_isCurrent(token)) {
      if (_backgroundLeaseId == leaseId) {
        _backgroundLeaseId = null;
      }
      try {
        await background.stopVoiceLease(leaseId);
      } catch (_) {}
      await background.setExternalAudioSessionOwner(false);
      return;
    }

    _startBackgroundKeepAliveTimer(token, background);
  }

  bool _requiresNativeBackgroundMicrophone(VoiceModeInput input) {
    return _platform.isAndroid ||
        input.hasServerStt && (input.prefersServerOnly || !input.hasLocalStt);
  }

  void _startBackgroundKeepAliveTimer(
    int token,
    VoiceBackgroundPort background,
  ) {
    _backgroundKeepAliveTimer?.cancel();
    _backgroundKeepAliveTimer = Timer.periodic(_backgroundKeepAliveInterval, (
      _,
    ) {
      if (!_isCurrent(token) || !state.isActive) {
        _backgroundKeepAliveTimer?.cancel();
        _backgroundKeepAliveTimer = null;
        return;
      }
      unawaited(background.keepAlive());
    });
  }

  Future<void> _stopBackgroundVoiceLease([
    VoiceBackgroundPort? coordinator,
  ]) async {
    _backgroundKeepAliveTimer?.cancel();
    _backgroundKeepAliveTimer = null;
    _iosAudioSessionManagedExternally = false;

    final leaseId = _backgroundLeaseId;
    _backgroundLeaseId = null;
    final background = coordinator ?? _backgroundCoordinator;
    if (background == null) return;

    if (leaseId != null) {
      try {
        await background.stopVoiceLease(leaseId);
      } catch (error, stackTrace) {
        DebugLogger.error(
          'background-stop-failed',
          scope: 'chat/voice_mode',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }

    await background.setExternalAudioSessionOwner(false);
  }

  Future<void> _startListening(
    int token, {
    String why = 'unspecified',
    void Function()? beforeAcceptingTranscripts,
    Duration? heldAudioLookback,
  }) async {
    if (!_isCurrent(token) || state.isMuted) {
      return;
    }
    if ((why == 'after-assistant-speech' || why == 'cancel-speaking') &&
        await _tryReopenSocket(token)) {
      return;
    }

    VoiceEventLog.instance.add('listening-start', <String, Object?>{
      'why': why,
      'source': _listeningSource(why),
      'phase': state.phase.name,
      'afterSpeech': _awaitingAssistant || _assistantFinalized,
    });
    final input = _voiceInput!;
    final transferResponseCaptureToLocalStt = input.willUseNativeLocalStt;
    if (!transferResponseCaptureToLocalStt) {
      await _audioSessionCoordinator?.endResponseWaitCapture();
      if (!_isCurrent(token) || state.isMuted) return;
    }

    final bufferedEvents = <VoiceTranscriptEvent>[];
    Object? bufferedError;
    StackTrace? bufferedErrorStackTrace;
    var bufferedDone = false;
    var acceptingTranscripts = beforeAcceptingTranscripts == null;

    void onTranscriptEvent(VoiceTranscriptEvent event) {
      if (!acceptingTranscripts) {
        bufferedEvents.add(event);
        return;
      }
      _handleTranscriptEvent(event, token);
    }

    void onTranscriptError(Object error, StackTrace stackTrace) {
      if (!acceptingTranscripts) {
        bufferedError ??= error;
        bufferedErrorStackTrace ??= stackTrace;
        return;
      }
      if (!_isCurrent(token)) return;
      DebugLogger.error(
        'listen-failed',
        scope: 'chat/voice_mode',
        error: error,
        stackTrace: stackTrace,
      );
      unawaited(_fail(error.toString(), token, _errorKindOf(error)));
    }

    void onTranscriptDone() {
      if (!acceptingTranscripts) {
        bufferedDone = true;
        return;
      }
      _transcriptSub = null;
      unawaited(_handleListeningDone(token));
    }

    if (_transcriptSub == null || !input.isListening) {
      await _detachListeningSubscriptions();
      if (!input.isHoldingServerRecorderForResponse) {
        try {
          await input.stopListening();
        } catch (_) {}
      }
    }
    if (!_isCurrent(token)) return;
    await _audioSessionCoordinator?.configureForListening();
    if (!_isCurrent(token)) return;

    _currentTranscript = '';
    _prewarmForNextTurn(minGap: Duration.zero);
    if (_bargeInProvisional) {
      // A take that may be the assistant's own echo: the panel goes on
      // showing the speech until the take is judged real.
      state = state.copyWith(intensity: 0, clearErrorMessage: true);
    } else {
      state = state.copyWith(
        phase: ChatVoiceModePhase.listening,
        transcript: '',
        assistantPreview: '',
        clearSpokenResponse: true,
        intensity: 0,
        clearErrorMessage: true,
      );
    }

    final callId = state.activeCallId;
    if (!_markedCallConnected && callId != null) {
      _markedCallConnected = true;
      unawaited(_callKit!.markCallConnected(callId));
    }

    if (_transcriptSub == null || !input.isListening) {
      final stream = heldAudioLookback == null
          ? await input.beginListeningEvents(
              iosAudioSessionManagedExternally:
                  _iosAudioSessionManagedExternally,
            )
          : await input.beginBargeInListeningEvents(
              lookback: heldAudioLookback,
              iosAudioSessionManagedExternally:
                  _iosAudioSessionManagedExternally,
            );
      if (!_isCurrent(token)) {
        await _stopVoiceInputAfterDispose(input);
        return;
      }

      await _transcriptSub?.cancel();
      _transcriptSub = stream.listen(
        onTranscriptEvent,
        onError: onTranscriptError,
        onDone: onTranscriptDone,
      );
    }
    if (transferResponseCaptureToLocalStt) {
      await _audioSessionCoordinator?.endResponseWaitCapture();
      if (!_isCurrent(token) || state.isMuted) return;
    }

    await _intensitySub?.cancel();
    if (!_isCurrent(token)) return;
    _intensitySub = input.intensityStream.listen((intensity) {
      if (_bargeInProvisional && intensity >= _provisionalSpeechIntensity) {
        _lastProvisionalSpeechAt = DateTime.now();
      }
      if (_isCurrent(token) && state.phase == ChatVoiceModePhase.listening) {
        state = state.copyWith(intensity: intensity);
      }
    });

    final startupError = bufferedError;
    if (startupError != null) {
      final stackTrace = bufferedErrorStackTrace ?? StackTrace.current;
      DebugLogger.error(
        'listen-failed',
        scope: 'chat/voice_mode',
        error: startupError,
        stackTrace: stackTrace,
      );
      Error.throwWithStackTrace(startupError, stackTrace);
    }

    beforeAcceptingTranscripts?.call();
    if (!_isCurrent(token)) return;
    acceptingTranscripts = true;
    for (final event in bufferedEvents) {
      if (!_isCurrent(token)) return;
      _handleTranscriptEvent(event, token);
    }
    bufferedEvents.clear();
    if (bufferedDone && _isCurrent(token)) {
      _transcriptSub = null;
      unawaited(_handleListeningDone(token));
    }
  }

  void _handleTranscriptEvent(VoiceTranscriptEvent event, int token) {
    if (!_isCurrent(token) || state.isMuted) return;

    _currentTranscript = event.text;
    if (!event.isFinal &&
        event.text.trim().isNotEmpty &&
        state.phase == ChatVoiceModePhase.listening) {
      // Speech has started: read ahead what the send will need, unless the
      // listening phase just did.
      _prewarmForNextTurn(minGap: const Duration(seconds: 5));
    }
    if (state.isActive &&
        state.phase != ChatVoiceModePhase.paused &&
        !_bargeInProvisional) {
      state = state.copyWith(transcript: event.text);
    }

    if (event.isFinal) {
      unawaited(_handleFinalTranscript(event.text, token));
    } else if (_isOnDeviceVoiceOnset(event.text)) {
      unawaited(_interruptOnDeviceOnset(token));
    }
  }

  /// Whether a partial transcript heard while the assistant speaks is the
  /// user starting to talk (on-device recognition, barge-in on): a few words,
  /// past the grace period after playback started, and not just words the
  /// assistant is saying, which is what its own echo would produce.
  bool _isOnDeviceVoiceOnset(String text) {
    if (!_awaitingAssistant ||
        state.phase != ChatVoiceModePhase.speaking ||
        !(_voiceInput?.isUsingNativeLocalStt ?? false) ||
        !ref.read(appSettingsProvider).voiceBargeInEnabled) {
      return false;
    }
    final startedAt = _assistantSpeechStartedAt;
    if (startedAt == null ||
        DateTime.now().difference(startedAt) < _onDeviceOnsetGrace) {
      return false;
    }
    final words = _wordsOf(text);
    if (words.length < _onDeviceOnsetMinWords) return false;
    final spoken = _wordsOf(state.assistantPreview).toSet();
    return !words.every(spoken.contains);
  }

  /// Runs of letters, digits and apostrophes, except that each Han or kana
  /// character counts as a word of its own: Chinese and Japanese are written
  /// without spaces, so a short phrase would otherwise read as one word.
  static final RegExp _wordPattern = RegExp(
    r"[\p{sc=Han}\p{sc=Hiragana}\p{sc=Katakana}]"
    r"|(?:(?![\p{sc=Han}\p{sc=Hiragana}\p{sc=Katakana}])[\p{L}\p{N}'])+",
    unicode: true,
  );

  static List<String> _wordsOf(String text) => _wordPattern
      .allMatches(text.toLowerCase())
      .map((match) => match[0]!)
      .toList();

  /// Stops the assistant on the user's first words; the recognizer keeps
  /// listening and its final transcript is sent as the next turn.
  Future<void> _interruptOnDeviceOnset(int token) {
    return _enqueue(() async {
      if (!_isCurrent(token) ||
          !_awaitingAssistant ||
          state.isMuted ||
          state.phase != ChatVoiceModePhase.speaking) {
        return;
      }
      DebugLogger.info('barge-in-onset', scope: 'chat/voice_mode');
      await _interruptAssistantForBargeIn(token);
      if (!_isCurrent(token)) return;
      state = state.copyWith(
        phase: ChatVoiceModePhase.listening,
        assistantPreview: '',
        intensity: 0,
      );
    });
  }

  /// Listens for the user starting to talk over the assistant through the
  /// server recorder held for its turn (server recognition, barge-in on).
  /// Playback starting arms it, or [armNow] when playback is already going.
  void _watchForServerBargeIn(int token, {bool armNow = false}) {
    final input = _voiceInput;
    if (!_isCurrent(token) ||
        input == null ||
        !_awaitingAssistant ||
        !input.isHoldingServerRecorderForResponse ||
        !ref.read(appSettingsProvider).voiceBargeInEnabled) {
      return;
    }
    unawaited(_bargeInLevelSub?.cancel());
    final detector = BargeInOnsetDetector();
    if (armNow) detector.arm();
    _bargeInDetector = detector;
    _bargeInLevelSub = input.heldCaptureLevels.listen((level) {
      if (!_isCurrent(token) ||
          !identical(_bargeInDetector, detector) ||
          state.isMuted ||
          state.phase == ChatVoiceModePhase.paused) {
        return;
      }
      _recentHeldDb.add(level.dbfs);
      if (_recentHeldDb.length > _bargeProbePreFrames) {
        _recentHeldDb.removeAt(0);
      }
      final lookback = detector.add(level);
      if (lookback != null) {
        _onsetInfo = <String, Object?>{
          'levelDb': level.dbfs.round(),
          'thresholdDb': detector.thresholdDb.round(),
          'sinceArmMs': detector.sinceArmed.inMilliseconds,
        };
        unawaited(_handleServerBargeInOnset(token, lookback));
      }
    });
  }

  Future<void> _stopWatchingForServerBargeIn() async {
    final sub = _bargeInLevelSub;
    _bargeInLevelSub = null;
    _bargeInDetector = null;
    await sub?.cancel();
  }

  /// The user started talking over the assistant: stop it, and record what
  /// they say from just before they started until they stop, through the
  /// same voice activity detection and server transcription as any turn.
  Future<void> _handleServerBargeInOnset(int token, Duration lookback) {
    return _enqueue(() async {
      if (!_isCurrent(token) ||
          !_awaitingAssistant ||
          state.isMuted ||
          state.phase == ChatVoiceModePhase.paused) {
        return;
      }
      await _stopWatchingForServerBargeIn();
      DebugLogger.info(
        'barge-in-onset',
        scope: 'chat/voice_mode',
        data: {'lookbackMs': lookback.inMilliseconds},
      );
      try {
        // Pause rather than stop: if the take turns out to be the
        // assistant's own voice, playback carries on where it was.
        _bargeInProvisional = true;
        _previewBeforeBargeIn = state.assistantPreview;
        _provisionalStartedAt = DateTime.now();
        _lastProvisionalSpeechAt = null;
        VoiceEventLog.instance.add('barge-in-provisional', <String, Object?>{
          'lookbackMs': lookback.inMilliseconds,
          ..._onsetInfo,
          'preview': _clip(_previewBeforeBargeIn),
        });
        _probePaused = false;
        _probeOnsetAt = DateTime.now();
        _probePreDb = _recentHeldDb.isEmpty ? null : _mean(_recentHeldDb);
        _provisionalDucked = await _textToSpeech!.duck(
          provisionalDuckLevel,
          ramp: _duckDownRamp,
        );
        if (_provisionalDucked) {
          VoiceEventLog.instance.add('barge-in-duck', <String, Object?>{
            'level': provisionalDuckLevel,
            'rampMs': _duckDownRamp.inMilliseconds,
          });
          _startBargeProbe(token);
        } else {
          await _textToSpeech!.pause();
        }
        _armProvisionalWatchdog(token, provisionalBargeInTimeout);
        if (!_isCurrent(token)) return;
        _pendingFinalTranscripts.clear();
        _lastSubmittedTranscript = null;
        await _startListening(
          token,
          heldAudioLookback: lookback,
          why: 'barge-in-provisional',
        );
      } catch (error, stackTrace) {
        if (!_isCurrent(token)) return;
        DebugLogger.error(
          'barge-in-listen-failed',
          scope: 'chat/voice_mode',
          error: error,
          stackTrace: stackTrace,
        );
        await _fail(error.toString(), token, _errorKindOf(error));
      }
    });
  }

  Future<void> _handleFinalTranscript(String text, int token) async {
    if (!_isCurrent(token) ||
        state.isMuted ||
        state.phase == ChatVoiceModePhase.paused) {
      return;
    }

    final transcript = text.trim();
    if (transcript.isEmpty) {
      if (_bargeInProvisional) {
        VoiceEventLog.instance.add('barge-in-dropped', <String, Object?>{
          'reason': 'empty',
          'words': 0,
        });
      }
      return;
    }

    if (_bargeInProvisional) {
      final routeClass = await _currentRouteClass();
      final profile = VoiceRouteProfile.forClass(routeClass);
      final confidence = TranscriptionConfidenceLog.instance.lookup(transcript);
      final echo =
          !profile.bargeInAllowed ||
          isBargeInEcho(
            transcript,
            _previewBeforeBargeIn,
            confidence: confidence,
            profile: profile,
          );
      final decisionData = <String, Object?>{
        'route': routeClass.name,
        'decision': echo ? 'echo' : 'user',
        'words': _wordsOf(transcript).length,
        'avgLogprob': ?confidence?.avgLogprob,
        'noSpeechProb': ?confidence?.noSpeechProb,
      };
      DebugLogger.info(
        'barge-in-decision',
        scope: 'chat/voice_mode',
        data: decisionData,
      );
      VoiceEventLog.instance.add('barge-in-decision', decisionData);
      if (echo) {
        _ignoredEchoTranscript = transcript;
        VoiceEventLog.instance.add('barge-in-dropped', <String, Object?>{
          'reason': profile.bargeInAllowed ? 'echo' : 'route-no-barge-in',
          'words': _wordsOf(transcript).length,
          'text': _clip(transcript),
        });
        await _resumeAfterBargeInEcho(token, transcript, reason: 'echo');
        return;
      }
      // Real words: the drain below stops the assistant and sends them.
      _bargeInProvisional = false;
      _provisionalDucked = false;
      _probePaused = false;
      _cancelBargeProbe();
      state = state.copyWith(
        phase: ChatVoiceModePhase.listening,
        assistantPreview: '',
        clearSpokenResponse: true,
        intensity: 0,
      );
    } else if (_awaitingAssistant && transcript == _ignoredEchoTranscript) {
      // The same take reported a second time (final event and end of take).
      return;
    }

    if (_sendingTranscript) {
      _enqueuePendingFinalTranscript(transcript);
      return;
    }

    await _drainFinalTranscripts(transcript, token);
  }

  Future<void> _handleListeningDone(int token) async {
    if (!_isCurrent(token) ||
        (state.phase != ChatVoiceModePhase.listening &&
            !(_bargeInProvisional &&
                state.phase == ChatVoiceModePhase.speaking))) {
      return;
    }

    final input = _voiceInput!;
    final transcript = input.lastCompletedTranscriptSendable
        ? _currentTranscript.trim()
        : '';
    if (transcript.isEmpty) {
      if (_bargeInProvisional) {
        VoiceEventLog.instance.add('barge-in-dropped', <String, Object?>{
          'reason': 'empty-take',
          'words': 0,
        });
        await _resumeAfterBargeInEcho(token, '', reason: 'empty-take');
        return;
      }
      await _restartAfterEmptyTranscript(token);
      return;
    }

    _emptyTranscriptRestarts = 0;
    await _handleFinalTranscript(transcript, token);
  }

  Future<void> _drainFinalTranscripts(
    String initialTranscript,
    int token,
  ) async {
    var transcript = initialTranscript;

    while (true) {
      if (!_isCurrent(token) ||
          state.isMuted ||
          state.phase == ChatVoiceModePhase.paused) {
        return;
      }

      if (transcript == _lastSubmittedTranscript) {
        final pending = _takePendingFinalTranscript();
        if (pending == null) {
          return;
        }
        transcript = pending;
        continue;
      }

      _sendingTranscript = true;
      try {
        _emptyTranscriptRestarts = 0;
        final assistantActive =
            _awaitingAssistant ||
            state.phase == ChatVoiceModePhase.sending ||
            state.phase == ChatVoiceModePhase.speaking;
        if (assistantActive &&
            !ref.read(appSettingsProvider).voiceBargeInEnabled) {
          _pendingFinalTranscripts.clear();
          return;
        }
        if (assistantActive) {
          await _interruptAssistantForBargeIn(token);
        }
        if (!_isCurrent(token) || state.isMuted) return;
        _lastSubmittedTranscript = transcript;
        await _sendTranscript(transcript, token);
      } finally {
        _sendingTranscript = false;
      }

      final pending = _takePendingFinalTranscript();
      if (pending == null || pending == transcript) {
        return;
      }
      transcript = pending;
    }
  }

  void _enqueuePendingFinalTranscript(String transcript) {
    final pending = transcript.trim();
    if (pending.isEmpty || pending == _lastSubmittedTranscript) {
      return;
    }
    if (_pendingFinalTranscripts.isNotEmpty &&
        _pendingFinalTranscripts.last == pending) {
      return;
    }
    _pendingFinalTranscripts.addLast(pending);
  }

  String? _takePendingFinalTranscript() {
    while (_pendingFinalTranscripts.isNotEmpty) {
      final pending = _pendingFinalTranscripts.removeFirst().trim();
      if (pending.isNotEmpty && pending != _lastSubmittedTranscript) {
        return pending;
      }
    }
    return null;
  }

  Future<void> _restartAfterEmptyTranscript(int token) async {
    _emptyTranscriptRestarts++;
    if (_emptyTranscriptRestarts > _maxEmptyTranscriptRestarts) {
      state = state.copyWith(
        phase: ChatVoiceModePhase.paused,
        errorMessage: 'No speech detected.',
        errorKind: ChatVoiceModeError.noSpeech,
      );
      return;
    }

    final exponent = _emptyTranscriptRestarts - 1;
    final delayMs = (_emptyTranscriptBaseDelayMs << exponent).clamp(
      _emptyTranscriptBaseDelayMs,
      _emptyTranscriptMaxDelayMs,
    );
    await Future<void>.delayed(Duration(milliseconds: delayMs));
    if (_isCurrent(token) && state.phase == ChatVoiceModePhase.listening) {
      await _startListening(token, why: 'empty-transcript-retry');
    }
  }

  DateTime? _lastTurnPrewarmAt;

  /// Starts, in the background, the settings, socket and location reads the
  /// next send will use. Not awaited; a failure only means the send reads them
  /// itself, as it always did.
  void _prewarmForNextTurn({required Duration minGap}) {
    final last = _lastTurnPrewarmAt;
    final now = DateTime.now();
    if (last != null && now.difference(last) < minGap) return;
    _lastTurnPrewarmAt = now;
    prewarmVoiceTurn(ref);
  }

  Future<void> _sendTranscript(String transcript, int token) async {
    if (!_isCurrent(token)) return;
    VoiceEventLog.instance.add('send-start');

    try {
      final input = _voiceInput!;
      final keepListening =
          ref.read(appSettingsProvider).voiceBargeInEnabled &&
          input.isUsingNativeLocalStt;
      var inputOwnsResponseCapture = false;
      await _serviceLifecycleGate.runExclusive(() async {
        if (!_isCurrent(token)) return;
        if (!keepListening) {
          await _detachListeningSubscriptions();
          if (!_isCurrent(token)) return;
          inputOwnsResponseCapture = await input.prepareResponseWaitHandoff();
          if (!_isCurrent(token)) return;
        }
        if (_platform.isIOS) {
          await _audioSessionCoordinator?.configureForBargeInSpeaking();
        } else {
          await _audioSessionCoordinator?.configureForSpeaking();
        }
        if (!_isCurrent(token)) return;
        if (!keepListening && !inputOwnsResponseCapture) {
          await _audioSessionCoordinator?.beginResponseWaitCapture(
            callKitCallId: _activeCallId,
          );
        }
      });
      if (!_isCurrent(token)) return;
      final tts = _textToSpeech!;
      _assistantMessageIdsBeforeTurn = _currentAssistantMessageIds();
      ref.read(streamingContentProvider.notifier).set(null);
      await tts.startStreamingTts();
      if (!_isCurrent(token)) {
        await _stopTtsAfterDispose(tts);
        return;
      }

      _streamingTtsStarted = true;
      _assistantFinalized = false;
      _awaitingAssistant = true;
      _lastFedAssistantText = '';
      _activeAssistantMessageId = null;
      _assistantSpeechChunks = const <String>[];
      _activeAssistantSpeechChunkIndex = -1;
      _assistantSpeechStartedAt = null;
      if (inputOwnsResponseCapture) _watchForServerBargeIn(token);

      state = state.copyWith(
        phase: ChatVoiceModePhase.sending,
        transcript: transcript,
        assistantPreview: '',
        clearSpokenResponse: true,
        intensity: 0,
        clearErrorMessage: true,
      );

      await _backgroundCoordinator?.keepAlive();
      if (!_isCurrent(token)) return;
      final selectedToolIds = ref.read(selectedToolIdsProvider);
      _speechPrefix = '';
      if (await _tryDirectTurn(transcript, token)) return;
      if (!_isCurrent(token)) return;
      VoiceEventLog.instance.add('durable-send');
      await durableSend(
        ref,
        transcript,
        null,
        toolIds: selectedToolIds,
        isVoiceMode: true,
      );
      if (!_isCurrent(token)) return;

      _activeAssistantMessageId ??= _activeAssistantMessage()?.id;
      _handleAssistantContentChanged();
      _handleChatMessagesChanged(ref.read(chatMessagesProvider));
    } catch (error, stackTrace) {
      if (!_isCurrent(token)) return;
      DebugLogger.error(
        'send-failed',
        scope: 'chat/voice_mode',
        error: error,
        stackTrace: stackTrace,
      );
      await _fail(error.toString(), token, _errorKindOf(error));
    }
  }

  /// Sends [transcript] straight to the relay (Contract A). Returns true when
  /// the turn was handled here (answered, failed or cancelled); false when it
  /// must go the Open WebUI way (no relay route, route "owui", or the relay
  /// is missing or off). Writes nothing to Open WebUI.
  Future<bool> _tryDirectTurn(String transcript, int token) async {
    final access = ref.read(voiceDirectAccessProvider);
    final conversation = ref.read(activeConversationProvider);
    if (access == null ||
        _directDisabled ||
        !_usesOpenWebUiTransport ||
        conversation == null ||
        isTemporaryChat(conversation.id) ||
        isDirectLocalConversation(conversation)) {
      return false;
    }
    final chatId = conversation.id;
    _directChatId = chatId;
    _directCallId ??= newVoiceTurnId();
    final VoiceDirectLease lease;
    try {
      lease = access.acquire();
    } catch (_) {
      return false;
    }
    _directTurnActive = true;
    final spoken = StringBuffer();
    try {
      VoiceEventLog.instance.add('direct-send');
      final result = await _directRunner.run(
        client: lease.client,
        callId: _directCallId!,
        chatId: chatId,
        text: transcript,
        chatMessages: ref.read(chatMessagesProvider),
        personaId: ref.read(voiceDirectPersonaIdProvider),
        build: VoiceEventLog.instance.build,
        tz: DateTime.now().timeZoneName,
        onAck: (ack) {
          if (!_isCurrent(token) || _speechPrefix.isNotEmpty) return;
          _speechPrefix = '$ack ';
          _feedAssistantText(_speechPrefix);
        },
        onDelta: (delta) {
          if (!_isCurrent(token)) return;
          VoiceEventLog.instance.add('direct-delta');
          spoken.write(delta);
          _feedAssistantText(_speechPrefix + spoken.toString());
        },
      );
      if (!_isCurrent(token)) return true;
      if (result.disableDirect) _directDisabled = true;
      switch (result.outcome) {
        case VoiceDirectOutcome.done:
          final text = spoken.isEmpty ? result.content : spoken.toString();
          _assistantFinalized = false;
          await _finishAssistantResponse(
            token,
            directText: _speechPrefix + text,
          );
          return true;
        case VoiceDirectOutcome.cancelled:
          return true;
        case VoiceDirectOutcome.failed:
          _assistantFinalized = true;
          await _fail(
            result.error ?? 'The voice turn failed.',
            token,
            ChatVoiceModeError.message,
          );
          return true;
        case VoiceDirectOutcome.owui:
        case VoiceDirectOutcome.fallback:
          VoiceEventLog.instance.add('direct-fallback', <String, Object?>{
            'why': result.outcome.name,
            'error': ?result.error,
          });
          return false;
      }
    } finally {
      _directTurnActive = false;
      lease.release();
    }
  }

  /// At call end: stop any direct turn in flight and, when the call had direct
  /// turns, re-read the chat from Open WebUI (the relay saved them there).
  void _endDirectCall() {
    _directRunner.cancel();
    _directTurnActive = false;
    final had = _directHistory.hasDirectTurns;
    final chatId = _directChatId;
    _directHistory.clear();
    _directDisabled = false;
    _directCallId = null;
    _directChatId = null;
    _speechPrefix = '';
    if (had && chatId != null && !_disposed) {
      final access = ref.read(voiceDirectAccessProvider);
      unawaited(_rereadChatAfterCall(chatId, access));
    }
  }

  Future<void> _rereadChatAfterCall(
    String chatId,
    VoiceDirectAccess? access,
  ) async {
    try {
      if (access != null) {
        final lease = access.acquire();
        try {
          await lease.client.waitSaved(chatId);
        } finally {
          lease.release();
        }
      }
      if (_disposed) return;
      final refreshed = await pullChatOrFetch(ref, chatId);
      if (refreshed == null || _disposed) return;
      if (ref.read(activeConversationProvider)?.id != chatId) return;
      ref.read(activeConversationProvider.notifier).set(refreshed);
    } catch (error, stackTrace) {
      DebugLogger.warning(
        'direct-call-reread-failed',
        scope: 'chat/voice_mode',
        data: {'error': error, 'stackTrace': stackTrace},
      );
    }
  }

  Future<VoiceRouteClass> _currentRouteClass() async {
    try {
      return await _audioSessionCoordinator?.currentRouteClass() ??
          VoiceRouteClass.other;
    } catch (_) {
      return VoiceRouteClass.other;
    }
  }

  /// A provisional barge-in heard only the assistant (or nothing): drop the
  /// take, hold the recorder for the response again and resume playback.
  Future<void> _resumeAfterBargeInEcho(
    int token,
    String transcript, {
    String reason = 'echo',
  }) async {
    if (!_isCurrent(token) || !_bargeInProvisional) return;
    _bargeInProvisional = false;
    _cancelProvisionalWatchdog();
    _cancelBargeProbe();
    final ducked = _provisionalDucked;
    final probePaused = _probePaused;
    _provisionalDucked = false;
    _probePaused = false;
    VoiceEventLog.instance.add('barge-in-resume', <String, Object?>{
      'reason': reason,
      'pausedMs': ?_provisionalPausedMs(),
      'ducked': ducked,
      'probePaused': probePaused,
    });
    // Ducked speech never stopped, so it comes back at once, before the
    // recorder handoff below (which took about half a second while paused).
    if (ducked) {
      try {
        // Paused on probable speech: back to full volume before it resumes.
        await _textToSpeech!.unduck(
          ramp: probePaused ? Duration.zero : _duckUpRamp,
        );
      } catch (_) {}
    }
    DebugLogger.info(
      'barge-in-echo-ignored',
      scope: 'chat/voice_mode',
      data: {'words': _wordsOf(transcript).length},
    );
    try {
      final input = _voiceInput!;
      var inputOwnsResponseCapture = false;
      await _serviceLifecycleGate.runExclusive(() async {
        if (!_isCurrent(token)) return;
        await _detachListeningSubscriptions();
        if (!_isCurrent(token)) return;
        inputOwnsResponseCapture = await input.prepareResponseWaitHandoff();
        if (!_isCurrent(token)) return;
        if (_platform.isIOS) {
          await _audioSessionCoordinator?.configureForBargeInSpeaking();
        } else {
          await _audioSessionCoordinator?.configureForSpeaking();
        }
        if (!_isCurrent(token)) return;
        if (!inputOwnsResponseCapture) {
          await _audioSessionCoordinator?.beginResponseWaitCapture(
            callKitCallId: _activeCallId,
          );
        }
      });
      if (!_isCurrent(token)) return;
      _pendingFinalTranscripts.clear();
      _currentTranscript = '';
      state = state.copyWith(
        phase: ChatVoiceModePhase.speaking,
        transcript: '',
        assistantPreview: state.assistantPreview.isEmpty
            ? _previewBeforeBargeIn
            : state.assistantPreview,
        intensity: 0,
      );
      if (!ducked || probePaused) await _textToSpeech!.resume();
      if (!_isCurrent(token)) return;
      if (inputOwnsResponseCapture) _watchForServerBargeIn(token, armNow: true);
    } catch (error, stackTrace) {
      if (!_isCurrent(token)) return;
      DebugLogger.error(
        'barge-in-echo-resume-failed',
        scope: 'chat/voice_mode',
        error: error,
        stackTrace: stackTrace,
      );
      await _fail(error.toString(), token, _errorKindOf(error));
    }
  }

  static String _clip(String text) =>
      text.length <= 80 ? text : '${text.substring(0, 80)}...';

  int? _provisionalPausedMs() {
    final startedAt = _provisionalStartedAt;
    return startedAt == null
        ? null
        : DateTime.now().difference(startedAt).inMilliseconds;
  }

  static double _mean(List<double> values) =>
      values.reduce((a, b) => a + b) / values.length;

  void _cancelBargeProbe() {
    unawaited(_probeSub?.cancel());
    _probeSub = null;
    _probeTimer?.cancel();
    _probeTimer = null;
    _probeDb.clear();
  }

  /// Starts reading the microphone for the duck test. The window opens
  /// [bargeProbeSettle] from now (the ramp and the output path) and lasts
  /// [bargeProbeWindow].
  void _startBargeProbe(int token) {
    final input = _voiceInput;
    if (input == null) return;
    _cancelBargeProbe();
    final opens = DateTime.now().add(bargeProbeSettle);
    _probeSub = input.heldCaptureLevels.listen((level) {
      if (!DateTime.now().isBefore(opens)) _probeDb.add(level.dbfs);
    });
    _probeTimer = Timer(bargeProbeSettle + bargeProbeWindow, () {
      _probeTimer = null;
      unawaited(_decideBargeProbe(token));
    });
  }

  Future<void> _decideBargeProbe(int token) async {
    if (!_isCurrent(token) || !_bargeInProvisional || !_provisionalDucked) {
      return;
    }
    final frames = List<double>.of(_probeDb);
    unawaited(_probeSub?.cancel());
    _probeSub = null;
    _probeDb.clear();
    final pre = _probePreDb;
    final onsetAt = _probeOnsetAt ?? DateTime.now();
    final data = <String, Object?>{
      'preDb': ?pre?.round(),
      'windowMs': bargeProbeWindow.inMilliseconds,
      'settleMs': bargeProbeSettle.inMilliseconds,
      'frames': frames.length,
    };
    if (pre == null || frames.length < _bargeProbeMinFrames) {
      // No level to judge by: leave it to the take and the watchdog.
      VoiceEventLog.instance.add('barge-probe', <String, Object?>{
        ...data,
        'decision': 'no-levels',
      });
      return;
    }
    final post = _mean(frames);
    final drop = pre - post;
    data['postDb'] = post.round();
    data['dropDb'] = drop.round();
    final speech = drop < bargeProbeSpeechDropDb && post > _bargeProbeFloorDb;
    if (!speech) {
      VoiceEventLog.instance.add('barge-probe', <String, Object?>{
        ...data,
        'decision': 'echo-fell',
        'msFromOnset': DateTime.now().difference(onsetAt).inMilliseconds,
      });
      await _enqueue(() async {
        if (!_isCurrent(token) || !_bargeInProvisional) return;
        await _resumeAfterBargeInEcho(token, '', reason: 'echo-fell');
      });
      return;
    }
    // Probable speech: stop the audio now, keep the take. A transcript that
    // turns out to be echo resumes it from this spot.
    _probePaused = true;
    try {
      await _textToSpeech!.pause();
    } catch (_) {}
    if (!_isCurrent(token)) return;
    if (state.phase == ChatVoiceModePhase.speaking) {
      state = state.copyWith(phase: ChatVoiceModePhase.listening);
    }
    VoiceEventLog.instance.add('barge-probe', <String, Object?>{
      ...data,
      'decision': 'speech',
      'msFromOnset': DateTime.now().difference(onsetAt).inMilliseconds,
    });
  }

  void _cancelProvisionalWatchdog() {
    _provisionalWatchdog?.cancel();
    _provisionalWatchdog = null;
  }

  /// Safety net for a provisional barge-in: playback stays paused only while
  /// the user is audibly talking (up to [_provisionalBargeInHardLimit]).
  /// With no sign of speech after [delay] it resumes where it paused, however
  /// the take is going (a take that never ends was heard on the loudspeaker).
  void _armProvisionalWatchdog(int token, Duration delay) {
    _cancelProvisionalWatchdog();
    if (!_bargeInProvisional || !_isCurrent(token)) return;
    _provisionalWatchdog = Timer(delay, () {
      _provisionalWatchdog = null;
      if (!_bargeInProvisional || !_isCurrent(token)) return;
      final now = DateTime.now();
      final startedAt = _provisionalStartedAt ?? now;
      final lastSpeech = _lastProvisionalSpeechAt;
      // 2026-11-05: ducked speech keeps the meter up (the 17:23:17 take sat 5 s
      // in a check on its own echo), so only a take that is paused for probable
      // speech counts as talking; the take's own end (VAD silence, then the
      // transcript) decides it and only the hard limit cuts it. A take heard
      // as speech was dropped at 5 s with its words unsent before this.
      final talking = _probePaused
          ? now.difference(startedAt) < _provisionalBargeInHardLimit
          : !_provisionalDucked &&
                lastSpeech != null &&
                now.difference(lastSpeech) < provisionalBargeInTimeout &&
                now.difference(startedAt) < _provisionalBargeInHardLimit;
      if (talking) {
        _armProvisionalWatchdog(token, const Duration(milliseconds: 500));
        return;
      }
      VoiceEventLog.instance.add('barge-in-dropped', <String, Object?>{
        'reason': 'timeout',
        'words': 0,
      });
      unawaited(_resumeAfterBargeInEcho(token, '', reason: 'timeout'));
    });
  }

  Future<void> _interruptAssistantForBargeIn(int token) async {
    if (!_isCurrent(token)) return;

    DebugLogger.info('barge-in', scope: 'chat/voice_mode');
    _bargeInProvisional = false;
    _provisionalDucked = false;
    _probePaused = false;
    _cancelBargeProbe();
    _cancelProvisionalWatchdog();
    final tts = _textToSpeech!;
    await tts.stopStreamingTts();
    await tts.stop();
    _logSpeechStopped('barge-in-confirmed');
    VoiceEventLog.instance.add('barge-in-stop');
    if (!_isCurrent(token)) return;

    _directRunner.cancel();
    _directTurnActive = false;
    try {
      ref.read(stopGenerationProvider)();
    } catch (error, stackTrace) {
      DebugLogger.warning(
        'barge-in-stop-generation-failed',
        scope: 'chat/voice_mode',
        data: {'error': error, 'stackTrace': stackTrace},
      );
    }

    _awaitingAssistant = false;
    _assistantFinalized = true;
    _streamingTtsStarted = false;
    _activeAssistantMessageId = null;
    _lastFedAssistantText = '';
    _assistantSpeechChunks = const <String>[];
    _activeAssistantSpeechChunkIndex = -1;
    _assistantMessageIdsBeforeTurn = <String>{};
    _assistantSpeechStartedAt = null;
    state = state.copyWith(clearSpokenResponse: true);
  }

  void _handleAssistantContentChanged([List<ChatMessage>? messages]) {
    if (_disposed ||
        !_awaitingAssistant ||
        !_streamingTtsStarted ||
        _assistantFinalized) {
      return;
    }

    if (_directTurnActive) return;
    final raw = _visibleAssistantText(messages);
    if (raw == null) {
      return;
    }
    _feedAssistantText(_speechPrefix + raw);
  }

  void _feedAssistantText(String text) {
    if (_lastFedAssistantText.isEmpty && text.trim().isNotEmpty) {
      VoiceEventLog.instance.add('chat-first-token');
    }
    _syncAssistantSpeechChunks(text);
    state = state.copyWith(assistantPreview: text);
    if (state.phase == ChatVoiceModePhase.paused) {
      _pendingPausedAssistantText = text;
      return;
    }

    if (text == _lastFedAssistantText) {
      return;
    }

    _lastFedAssistantText = text;
    unawaited(_textToSpeech!.feedStreamingText(text));
  }

  void _handleChatMessagesChanged(List<ChatMessage> messages) {
    if (_disposed ||
        !_awaitingAssistant ||
        !_streamingTtsStarted ||
        _assistantFinalized) {
      return;
    }

    // A direct turn is spoken from the relay's stream; the chat the relay saves
    // to Open WebUI arriving in the message list must not drive the speech.
    if (_directTurnActive) return;
    final active = _activeAssistantMessage(messages);
    if (active == null) {
      return;
    }
    _activeAssistantMessageId ??= active.id;
    final error = active.error;
    if (error != null) {
      _assistantFinalized = true;
      unawaited(
        _fail(
          error.content ?? 'The assistant response failed.',
          _token,
          error.content == null
              ? ChatVoiceModeError.other
              : ChatVoiceModeError.message,
        ),
      );
      return;
    }
    _handleAssistantContentChanged(messages);
    // The transport marks `responseDone` on a terminal finish reason while
    // `isStreaming` can stay true until a later done event. Finalize on either
    // signal so the trailing TTS chunk is not held until transport close.
    if (!assistantMessageResponseCompleted(active)) {
      return;
    }

    unawaited(_finishAssistantResponse(_token));
  }

  Future<void> _finishAssistantResponse(
    int token, {
    String? directText,
  }) async {
    if (!_isCurrent(token) || _assistantFinalized) {
      return;
    }

    final finalText =
        directText ?? _speechPrefix + (_visibleAssistantText() ?? '');
    _syncAssistantSpeechChunks(finalText);
    state = state.copyWith(assistantPreview: finalText);

    if (state.phase == ChatVoiceModePhase.paused) {
      _assistantFinalized = true;
      _assistantFinalizationDeferred = true;
      _pendingPausedAssistantText = finalText;
      _pendingPausedAssistantFinalText = finalText;
      return;
    }

    _assistantFinalized = true;
    await _textToSpeech!.finishStreamingTts(finalText: finalText);
  }

  Future<void> _resumePausedAssistantTurn(int token) async {
    final shouldResumePlayback = _pausedDuringSpeech;
    _pausedDuringSpeech = false;
    _pausedDuringAssistantTurn = false;

    if (!_awaitingAssistant) {
      await _startListening(token, why: 'resume-no-assistant-turn');
      return;
    }

    try {
      await _audioSessionCoordinator?.beginResponseWaitCapture(
        callKitCallId: _activeCallId,
      );
    } catch (error, stackTrace) {
      if (!_isCurrent(token)) return;
      DebugLogger.error(
        'resume-background-audio-failed',
        scope: 'chat/voice_mode',
        error: error,
        stackTrace: stackTrace,
      );
      await _fail(error.toString(), token, _errorKindOf(error));
      return;
    }
    if (!_isCurrent(token)) return;

    state = state.copyWith(
      phase: shouldResumePlayback
          ? ChatVoiceModePhase.speaking
          : ChatVoiceModePhase.sending,
      clearErrorMessage: true,
    );

    await _flushPausedAssistantTts(token);
    if (!_isCurrent(token) || !state.isActive) {
      return;
    }

    if (shouldResumePlayback) {
      await _textToSpeech!.resume();
      if (_isCurrent(token) && state.isActive) {
        state = state.copyWith(phase: ChatVoiceModePhase.speaking);
      }
      return;
    }

    if (!_assistantFinalized) {
      _handleAssistantContentChanged();
      _handleChatMessagesChanged(ref.read(chatMessagesProvider));
    }
  }

  Future<void> _flushPausedAssistantTts(int token) async {
    final tts = _textToSpeech!;
    final deferredFinalText = _pendingPausedAssistantFinalText;
    final pendingText = _pendingPausedAssistantText;
    _pendingPausedAssistantText = null;
    _pendingPausedAssistantFinalText = null;

    if (_assistantFinalizationDeferred) {
      _assistantFinalizationDeferred = false;
      final finalText = deferredFinalText ?? pendingText ?? '';
      _lastFedAssistantText = finalText;
      await tts.finishStreamingTts(finalText: finalText);
      return;
    }

    if (!_isCurrent(token) ||
        pendingText == null ||
        pendingText == _lastFedAssistantText) {
      return;
    }

    _lastFedAssistantText = pendingText;
    await tts.feedStreamingText(pendingText);
  }

  Future<void> _resumeAfterAssistantSpeech(int token) async {
    if (!_isCurrent(token) || !_awaitingAssistant) {
      return;
    }

    _logSpeechStopped('assistant-turn-done');
    _awaitingAssistant = false;
    _streamingTtsStarted = false;
    await _stopWatchingForServerBargeIn();
    if (!_isCurrent(token)) return;
    _pendingFinalTranscripts.clear();
    _lastSubmittedTranscript = null;
    _activeAssistantMessageId = null;
    _lastFedAssistantText = '';
    _assistantSpeechChunks = const <String>[];
    _activeAssistantSpeechChunkIndex = -1;
    _assistantMessageIdsBeforeTurn = <String>{};

    if (!state.isActive ||
        state.isMuted ||
        state.phase == ChatVoiceModePhase.paused) {
      return;
    }

    await _startListening(token, why: 'after-assistant-speech');
  }

  Set<String> _currentAssistantMessageIds() {
    final List<ChatMessage> messages = ref.read(chatMessagesProvider);
    return {
      for (final message in messages)
        if (message.role == 'assistant') message.id,
    };
  }

  ChatMessage? _activeAssistantMessage([List<ChatMessage>? messages]) {
    final List<ChatMessage> all = messages ?? ref.read(chatMessagesProvider);
    final id = _activeAssistantMessageId;
    if (id != null) {
      for (final message in all.reversed) {
        if (message.id == id && message.role == 'assistant') {
          return message;
        }
      }
    }
    for (final message in all.reversed) {
      if (message.role == 'assistant' &&
          !_assistantMessageIdsBeforeTurn.contains(message.id)) {
        return message;
      }
    }
    return null;
  }

  String? _visibleAssistantText([List<ChatMessage>? messages]) {
    final message = _activeAssistantMessage(messages);
    if (message == null) return null;
    // Once the transport marks the response done it has flushed the buffered
    // text into the message, while `streamingContentProvider` may still hold
    // an earlier frame. The message is authoritative from that point.
    final settled =
        message.isStreaming &&
        assistantMessageResponseCompleted(message) &&
        message.content.isNotEmpty;
    if (!settled &&
        message.isStreaming &&
        _isLastStreamingAssistant(message, messages)) {
      final visible = ref.read(streamingContentProvider);
      if (visible != null && visible.isNotEmpty) {
        return visible;
      }
    }
    return message.content;
  }

  bool _isLastStreamingAssistant(
    ChatMessage message, [
    List<ChatMessage>? messages,
  ]) {
    final List<ChatMessage> all = messages ?? ref.read(chatMessagesProvider);
    if (all.isEmpty) return false;
    final last = all.last;
    return last.id == message.id &&
        last.role == 'assistant' &&
        last.isStreaming;
  }

  Future<void> _cancelListening() async {
    final input = _voiceInput;
    await _detachListeningSubscriptions();
    try {
      await input?.stopListening();
    } catch (_) {}
  }

  Future<void> _detachListeningSubscriptions() async {
    await _stopWatchingForServerBargeIn();
    await _transcriptSub?.cancel();
    _transcriptSub = null;
    await _intensitySub?.cancel();
    _intensitySub = null;
  }

  Future<void> _fail(
    String message,
    int token, [
    ChatVoiceModeError kind = ChatVoiceModeError.other,
  ]) async {
    if (!_isCurrent(token)) return;
    _noteEnd('fail:${kind.name}');
    // Invalidate transcript/TTS callbacks before resources are detached. The
    // lifecycle gate may delay subscription cancellation, and a recognizer is
    // allowed to deliver buffered data or onDone after onError.
    final failureToken = ++_token;
    await _disposeResources(endCallKit: true, ownershipToken: failureToken);
    if (!_isCurrent(failureToken)) return;
    state = state.copyWith(
      phase: ChatVoiceModePhase.error,
      errorMessage: message,
      errorKind: kind,
      clearActiveCallId: true,
      clearSpokenResponse: true,
      intensity: 0,
    );
  }

  void _setError(
    String message, [
    ChatVoiceModeError kind = ChatVoiceModeError.other,
  ]) {
    state = state.copyWith(
      phase: ChatVoiceModePhase.error,
      errorMessage: message,
      errorKind: kind,
      clearActiveCallId: true,
      clearSpokenResponse: true,
      intensity: 0,
    );
  }

  Future<void> _stopInternal({
    required bool endCallKit,
    String reason = 'stop',
  }) async {
    if (!state.isActive && state.phase != ChatVoiceModePhase.error) {
      return;
    }
    _noteEnd(reason);

    ++_token;
    final stopToken = _token;
    state = state.copyWith(phase: ChatVoiceModePhase.ending);
    await _disposeResources(
      endCallKit: endCallKit && !_stoppingFromCallKit,
      ownershipToken: stopToken,
    );
    if (!_isCurrent(stopToken)) return;
    _stoppingFromCallKit = false;
    state = state.copyWith(
      phase: ChatVoiceModePhase.ended,
      transcript: '',
      assistantPreview: '',
      clearSpokenResponse: true,
      intensity: 0,
      elapsed: Duration.zero,
      clearStartedAt: true,
      clearActiveCallId: true,
      isMuted: false,
      isSpeakerphoneEnabled: false,
    );
  }

  Future<void> _disposeResources({
    required bool endCallKit,
    required int ownershipToken,
  }) async {
    VoiceEventLog.instance.stop(
      reason: _endReason ?? 'unknown',
      fields: <String, Object?>{
        'phase': _endPhase ?? state.phase.name,
        'callKitOn': _endReason == null ? _activeCallId != null : _endCallKitOn,
      },
    );
    _endReason = null;
    _endPhase = null;
    _endCallKitOn = false;
    _endDirectCall();
    final input = _voiceInput;
    final tts = _textToSpeech;
    final callKit = _callKit;
    final callId = _activeCallId;
    final transcriptSub = _transcriptSub;
    final intensitySub = _intensitySub;
    final responseCaptureFailureSub = _responseCaptureFailureSub;
    final audioResponseCaptureFailureSub = _audioResponseCaptureFailureSub;
    final ttsSub = _ttsSub;
    final callKitSub = _callKitSub;
    final speakerphoneRouteSub = _speakerphoneRouteSub;
    final sessionEventSub = _sessionEventSub;
    final socketServiceSub = _socketServiceSub;
    final selectedModelSub = _selectedModelSub;
    final bargeInLevelSub = _bargeInLevelSub;
    final elapsedTimer = _elapsedTimer;
    final backgroundKeepAliveTimer = _backgroundKeepAliveTimer;
    final backgroundLeaseId = _backgroundLeaseId;
    final socketBackgroundLease = _socketBackgroundLease;
    final backgroundCoordinator = _backgroundCoordinator;
    final audioSessionCoordinator = _audioSessionCoordinator;
    final realtime = _realtime;
    final realtimeHost = _realtimeHost;
    final realtimeSub = _realtimeSub;
    final realtimeChatSub = _realtimeChatSub;

    // Detach this session's instance state before the first await. A stale
    // teardown can then finish its captured resources without a later finally
    // block nulling services or resetting flags installed by a replacement
    // start.
    _activeCallId = null;
    _elapsedTimer = null;
    _transcriptSub = null;
    _intensitySub = null;
    _responseCaptureFailureSub = null;
    _audioResponseCaptureFailureSub = null;
    _ttsSub = null;
    _callKitSub = null;
    _speakerphoneRouteSub = null;
    _sessionEventSub = null;
    _socketServiceSub = null;
    _selectedModelSub = null;
    _bargeInLevelSub = null;
    _bargeInDetector = null;
    _cancelProvisionalWatchdog();
    _backgroundKeepAliveTimer = null;
    _backgroundLeaseId = null;
    _socketBackgroundLease = null;
    _voiceInput = null;
    _textToSpeech = null;
    _callKit = null;
    _iosAudioSessionManagedExternally = false;
    _usesOpenWebUiTransport = false;
    _realtime = null;
    _standardFallback = null;
    _realtimeHost = null;
    _realtimeSub = null;
    _realtimeChatSub = null;
    realtimeChatSub?.close();
    // Its ending is this teardown's own; nothing listens for it any more.
    unawaited(realtimeSub?.cancel());
    // Ends the realtime voice and saves what it had not saved yet.
    final realtimeEnded = realtime?.end();
    elapsedTimer?.cancel();
    backgroundKeepAliveTimer?.cancel();
    selectedModelSub?.close();
    socketServiceSub?.close();
    socketBackgroundLease?.dispose();
    _resetRuntime();

    try {
      await _serviceLifecycleGate.runCleanupExclusive(() async {
        bool replacementOwnsInput() =>
            !_isCurrent(ownershipToken) && _voiceInput != null;
        bool replacementOwnsTts() =>
            !_isCurrent(ownershipToken) && _textToSpeech != null;
        bool replacementOwnsSharedAudio() =>
            !_isCurrent(ownershipToken) &&
            (_voiceInput != null ||
                _textToSpeech != null ||
                _backgroundLeaseId != null);

        // Before the audio session goes, so the call's audio stops first.
        await _runTeardownStep('realtime-end', () async {
          try {
            await realtimeEnded;
          } finally {
            // Answers still running go on in the chat, unfollowed.
            realtimeHost?.close();
          }
        });
        await _runTeardownStep('transcript-subscription-cancel', () async {
          await transcriptSub?.cancel();
        });
        await _runTeardownStep('intensity-subscription-cancel', () async {
          await intensitySub?.cancel();
        });
        await _runTeardownStep('barge-in-level-cancel', () async {
          await bargeInLevelSub?.cancel();
        });
        await _runTeardownStep('input-capture-failure-cancel', () async {
          await responseCaptureFailureSub?.cancel();
        });
        await _runTeardownStep('audio-capture-failure-cancel', () async {
          await audioResponseCaptureFailureSub?.cancel();
        });
        await _runTeardownStep('voice-input-stop', () async {
          if (!replacementOwnsInput()) {
            await input?.stopListening();
          }
        });
        await _runTeardownStep('response-wait-capture-stop', () async {
          if (!replacementOwnsSharedAudio()) {
            await audioSessionCoordinator?.endResponseWaitCapture();
          }
        });
        await _runTeardownStep('tts-subscription-cancel', () async {
          await ttsSub?.cancel();
        });
        await _runTeardownStep('streaming-tts-stop', () async {
          if (!replacementOwnsTts()) {
            await tts?.stopStreamingTts();
          }
        });
        await _runTeardownStep('tts-stop', () async {
          if (!replacementOwnsTts()) {
            await tts?.stop();
          }
        });
        // Its own step: a stop that throws must not leave the shared engine on
        // the call route, where read-aloud does not belong.
        await _runTeardownStep('tts-call-route-release', () async {
          if (!replacementOwnsTts()) {
            tts?.setVoiceCallActive(false);
          }
        });
        await _runTeardownStep('background-lease-stop', () async {
          if (backgroundLeaseId != null) {
            await backgroundCoordinator?.stopVoiceLease(backgroundLeaseId);
          }
        });
        await _runTeardownStep('background-audio-owner-release', () async {
          if (!replacementOwnsSharedAudio()) {
            await backgroundCoordinator?.setExternalAudioSessionOwner(false);
          }
        });
        await _runTeardownStep('audio-session-deactivate', () async {
          if (!replacementOwnsSharedAudio()) {
            await audioSessionCoordinator?.deactivate();
          }
        });
        await _runTeardownStep('callkit-subscription-cancel', () async {
          await callKitSub?.cancel();
        });
        await _runTeardownStep('audio-session-events-cancel', () async {
          await sessionEventSub?.cancel();
        });
        await _runTeardownStep(
          'speakerphone-route-subscription-cancel',
          () async {
            await speakerphoneRouteSub?.cancel();
          },
        );
        if (endCallKit && callId != null) {
          await _runTeardownStep('callkit-end', () async {
            await callKit?.endCall(callId);
          });
        }
      });
    } on TimeoutException catch (error, stackTrace) {
      DebugLogger.error(
        'teardown-lifecycle-timeout',
        scope: 'chat/voice_mode',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _runTeardownStep(
    String step,
    Future<void> Function() teardown,
  ) async {
    try {
      await teardown();
    } catch (error, stackTrace) {
      DebugLogger.error(
        'teardown-step-failed',
        scope: 'chat/voice_mode',
        error: error,
        stackTrace: stackTrace,
        data: {'step': step},
      );
    }
  }

  void _resetRuntime() {
    _selectedModelSub?.close();
    _selectedModelSub = null;
    _socketServiceSub?.close();
    _socketServiceSub = null;
    _socketBackgroundLease?.dispose();
    _socketBackgroundLease = null;
    _usesOpenWebUiTransport = false;
    _socketReopenFallback = null;
    _socketReopenFailures = 0;
    _socketReopening = false;
    _emptyTranscriptRestarts = 0;
    _currentTranscript = '';
    _lastFedAssistantText = '';
    _activeCallId = null;
    _activeAssistantMessageId = null;
    _assistantMessageIdsBeforeTurn = <String>{};
    _awaitingAssistant = false;
    _assistantFinalized = false;
    _streamingTtsStarted = false;
    _iosAudioSessionManagedExternally = false;
    _markedCallConnected = false;
    _pausedDuringSpeech = false;
    _pausedDuringAssistantTurn = false;
    _appOwnsSession = false;
    _pausedByInterruption = false;
    _pausedByRouteLoss = false;
    _mutedDuringSpeech = false;
    _assistantFinalizationDeferred = false;
    _pendingPausedAssistantText = null;
    _pendingPausedAssistantFinalText = null;
    _pendingFinalTranscripts.clear();
    _lastSubmittedTranscript = null;
    _sendingTranscript = false;
    _assistantSpeechChunks = const <String>[];
    _activeAssistantSpeechChunkIndex = -1;
    _assistantSpeechStartedAt = null;
    _bargeInProvisional = false;
    _provisionalDucked = false;
    _probePaused = false;
    _cancelBargeProbe();
    _recentHeldDb.clear();
    _cancelProvisionalWatchdog();
    _provisionalStartedAt = null;
    _lastProvisionalSpeechAt = null;
    _previewBeforeBargeIn = '';
  }

  void _replaceSocketBackgroundLease(SocketService? socket) {
    final replacement = !_disposed && _usesOpenWebUiTransport && state.isActive
        ? socket?.acquireBackgroundActivityLease()
        : null;
    final previous = _socketBackgroundLease;
    _socketBackgroundLease = replacement;
    previous?.dispose();
  }

  void _updateVoiceTransport(Model? model) {
    if (_usesOpenWebUiTransport ||
        model == null ||
        !voiceCallUsesOpenWebUiTransport(ref, model)) {
      return;
    }
    _usesOpenWebUiTransport = true;
    _replaceSocketBackgroundLease(ref.read(socketServiceProvider));
  }

  void _syncAssistantSpeechChunks(String text) {
    _assistantSpeechChunks = _textToSpeech!.splitTextForSpeech(text);

    final index = _activeAssistantSpeechChunkIndex;
    if (index >= 0 && index < _assistantSpeechChunks.length) {
      final chunk = _assistantSpeechChunks[index];
      if (chunk != state.spokenResponse) {
        state = state.copyWith(
          spokenResponse: chunk,
          clearSpokenProgress: true,
        );
      }
    }
  }

  void _handleTtsChunkStarted(int chunkIndex) {
    if (!_awaitingAssistant || !_streamingTtsStarted) {
      return;
    }

    _activeAssistantSpeechChunkIndex = chunkIndex;
    if (chunkIndex < 0) {
      state = state.copyWith(clearSpokenResponse: true);
      return;
    }

    if (chunkIndex >= _assistantSpeechChunks.length) {
      _syncAssistantSpeechChunks(state.assistantPreview);
    }

    if (chunkIndex >= _assistantSpeechChunks.length) {
      state = state.copyWith(clearSpokenResponse: true);
      return;
    }

    state = state.copyWith(
      spokenResponse: _assistantSpeechChunks[chunkIndex],
      clearSpokenProgress: true,
    );
  }

  void _handleTtsWordProgress(int start, int end) {
    if (!_awaitingAssistant ||
        !_streamingTtsStarted ||
        state.spokenResponse.trim().isEmpty) {
      return;
    }

    state = state.copyWith(spokenWordStart: start, spokenWordEnd: end);
  }

  void _startElapsedTimer(int token) {
    _elapsedTimer?.cancel();
    _elapsedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!_isCurrent(token)) {
        _elapsedTimer?.cancel();
        return;
      }
      final startedAt = state.startedAt;
      if (startedAt == null) return;
      state = state.copyWith(elapsed: DateTime.now().difference(startedAt));
    });
  }

  Future<void> _enqueue(Future<void> Function() action) {
    if (_disposed) return Future<void>.value();
    final next = _serial.then((_) async {
      if (_disposed) return;
      await action();
    });
    _serial = next.catchError((_) {});
    return next;
  }

  void _cancelPendingStartReadiness() {
    final cancellation = _pendingStartReadinessCancellation;
    if (cancellation != null && !cancellation.isCompleted) {
      cancellation.complete();
    }
  }

  bool _isCurrent(int token) => !_disposed && token == _token;

  Future<void> _cancelSubscriptionAfterDispose(
    StreamSubscription<dynamic>? subscription,
  ) async {
    try {
      await subscription?.cancel();
    } catch (_) {}
  }

  Future<void> _stopVoiceInputAfterDispose(VoiceModeInput? input) async {
    try {
      await input?.stopListening();
    } catch (_) {}
  }

  Future<void> _stopTtsAfterDispose(VoiceModeSpeech? tts) async {
    try {
      await tts?.stopStreamingTts();
    } catch (_) {}
    try {
      await tts?.stop();
    } catch (_) {}
  }

  Future<void> _stopBackgroundVoiceLeaseAfterDispose(
    VoiceBackgroundPort? coordinator,
  ) async {
    try {
      await _stopBackgroundVoiceLease(coordinator);
    } catch (_) {}
  }

  Future<void> _deactivateAudioSessionAfterDispose(
    VoiceAudioSessionPort? coordinator,
  ) async {
    try {
      await coordinator?.deactivate();
    } catch (_) {}
  }

  Future<void> _endResponseWaitCaptureAfterDispose(
    VoiceAudioSessionPort? coordinator,
  ) async {
    try {
      await coordinator?.endResponseWaitCapture();
    } catch (_) {}
  }

  Future<void> _endCallAfterDispose(
    VoiceCallKitPort? callKit,
    String callId,
  ) async {
    try {
      await callKit?.endCall(callId);
    } catch (_) {}
  }
}

const int _voiceModeViewVersion = 2;

/// The bottom view voice mode last used: true (also a fresh install) is the
/// text-only strip, false is the expanded panel (speaker, pause, text).
///
/// Before build 191 the same key held "pill" or "full panel", and most
/// installs had never set it (full panel). A value saved without the version
/// is from that meaning, so it is ignored and the call opens on the text
/// strip; the first collapse or expand after that saves under the new
/// meaning.
bool storedVoiceModeCollapsed() {
  if (!PreferencesStore.isReady) return true;
  if (PreferencesStore.getInt(PreferenceKeys.voiceModeViewVersion) !=
      _voiceModeViewVersion) {
    return true;
  }
  return PreferencesStore.getBool(PreferenceKeys.voiceModeCollapsed) ?? true;
}
