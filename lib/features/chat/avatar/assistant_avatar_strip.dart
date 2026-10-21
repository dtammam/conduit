import 'dart:async';
import 'dart:io';

import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/utils/adaptive_glass.dart';
import 'package:conduit/shared/widgets/conduit_loading.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit/shared/widgets/themed_sheets.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../widgets/message_bubble_colors.dart';
import 'assistant_activity.dart';
import 'assistant_avatar_accent.dart';
import 'assistant_avatar_media.dart';

const String _logScope = 'chat/avatar';

/// The word shown in the pill for [activity].
String _activityLabel(AppLocalizations l10n, AssistantActivity activity) =>
    switch (activity) {
      AssistantActivity.idle => l10n.assistantActivityIdle,
      AssistantActivity.working => l10n.assistantActivityWorking,
      AssistantActivity.making => l10n.assistantActivityMaking,
      AssistantActivity.done => l10n.assistantActivityDone,
    };

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

class _AssistantAvatarStripState extends ConsumerState<AssistantAvatarStrip> {
  late final AssistantAvatarMediaStore _store =
      widget.mediaStore ?? AssistantAvatarMediaStore();
  AssistantAvatarMediaSet _media = AssistantAvatarMediaSet.empty;
  final Map<String, VideoPlayerController> _controllers = {};
  final Set<String> _failedMedia = {};
  bool _holdingDone = false;
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

  @override
  void initState() {
    super.initState();
    unawaited(_reloadMedia());
  }

  @override
  void dispose() {
    _disposed = true;
    _doneTimer?.cancel();
    _videoAccentTimer?.cancel();
    for (final controller in _controllers.values) {
      unawaited(controller.dispose());
    }
    _controllers.clear();
    super.dispose();
  }

  Future<void> _reloadMedia() async {
    final media = await _store.load();
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

  Future<void> _openSheet() async {
    await ThemedSheets.showSurface<void>(
      context: context,
      builder: (_) =>
          _AssistantAvatarSheet(store: _store, onChanged: _reloadMedia),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<bool>(isChatStreamingProvider, _onStreamingChanged);
    ref.listen<bool>(
      appSettingsProvider.select((settings) => settings.messageBubbles),
      (previous, next) {
        if (next && previous != true) unawaited(_refreshAccent());
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
    final word = _activityLabel(l10n, activity);
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
    // Play and pause after the frame, and only when the clip changes.
    if (playingId != _playingId) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_disposed) _syncPlayback(playingId);
      });
    }

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
                onTap: _openSheet,
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
                      child: content ?? _AvatarInitial(name: widget.modelName),
                    ),
                  ),
                ),
              ),
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

/// The themed sheet that assigns a clip to each state.
class _AssistantAvatarSheet extends ConsumerStatefulWidget {
  const _AssistantAvatarSheet({required this.store, this.onChanged});

  final AssistantAvatarMediaStore store;
  final Future<void> Function()? onChanged;

  @override
  ConsumerState<_AssistantAvatarSheet> createState() =>
      _AssistantAvatarSheetState();
}

class _AssistantAvatarSheetState extends ConsumerState<_AssistantAvatarSheet> {
  AssistantAvatarMediaSet _media = AssistantAvatarMediaSet.empty;
  AssistantActivity? _busy;

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  Future<void> _reload() async {
    final media = await widget.store.load();
    if (!mounted) return;
    setState(() => _media = media);
  }

  Future<void> _choose(AssistantActivity state) async {
    setState(() => _busy = state);
    final stored = await widget.store.pickAndAssign(state);
    if (!mounted) return;
    setState(() => _busy = null);
    if (stored == false) {
      AdaptiveSnackBar.show(
        context,
        message: AppLocalizations.of(context)!.assistantAvatarPickFailed,
        type: AdaptiveSnackBarType.error,
      );
      return;
    }
    if (stored == true) await _changed();
  }

  Future<void> _remove(AssistantActivity state) async {
    setState(() => _busy = state);
    await widget.store.remove(state);
    if (!mounted) return;
    setState(() => _busy = null);
    await _changed();
  }

  Future<void> _changed() async {
    await _reload();
    await widget.onChanged?.call();
  }

