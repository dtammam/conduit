import 'dart:async';
import 'dart:io';

import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/utils/adaptive_glass.dart';
import 'package:conduit/shared/widgets/conduit_loading.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit/shared/widgets/themed_sheets.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import 'assistant_action_log.dart';
import 'assistant_activity.dart';
import 'assistant_avatar_accent.dart';
import 'assistant_avatar_media.dart';
import 'assistant_avatar_sheet.dart';
import 'assistant_pending_approval.dart';
import 'persona_appearance_service.dart';

const String _logScope = 'chat/avatar';

/// A centered round avatar that reacts to what the assistant is doing, with
/// a pill naming the assistant under it. It takes the app bar's title slot
/// when the "Assistant avatar" setting is on: the circle starts on the
/// toolbar's top line and the pill hangs below the toolbar, so the pill
/// doubles as the model selector.
///
/// It rebuilds only on [isChatStreamingProvider] and a selected
/// [AssistantActivitySnapshot] of the latest assistant message, never on
/// every streamed chunk.
class AssistantAvatarStrip extends ConsumerStatefulWidget {
  const AssistantAvatarStrip({
    super.key,
    required this.modelName,
    this.onNamePressed,
    this.onActivityPressed,
    this.isLoading = false,
    this.mediaStore,
    this.doneHold = kAssistantActivityDoneHold,
  });

  /// Total height of the strip: the circle, a gap and the two-line pill. The
  /// pill is shorter while idle; the slack stays reserved so the transcript
  /// does not shift when the state line appears.
  static const double height = avatarSize + Spacing.sm + _pillMaxHeight;

  /// Diameter of the avatar circle.
  static const double avatarSize = 72;

  static const double _pillMaxHeight = 48;

  /// Height the strip hangs below a toolbar of [toolbarHeight]; the chat
  /// page keeps the message list below it.
  static double insetBelowToolbar(double toolbarHeight) =>
      (height - toolbarHeight).clamp(0.0, double.infinity);

  /// Display name of the active model; its first letter is the fallback.
  final String? modelName;

  /// Opens the model selector from the pill while the assistant is idle;
  /// null leaves the pill inert.
  final VoidCallback? onNamePressed;

  /// Invoked from the pill while the assistant is busy, when the pill shows
  /// the state word; the chat page jumps to the live reply.
  final VoidCallback? onActivityPressed;

  /// Shows a placeholder in the pill while models or the chat are loading.
  final bool isLoading;

  /// Overrides the on-disk store (tests).
  final AssistantAvatarMediaStore? mediaStore;

  final Duration doneHold;

  @override
  ConsumerState<AssistantAvatarStrip> createState() =>
      _AssistantAvatarStripState();
}

