import 'package:flutter/widgets.dart';

import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/adaptive_toolbar_components.dart';
import '../../../shared/widgets/conduit_components.dart';

/// A small pill with a spinner and a line of text, shown over the chat while
/// Share as video or audio is being made (the share sheet opens when it ends).
/// It never blocks touches.
class ShareProgressPill extends StatelessWidget {
  const ShareProgressPill({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    return Semantics(
      liveRegion: true,
      label: message,
      child: DecoratedBox(
        decoration: ShapeDecoration(
          color: theme.surfaceBackground,
          shape: StadiumBorder(
            side: BorderSide(color: theme.dividerColor, width: 0.5),
          ),
          shadows: const [
            BoxShadow(
              color: Color(0x33000000),
              blurRadius: 12,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Spacing.md,
            vertical: Spacing.sm,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const ConduitLoadingIndicator(size: 16, isCompact: true),
              const SizedBox(width: Spacing.sm),
              Flexible(
                child: Text(
                  message,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.standard.copyWith(
                    color: theme.textPrimary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Handle for a pill put in the app's overlay by [ShareProgress.show].
class ShareProgress {
  ShareProgress._(this._entry, this._message);

  final OverlayEntry _entry;
  final ValueNotifier<String> _message;
  bool _done = false;

  /// Puts the pill at the top of the screen, below the status bar and the app
  /// bar, so it never covers the composer (keyboard up or down). Returns null
  /// without an overlay.
  static ShareProgress? show(BuildContext context, String message) {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return null;
    final notifier = ValueNotifier<String>(message);
    final entry = OverlayEntry(
      builder: (context) => Positioned(
        left: Spacing.lg,
        right: Spacing.lg,
        top:
            MediaQuery.viewPaddingOf(context).top +
            conduitAdaptiveToolbarHeightOf(context) +
            Spacing.sm,
        child: IgnorePointer(
          child: Center(
            child: ValueListenableBuilder<String>(
              valueListenable: notifier,
              builder: (_, text, _) => ShareProgressPill(message: text),
            ),
          ),
        ),
      ),
    );
    overlay.insert(entry);
    return ShareProgress._(entry, notifier);
  }

  void update(String message) {
    if (!_done) _message.value = message;
  }

  /// Removes the pill; safe to call more than once.
  void dismiss() {
    if (_done) return;
    _done = true;
    _entry.remove();
    _entry.dispose();
    _message.dispose();
  }
}