  String _kindLabel(AppLocalizations l10n, AssistantActivity state) {
    final user = _media.userFiles[state];
    if (user != null) {
      return user.kind == AssistantAvatarMediaKind.video
          ? l10n.assistantAvatarMediaVideo
          : l10n.assistantAvatarMediaImage;
    }
    if (_media.bundled.contains(state)) return l10n.assistantAvatarMediaDefault;
    return l10n.assistantAvatarMediaNone;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          Spacing.modalPadding,
          Spacing.sm,
          Spacing.modalPadding,
          Spacing.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.assistantAvatar,
              style: AppTypography.titleMediumStyle.copyWith(
                color: theme.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: Spacing.md),
            for (final state in AssistantActivity.values)
              _buildRow(context, l10n, theme, state),
            if (ref.watch(
              appSettingsProvider.select((settings) => settings.messageBubbles),
            ))
              _BubbleColorPicker(l10n: l10n, theme: theme),
          ],
        ),
      ),
    );
  }

  Widget _buildRow(
    BuildContext context,
    AppLocalizations l10n,
    ConduitThemeExtension theme,
    AssistantActivity state,
  ) {
    final hasUserFile = _media.userFiles.containsKey(state);
    final overridesDefault = hasUserFile && _media.bundled.contains(state);
    final busy = _busy != null;
    return Padding(
      key: ValueKey('assistant-avatar-row-${state.name}'),
      padding: const EdgeInsets.symmetric(vertical: Spacing.xs),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _activityLabel(l10n, state),
                  style: AppTypography.bodyLargeStyle.copyWith(
                    color: theme.textPrimary,
                  ),
                ),
                Text(
                  overridesDefault
                      ? '${_kindLabel(l10n, state)} · '
                            '${l10n.assistantAvatarRemoveRestoresDefault}'
                      : _kindLabel(l10n, state),
                  style: AppTypography.bodySmallStyle.copyWith(
                    color: theme.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: Spacing.sm),
          AdaptiveButton(
            key: ValueKey('assistant-avatar-choose-${state.name}'),
            onPressed: () => _choose(state),
            enabled: !busy,
            label: l10n.assistantAvatarChoose,
            style: AdaptiveButtonStyle.tinted,
            size: AdaptiveButtonSize.small,
            useNative: false,
          ),
          const SizedBox(width: Spacing.xs),
          AdaptiveButton(
            key: ValueKey('assistant-avatar-remove-${state.name}'),
            onPressed: () => _remove(state),
            enabled: !busy && hasUserFile,
            label: l10n.assistantAvatarRemove,
            style: AdaptiveButtonStyle.plain,
            size: AdaptiveButtonSize.small,
            useNative: false,
          ),
        ],
      ),
    );
  }
}

/// The user bubble color choice, shown in the avatar sheet while "Message
/// bubbles" is on: Auto (from the avatar), Gray (the neutral look) and a few
/// swatches, each previewed as the bubble it would make in this theme.
class _BubbleColorPicker extends ConsumerWidget {
  const _BubbleColorPicker({required this.l10n, required this.theme});

  final AppLocalizations l10n;
  final ConduitThemeExtension theme;

  String _swatchLabel(MessageBubbleSwatch swatch) => switch (swatch) {
    MessageBubbleSwatch.gold => l10n.assistantAvatarBubbleColorGold,
    MessageBubbleSwatch.orange => l10n.assistantAvatarBubbleColorOrange,
    MessageBubbleSwatch.pink => l10n.assistantAvatarBubbleColorPink,
    MessageBubbleSwatch.purple => l10n.assistantAvatarBubbleColorPurple,
    MessageBubbleSwatch.blue => l10n.assistantAvatarBubbleColorBlue,
    MessageBubbleSwatch.green => l10n.assistantAvatarBubbleColorGreen,
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(
      appSettingsProvider.select(
        (settings) => settings.assistantAvatarBubbleColor,
      ),
    );
    final auto = ref.watch(assistantAvatarAutoAccentProvider);
    void choose(String value) => ref
        .read(appSettingsProvider.notifier)
        .setAssistantAvatarBubbleColor(value);

    final options = <Widget>[
      _BubbleColorOption(
        key: const ValueKey('bubble-color-auto'),
        label: l10n.assistantAvatarBubbleColorAuto,
        colors: resolveMessageBubbleColors(theme, auto),
        icon: cupertinoIconForSFSymbol('sparkles'),
        selected: selected == assistantAvatarBubbleColorAuto,
        onTap: () => choose(assistantAvatarBubbleColorAuto),
        theme: theme,
      ),
      _BubbleColorOption(
        key: const ValueKey('bubble-color-gray'),
        label: l10n.assistantAvatarBubbleColorGray,
        colors: resolveMessageBubbleColors(theme, null),
        selected: selected == assistantAvatarBubbleColorGray,
        onTap: () => choose(assistantAvatarBubbleColorGray),
        theme: theme,
      ),
      for (final swatch in MessageBubbleSwatch.values)
        _BubbleColorOption(
          key: ValueKey('bubble-color-${swatch.name}'),
          label: _swatchLabel(swatch),
          colors: resolveMessageBubbleColors(theme, swatch.color),
          selected:
              parseBubbleColor(selected)?.toARGB32() == swatch.color.toARGB32(),
          onTap: () => choose(swatch.storageValue),
          theme: theme,
        ),
    ];

    return Padding(
      padding: const EdgeInsets.only(top: Spacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.assistantAvatarBubbleColor,
            style: AppTypography.bodyLargeStyle.copyWith(
              color: theme.textPrimary,
            ),
          ),
          Text(
            l10n.assistantAvatarBubbleColorDescription,
            style: AppTypography.bodySmallStyle.copyWith(
              color: theme.textSecondary,
            ),
          ),
          const SizedBox(height: Spacing.sm),
          Wrap(spacing: Spacing.sm, runSpacing: Spacing.sm, children: options),
        ],
      ),
    );
  }
}

class _BubbleColorOption extends StatelessWidget {
  const _BubbleColorOption({
    super.key,
    required this.label,
    required this.colors,
    required this.selected,
    required this.onTap,
    required this.theme,
    this.icon,
  });

  static const double _size = 40;

  final String label;
  final MessageBubbleColors colors;
  final bool selected;
  final VoidCallback onTap;
  final ConduitThemeExtension theme;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          width: 56,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: _size + 6,
                height: _size + 6,
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: selected
                        ? theme.textPrimary
                        : const Color(0x00000000),
                    width: 2,
                  ),
                ),
                child: Container(
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: colors.userFill,
                  ),
                  child: icon == null
                      ? null
                      : Icon(icon, size: 18, color: colors.userText),
                ),
              ),
              const SizedBox(height: Spacing.xxs),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTypography.captionStyle.copyWith(
                  color: selected ? theme.textPrimary : theme.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
