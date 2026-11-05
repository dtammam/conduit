import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../services/speech_take_store.dart';

/// Plays the previewed file; a seam so tests need no audio engine.
abstract interface class ReplyAudioPreviewPlayer {
  /// Loads [file] and returns its length when known.
  Future<Duration?> load(File file);
  Future<void> play();
  Future<void> pause();
  Future<void> seekToStart();
  Stream<bool> get playing;
  Stream<Duration> get position;
  Stream<void> get completed;
  Future<void> dispose();
}

/// The phone's own player, used for the preview only (read-aloud has its own).
final class JustAudioPreviewPlayer implements ReplyAudioPreviewPlayer {
  final AudioPlayer _player = AudioPlayer();

  @override
  Future<Duration?> load(File file) => _player.setFilePath(file.path);
  @override
  Future<void> play() => _player.play();
  @override
  Future<void> pause() => _player.pause();
  @override
  Future<void> seekToStart() => _player.seek(Duration.zero);
  @override
  Stream<bool> get playing => _player.playingStream;
  @override
  Stream<Duration> get position => _player.positionStream;
  @override
  Stream<void> get completed => _player.processingStateStream.where(
    (state) => state == ProcessingState.completed,
  );
  @override
  Future<void> dispose() => _player.dispose();
}

/// Shows the take to be shared and returns the one Dean last previewed, or
/// null when he closes the sheet. The sheet holds play and pause, the length,
/// Try again (a new take that replaces this one, as often as he likes) and
/// the action ([actionLabel]: Share or Save).
Future<SpeechTake?> showReplyAudioPreview(
  BuildContext context, {
  required SpeechTake take,
  required Future<SpeechTake> Function() onTryAgain,
  required String actionLabel,
  ReplyAudioPreviewPlayer Function()? playerFactory,
}) {
  return showModalBottomSheet<SpeechTake>(
    context: context,
    useSafeArea: true,
    showDragHandle: true,
    backgroundColor: context.conduitTheme.surfaceBackground,
    builder: (context) => ReplyAudioPreviewSheet(
      take: take,
      onTryAgain: onTryAgain,
      actionLabel: actionLabel,
      player: (playerFactory ?? JustAudioPreviewPlayer.new)(),
    ),
  );
}

class ReplyAudioPreviewSheet extends StatefulWidget {
  const ReplyAudioPreviewSheet({
    super.key,
    required this.take,
    required this.onTryAgain,
    required this.actionLabel,
    required this.player,
  });

  final SpeechTake take;
  final Future<SpeechTake> Function() onTryAgain;
  final String actionLabel;
  final ReplyAudioPreviewPlayer player;

  @override
  State<ReplyAudioPreviewSheet> createState() => _ReplyAudioPreviewSheetState();
}

class _ReplyAudioPreviewSheetState extends State<ReplyAudioPreviewSheet> {
  late SpeechTake _take = widget.take;
  Duration? _length;
  Duration _position = Duration.zero;
  bool _playing = false;
  bool _busy = false;
  String? _error;
  final List<StreamSubscription<Object?>> _subs = [];

  @override
  void initState() {
    super.initState();
    final player = widget.player;
    _subs
      ..add(
        player.playing.listen((v) {
          if (mounted) setState(() => _playing = v);
        }),
      )
      ..add(
        player.position.listen((v) {
          if (mounted) setState(() => _position = v);
        }),
      )
      ..add(
        player.completed.listen((_) async {
          await player.pause();
          await player.seekToStart();
          if (mounted) setState(() => _position = Duration.zero);
        }),
      );
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final length = await widget.player.load(_take.file);
      if (mounted) setState(() => _length = length);
    } catch (_) {
      if (mounted) setState(() => _length = null);
    }
  }

  @override
  void dispose() {
    for (final sub in _subs) {
      unawaited(sub.cancel());
    }
    unawaited(widget.player.dispose());
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_playing) {
      await widget.player.pause();
    } else {
      await widget.player.play();
    }
  }

  Future<void> _tryAgain() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.player.pause();
      final fresh = await widget.onTryAgain();
      if (!mounted) return;
      _take = fresh;
      _position = Duration.zero;
      await _load();
    } catch (error) {
      if (mounted) {
        setState(() => _error = AppLocalizations.of(context)!
            .replyAudioTryAgainFailed(error.toString()));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static String _clock(Duration d) {
    final seconds = d.inSeconds;
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final length = _length;
    final fraction = length == null || length.inMilliseconds == 0
        ? 0.0
        : (_position.inMilliseconds / length.inMilliseconds).clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Spacing.lg,
        0,
        Spacing.lg,
        Spacing.lg,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.replyAudioTitle,
            style: AppTypography.standard.copyWith(
              color: theme.textPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: Spacing.md),
          Row(
            children: [
              IconButton(
                key: const ValueKey('reply-audio-play'),
                tooltip: _playing ? l10n.replyAudioPause : l10n.replyAudioPlay,
                onPressed: _busy ? null : _toggle,
                icon: Icon(
                  _playing ? CupertinoIcons.pause_fill : CupertinoIcons.play_fill,
                ),
              ),
              Expanded(
                child: LinearProgressIndicator(
                  value: _busy ? null : fraction,
                  minHeight: 4,
                ),
              ),
              const SizedBox(width: Spacing.md),
              Text(
                key: const ValueKey('reply-audio-length'),
                length == null
                    ? '--:--'
                    : '${_clock(_position)} / ${_clock(length)}',
                style: AppTypography.small.copyWith(
                  color: theme.textSecondary,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          if (_busy || _error != null) ...[
            const SizedBox(height: Spacing.sm),
            Text(
              _busy ? l10n.replyAudioMakingNew : _error!,
              key: const ValueKey('reply-audio-status'),
              style: AppTypography.small.copyWith(
                color: _busy ? theme.textSecondary : theme.error,
              ),
            ),
          ],
          const SizedBox(height: Spacing.lg),
          Row(
            children: [
              Expanded(
                child: ConduitButton(
                  key: const ValueKey('reply-audio-try-again'),
                  text: l10n.replyAudioTryAgain,
                  isSecondary: true,
                  isLoading: _busy,
                  isFullWidth: true,
                  useNative: false,
                  onPressed: _busy ? null : _tryAgain,
                ),
              ),
              const SizedBox(width: Spacing.md),
              Expanded(
                child: ConduitButton(
                  key: const ValueKey('reply-audio-action'),
                  text: widget.actionLabel,
                  isFullWidth: true,
                  useNative: false,
                  onPressed: _busy ? null : () => Navigator.of(context).pop(_take),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