class _AssistantAvatarStripState extends ConsumerState<AssistantAvatarStrip>
    with WidgetsBindingObserver {
  late final AssistantAvatarMediaStore _store =
      widget.mediaStore ?? AssistantAvatarMediaStore();
  AssistantAvatarMediaSet _media = AssistantAvatarMediaSet.empty;
  final Map<String, VideoPlayerController> _controllers = {};
  final Set<String> _failedMedia = {};
  bool _holdingDone = false;

  /// What the circle shows right now, for the sheet's header.
  Widget? _circleContent;
  Timer? _doneTimer;
  String? _playingId;
  bool _disposed = false;

  /// Bumped by every [_refreshAccent], so a slow read never records a color
  /// for media that has since changed.
  int _accentGeneration = 0;

  /// Wraps the circle's media so a playing video frame can be read back for
  /// the bubble color.
  final GlobalKey _mediaBoundaryKey = GlobalKey();

  /// The video clip whose color is still to be sampled, with its cache key.
  ({String mediaId, String cacheKey})? _pendingVideoAccent;
  Timer? _videoAccentTimer;

  /// Asks for the active persona while this chat is on screen.
  Timer? _personaTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_reloadMedia());
    // A chat opening is one of the moments the persona is asked for; then
    // once a minute while the strip is mounted and the app is in front.
    unawaited(ref.read(personaAppearanceProvider.notifier).refresh());
    _personaTimer = Timer.periodic(kPersonaPollInterval, (_) {
      final lifecycle = WidgetsBinding.instance.lifecycleState;
      if (lifecycle != null && lifecycle != AppLifecycleState.resumed) return;
      unawaited(ref.read(personaAppearanceProvider.notifier).refresh());
    });
    // A chat that is already open counts as loaded.
    WidgetsBinding.instance.addPostFrameCallback((_) => _scanLoadedChat());
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _doneTimer?.cancel();
    _videoAccentTimer?.cancel();
    _personaTimer?.cancel();
    for (final controller in _controllers.values) {
      unawaited(controller.dispose());
    }
    _controllers.clear();
    super.dispose();
  }

  Future<void> _reloadMedia() async {
    final media = await _store.load(
      personaId: ref.read(activePersonaAppearanceProvider)?.id,
    );
    if (_disposed) return;
    // A replaced file keeps its path, so drop every file controller and
    // any asset controller no longer in use; they are recreated lazily.
    final keep = {
      for (final state in AssistantActivity.values)
        if (media.resolve(state) case final resolved? when resolved.isBundled)
          resolved.id,
    };
    final stale = _controllers.keys.where((id) => !keep.contains(id)).toList();
    for (final id in stale) {
      unawaited(_controllers.remove(id)?.dispose());
    }
    _failedMedia.clear();
    _playingId = null;
    setState(() => _media = media);
    unawaited(_refreshAccent());
  }

  /// Derives the bubble color from the avatar's resting media once per
  /// clip, only while "Message bubbles" is on. Images are decoded at
  /// thumbnail size; a video is sampled from the circle once it plays.
  Future<void> _refreshAccent() async {
    final generation = ++_accentGeneration;
    _pendingVideoAccent = null;
    _videoAccentTimer?.cancel();
    if (!ref.read(appSettingsProvider).messageBubbles) return;
    final notifier = ref.read(assistantAvatarAutoAccentProvider.notifier);
    final source = assistantAvatarAccentSource(_media);
    if (source == null) {
      await notifier.clear();
      return;
    }
    final cacheKey = await assistantAvatarMediaCacheKey(source);
    if (_disposed || generation != _accentGeneration) return;
    if (notifier.cachedKey == cacheKey) return;
    if (source.kind == AssistantAvatarMediaKind.video) {
      _pendingVideoAccent = (mediaId: source.id, cacheKey: cacheKey);
      _scheduleVideoAccentSample();
      return;
    }
    try {
      final bytes = await File(source.path).readAsBytes();
      final color = await dominantVividColorOfEncoded(bytes);
      if (_disposed || generation != _accentGeneration) return;
      await notifier.record(cacheKey, color);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'accent-image-failed',
        scope: _logScope,
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// Samples the pending video once its clip has been playing on screen for
  /// a moment, so a real frame has been composited.
  void _scheduleVideoAccentSample() {
    final pending = _pendingVideoAccent;
    if (pending == null || _playingId != pending.mediaId) return;
    final controller = _controllers[pending.mediaId];
    if (controller == null || !controller.value.isInitialized) return;
    if (_videoAccentTimer?.isActive ?? false) return;
    _videoAccentTimer = Timer(
      const Duration(milliseconds: 800),
      () => unawaited(_sampleVideoAccent(pending)),
    );
  }

  Future<void> _sampleVideoAccent(
    ({String mediaId, String cacheKey}) pending,
  ) async {
    if (_disposed || _pendingVideoAccent != pending) return;
    if (_playingId != pending.mediaId) return;
    final boundary = _mediaBoundaryKey.currentContext?.findRenderObject();
    if (boundary is! RenderRepaintBoundary || !boundary.hasSize) return;
    _pendingVideoAccent = null;
    Color? color;
    try {
      final image = await boundary.toImage();
      try {
        color = await dominantVividColorOfImage(image);
      } finally {
        image.dispose();
      }
    } catch (error, stackTrace) {
      DebugLogger.error(
        'accent-video-sample-failed',
        scope: _logScope,
        error: error,
        stackTrace: stackTrace,
      );
    }
    if (_disposed) return;
    // A blank read-back (the platform texture not captured) has no vivid
    // pixels and yields null; it is kept for this session only, so the next
    // launch tries again, and the bubbles stay gray meanwhile.
    DebugLogger.log(
      'accent-video-sample',
      scope: _logScope,
      data: {'found': color != null},
    );
    await ref
        .read(assistantAvatarAutoAccentProvider.notifier)
        .record(pending.cacheKey, color, persist: color != null);
  }

  void _onStreamingChanged(bool? previous, bool next) {
    if (next) {
      _doneTimer?.cancel();
      _doneTimer = null;
      if (_holdingDone) setState(() => _holdingDone = false);
      return;
    }
    if (previous != true) return;
    _scanLoadedChat(finishedAt: DateTime.now());
    final failed = latestAssistantMessage(ref.read(chatMessagesProvider))
        ?.error;
    if (failed != null) return;
    _doneTimer?.cancel();
    setState(() => _holdingDone = true);
    _doneTimer = Timer(widget.doneHold, () {
      if (_disposed) return;
      setState(() => _holdingDone = false);
    });
  }

  VideoPlayerController? _controllerFor(AssistantAvatarMedia media) {
    if (_failedMedia.contains(media.id)) return null;
    final existing = _controllers[media.id];
    if (existing != null) return existing;
    final VideoPlayerController controller;
    try {
      controller = media.isBundled
          ? VideoPlayerController.asset(media.path)
          : VideoPlayerController.file(File(media.path));
    } catch (error, stackTrace) {
      DebugLogger.error(
        'video-create-failed',
        scope: _logScope,
        error: error,
        stackTrace: stackTrace,
      );
      _failedMedia.add(media.id);
      return null;
    }
    _controllers[media.id] = controller;
    unawaited(_initialize(media.id, controller));
    return controller;
  }

  Future<void> _initialize(String id, VideoPlayerController controller) async {
    try {
      await controller.initialize();
      await controller.setLooping(true);
      await controller.setVolume(0);
      controller.addListener(() => _keepLooping(id, controller));
      if (_disposed || _controllers[id] != controller) return;
      if (_playingId == id) {
        await controller.play();
        _scheduleVideoAccentSample();
      }
      if (mounted) setState(() {});
    } catch (error, stackTrace) {
      DebugLogger.error(
        'video-init-failed',
        scope: _logScope,
        error: error,
        stackTrace: stackTrace,
      );
      if (_disposed) return;
      _failedMedia.add(id);
      if (_controllers[id] == controller) {
        _controllers.remove(id);
        unawaited(controller.dispose());
      }
      if (mounted) setState(() {});
    }
  }

  /// iOS pauses players when the app leaves the screen and does not always
  /// loop a clip that reached its end; the clip on screen is restarted.
  void _keepLooping(String id, VideoPlayerController controller) {
    if (_disposed || id != _playingId) return;
    final v = controller.value;
    if (!v.isInitialized || v.isPlaying || v.isBuffering) return;
    final atEnd =
        v.duration > Duration.zero &&
        v.position >= v.duration - const Duration(milliseconds: 150);
    if (!atEnd) return;
    unawaited(controller.seekTo(Duration.zero).then((_) => controller.play()));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || _disposed) return;
    final controller = _controllers[_playingId];
    if (controller == null || !controller.value.isInitialized) return;
    if (!controller.value.isPlaying) unawaited(controller.play());
  }

  /// Plays the current state's clip and pauses every other one.
  void _syncPlayback(String? currentId) {
    if (_playingId == currentId) return;
    _playingId = currentId;
    for (final entry in _controllers.entries) {
      final controller = entry.value;
      if (!controller.value.isInitialized) continue;
      try {
        if (entry.key == currentId) {
          unawaited(controller.play());
          _scheduleVideoAccentSample();
        } else {
          unawaited(controller.pause());
        }
      } catch (error, stackTrace) {
        DebugLogger.error(
          'video-playback-failed',
          scope: _logScope,
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
  }

  /// Records the tool calls of the open chat's settled replies that the log
  /// has not read yet. The log remembers what it has read, so calling this
  /// again costs a length comparison per reply.
  void _scanLoadedChat({DateTime? finishedAt}) {
    if (_disposed || !mounted) return;
    final chatId = ref.read(activeConversationProvider)?.id;
    if (chatId == null || isTemporaryChat(chatId)) return;
    if (ref.read(isChatStreamingProvider)) return;
    unawaited(
      ref
          .read(assistantActionLogProvider.notifier)
          .scanMessages(
            chatId,
            ref.read(chatMessagesProvider),
            finishedAt: finishedAt,
          ),
    );
  }

  bool _sheetOpen = false;

  Future<void> _openSheet({
    AssistantSheetTab? tab,
    Set<String>? messageIds,
  }) async {
    if (_sheetOpen) return;
    _sheetOpen = true;
    try {
      await ThemedSheets.showSurface<void>(
        context: context,
        builder: (_) => AssistantAvatarSheet(
          store: _store,
          onChanged: _reloadMedia,
          modelName: widget.modelName,
          avatar: _circleContent,
          initialTab: tab,
          messageIds: messageIds,
        ),
      );
    } finally {
      _sheetOpen = false;
    }
  }

  void _onSheetRequest(
    AssistantSheetRequest? previous,
    AssistantSheetRequest? next,
  ) {
    if (next == null) return;
    ref.read(assistantSheetRequestProvider.notifier).consume();
    unawaited(_openSheet(tab: next.tab, messageIds: next.messageIds));
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<bool>(isChatStreamingProvider, _onStreamingChanged);
    ref.listen<PersonaAppearance?>(activePersonaAppearanceProvider, (
      previous,
      next,
    ) {
      // New persona, new clips, or the setting turning on or off.
      final same = next == null ? previous == null : next.sameClipsAs(previous);
      if (!same) unawaited(_reloadMedia());
    });
    ref.listen<bool>(
      appSettingsProvider.select((settings) => settings.messageBubbles),
      (previous, next) {
        if (next && previous != true) unawaited(_refreshAccent());
      },
    );
    ref.listen<AssistantSheetRequest?>(
      assistantSheetRequestProvider,
      _onSheetRequest,
    );
    ref.listen<int>(
      chatMessagesProvider.select((messages) => messages.length),
      (previous, next) => _scanLoadedChat(),
    );
    ref.listen<String?>(
      activeConversationProvider.select((conversation) => conversation?.id),
      (previous, next) => _scanLoadedChat(),
    );
    ref.listen<({String? callId, String? messageId})>(
      chatMessagesProvider.select((messages) {
        final snapshot = assistantActivitySnapshot(messages);
        return (callId: snapshot.callId, messageId: snapshot.messageId);
      }),
      (previous, next) {
        final callId = next.callId;
        final messageId = next.messageId;
        if (callId == null || callId.isEmpty || messageId == null) return;
        ref
            .read(assistantActionLogProvider.notifier)
            .noteRunning(messageId, callId);
      },
    );
    ref.watch(isChatStreamingProvider);
    final snapshot = ref.watch(
      chatMessagesProvider.select(assistantActivitySnapshot),
    );
    final activity = resolveDisplayedAssistantActivity(
      live: snapshot.live,
      holdingDone: _holdingDone,
    );
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final word = assistantActivityLabel(l10n, activity);
    // The line under the name: the running tool step when the stream names
    // one ("Search web", "Searching the web"), else the state word.
    final stateLine =
        activity == AssistantActivity.working ||
            activity == AssistantActivity.making
        ? (snapshot.detail ?? word)
        : word;
    final trimmedName = widget.modelName?.trim() ?? '';
    final displayName = trimmedName.isEmpty ? null : trimmedName;

    final media = _media.resolve(activity);
    Widget? content;
    String? playingId;
    if (media != null && !_failedMedia.contains(media.id)) {
      if (media.kind == AssistantAvatarMediaKind.video) {
        final controller = _controllerFor(media);
        if (controller != null) {
          playingId = media.id;
          if (controller.value.isInitialized) {
            final size = controller.value.size;
            content = FittedBox(
              fit: BoxFit.cover,
              clipBehavior: Clip.hardEdge,
              child: SizedBox(
                width: size.width <= 0
                    ? AssistantAvatarStrip.avatarSize
                    : size.width,
                height: size.height <= 0
                    ? AssistantAvatarStrip.avatarSize
                    : size.height,
                child: VideoPlayer(controller),
              ),
            );
          }
        }
      } else {
        content = Image.file(
          File(media.path),
          key: ValueKey(media.id),
          fit: BoxFit.cover,
          width: AssistantAvatarStrip.avatarSize,
          height: AssistantAvatarStrip.avatarSize,
          gaplessPlayback: true,
          errorBuilder: (context, error, stackTrace) {
            DebugLogger.error(
              'image-decode-failed',
              scope: _logScope,
              error: error,
              stackTrace: stackTrace,
            );
            return _AvatarInitial(name: widget.modelName);
          },
        );
      }
    }
    _circleContent = content;
    // Play and pause after the frame, and only when the clip changes.
    if (playingId != _playingId) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_disposed) _syncPlayback(playingId);
      });
    }

    final unseenFailures = ref.watch(
      assistantActionLogProvider.select((log) => log.unseenFailures),
    );
    final approvalPending = ref.watch(
      assistantApprovalProvider.select((approval) => approval != null),
    );
    final busy = activity != AssistantActivity.idle;
    final pillTap = busy ? widget.onActivityPressed : widget.onNamePressed;
    // Idle and tappable, the name is the model picker. No chevron marks it,
    // so the hint says it for VoiceOver.
    final picksModel = !busy && pillTap != null;

    return SizedBox(
      key: const ValueKey('assistant-avatar-strip'),
      height: AssistantAvatarStrip.height,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Spacing.inputPadding),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.start,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                Semantics(
                  button: true,
                  label: l10n.assistantAvatarEditLabel(
                    displayName ?? l10n.assistantAvatar,
                    word,
                  ),
                  excludeSemantics: true,
                  child: GestureDetector(
                    key: const ValueKey('assistant-avatar-circle'),
                    behavior: HitTestBehavior.opaque,
                    onTap: () => unawaited(_openSheet()),
                    child: Container(
                      width: AssistantAvatarStrip.avatarSize,
                      height: AssistantAvatarStrip.avatarSize,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: theme.surfaceContainer,
                        border: Border.all(color: theme.cardBorder),
                      ),
                      child: ClipOval(
                        child: RepaintBoundary(
                          key: _mediaBoundaryKey,
                          child:
                              content ?? _AvatarInitial(name: widget.modelName),
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: -2,
                  right: -2,
                  child: _AvatarBadge(
                    failures: unseenFailures,
                    approval: approvalPending,
                  ),
                ),
              ],
            ),
            const SizedBox(height: Spacing.sm),
            // The pill names the assistant and, while it is busy, says what it
            // is doing, naming the tool step when there is one. Idle it is
            // the model selector; busy it jumps to the live reply, where the
            // tool and thinking rows expand.
            Semantics(
              button: pillTap != null,
              // The circle already announces "<name>, <state>"; the pill
              // reads as the state line while busy and the model picker idle.
              label: busy ? stateLine : (displayName ?? l10n.chooseModel),
              hint: picksModel ? l10n.modelPickerHint : null,
              excludeSemantics: true,
              child: GestureDetector(
                key: const ValueKey('assistant-avatar-pill'),
                behavior: HitTestBehavior.opaque,
                onTap: pillTap,
                child: MediaQuery.withClampedTextScaling(
                  maxScaleFactor: 1.2,
                  child: _AssistantAvatarPillSurface(
                    child: widget.isLoading
                        ? Center(
                            widthFactor: 1,
                            child: ConduitLoading.skeleton(
                              width: 64,
                              height: 12,
                              borderRadius: BorderRadius.circular(
                                AppBorderRadius.sm,
                              ),
                            ),
                          )
                        : Column(
                            mainAxisSize: MainAxisSize.min,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                displayName ?? l10n.chooseModel,
                                key: const ValueKey(
                                  'assistant-avatar-pill-name',
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.center,
                                style: AppTypography.labelStyle.copyWith(
                                  color: theme.textPrimary,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              if (busy)
                                Text(
                                  stateLine,
                                  key: const ValueKey(
                                    'assistant-avatar-pill-state',
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppTypography.captionStyle.copyWith(
                                    color: theme.textSecondary,
                                  ),
                                ),
                            ],
                          ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The name pill's surface: the toolbar's Liquid Glass on iOS 26 and later,
/// as behind the app bar's buttons and the context ring, and the opaque
/// toolbar pill elsewhere. The pill sizes to its text, so the glass is a
/// backdrop stretched under it rather than a fixed-size toolbar surface.
class _AssistantAvatarPillSurface extends StatelessWidget {
  const _AssistantAvatarPillSurface({required this.child});

  final Widget child;

  static const BorderRadius _radius = BorderRadius.all(
    Radius.circular(AppBorderRadius.round),
  );

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final fallback = conduitUsesOpaqueGlassFallback();
    final body = Container(
      key: const ValueKey('assistant-avatar-pill-surface'),
      constraints: const BoxConstraints(
        minHeight: Spacing.xl + Spacing.xs,
        maxWidth: 240,
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.md,
        vertical: Spacing.xxs + 1,
      ),
      // Without native glass, the opaque fill and hairline color of the
      // toolbar's fallback pills and circles. Over glass the border stays,
      // transparent, so the pill is the same size either way.
      decoration: BoxDecoration(
        color: fallback ? theme.surfaceContainerHighest : null,
        borderRadius: _radius,
        border: Border.all(
          color: fallback ? theme.cardBorder : const Color(0x00000000),
        ),
      ),
      child: child,
    );
    if (fallback) return body;
    return Stack(
      children: [
        // The native glass would draw over a sheet that covers the pill, so
        // it steps aside then, like the toolbar's other glass surfaces.
        // The native corner radius is a plain number, so it is half the
        // pill's measured height: a capsule at one line or two.
        Positioned.fill(
          child: ThemedSheets.hideNativeChromeWhileCovered(
            replacement: const SizedBox.expand(),
            child: LayoutBuilder(
              builder: (context, constraints) => AdaptiveGlassBackdrop(
                key: const ValueKey('assistant-avatar-pill-glass'),
                borderRadius: BorderRadius.circular(constraints.maxHeight / 2),
                autoHideOnModal: false,
              ),
            ),
          ),
        ),
        body,
      ],
    );
  }
}

class _AvatarInitial extends StatelessWidget {
  const _AvatarInitial({required this.name});

  final String? name;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final trimmed = name?.trim() ?? '';
    final initial = trimmed.isEmpty
        ? ''
        : String.fromCharCodes(trimmed.runes.take(1)).toUpperCase();
    return Center(
      child: Text(
        initial,
        style: AppTypography.titleLargeStyle.copyWith(
          color: theme.textPrimary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// The mark on the avatar circle: a red count of tool calls that failed since
/// the user last looked at the activity list, else an amber mark while a
/// prompt waits for an answer. Nothing otherwise.
class _AvatarBadge extends StatelessWidget {
  const _AvatarBadge({required this.failures, required this.approval});

  final int failures;
  final bool approval;

  @override
  Widget build(BuildContext context) {
    if (failures <= 0 && !approval) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final showCount = failures > 0;
    final color = showCount ? theme.error : theme.warning;
    return Semantics(
      label: showCount
          ? l10n.assistantFailedCount(failures)
          : l10n.assistantApprovalWaiting,
      excludeSemantics: true,
      child: Container(
        key: ValueKey(
          showCount
              ? 'assistant-avatar-badge-failed'
              : 'assistant-avatar-badge-approval',
        ),
        constraints: BoxConstraints(
          minWidth: showCount ? 18 : 14,
          minHeight: showCount ? 18 : 14,
        ),
        padding: showCount
            ? const EdgeInsets.symmetric(horizontal: 5)
            : EdgeInsets.zero,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(AppBorderRadius.round),
          border: Border.all(color: theme.surfaceBackground, width: 2),
        ),
        child: showCount
            ? Text(
                failures > 99 ? '99+' : '$failures',
                style: AppTypography.micro.copyWith(
                  color: const Color(0xFFFFFFFF),
                  fontWeight: FontWeight.w700,
                ),
              )
            : null,
      ),
    );
  }
}
