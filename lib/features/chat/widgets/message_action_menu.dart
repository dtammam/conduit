import 'package:conduit/core/services/haptic_service.dart';
import 'package:conduit/features/chat/reactions/quick_reply_reactions.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// One action of the message menu: an icon button with a short label.
class MessageMenuAction {
  const MessageMenuAction({
    required this.id,
    required this.icon,
    required this.label,
    this.onTap,
    this.destructive = false,
  });

  final String id;
  final IconData icon;
  final String label;

  /// Null shows the action disabled.
  final VoidCallback? onTap;
  final bool destructive;
}

/// What the menu of one message holds.
///
/// Row one is the emoji reactions (when [onReaction] is set). Row two is
/// [actions] as icon buttons, followed by a More button when [more] is not
/// empty, which swaps the row for the [more] list.
class MessageMenuSpec {
  const MessageMenuSpec({
    required this.actions,
    this.more = const <MessageMenuAction>[],
    this.moreIcon,
    this.onReaction,
  });

  final List<MessageMenuAction> actions;
  final List<MessageMenuAction> more;

  /// The icon of the More button, shown when [more] is not empty.
  final IconData? moreIcon;
  final ValueChanged<QuickReplyReaction>? onReaction;
}

/// Opens a message's menu on a long press of [child].
///
/// The press is claimed at 400 ms, before text selection's own long press, so
/// while [enabled] a long press no longer selects a word. The detector stays
/// in the tree when disabled so the content keeps its state. [buildMenu] is
/// called when the press happens, so the menu reflects the message as it is
/// then.
class MessageMenuLongPress extends StatelessWidget {
  const MessageMenuLongPress({
    super.key,
    required this.enabled,
    required this.buildMenu,
    required this.child,
  });

  static const Duration pressDuration = Duration(milliseconds: 400);

  final bool enabled;
  final MessageMenuSpec Function() buildMenu;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // The text under the press takes focus on touch down (selection does),
    // which would unfocus the composer. A press that opens the menu hands
    // focus back to whatever held it before.
    FocusNode? focusBeforePress;
    return RawGestureDetector(
      behavior: HitTestBehavior.translucent,
      gestures: enabled
          ? <Type, GestureRecognizerFactory>{
              LongPressGestureRecognizer:
                  GestureRecognizerFactoryWithHandlers<
                    LongPressGestureRecognizer
                  >(
                    () => LongPressGestureRecognizer(duration: pressDuration),
                    (recognizer) => recognizer
                      ..onLongPressDown = (_) {
                        focusBeforePress = FocusManager.instance.primaryFocus;
                      }
                      ..onLongPressStart = (details) {
                        final previous = focusBeforePress;
                        if (previous != null &&
                            previous.context != null &&
                            !previous.hasPrimaryFocus) {
                          previous.requestFocus();
                        }
                        ConduitHaptics.selectionClick();
                        showMessageMenu(
                          context,
                          pressPoint: details.globalPosition,
                          spec: buildMenu(),
                        );
                      },
                  ),
            }
          : const <Type, GestureRecognizerFactory>{},
      child: child,
    );
  }
}

/// Shows the menu above [pressPoint] (global coordinates), kept inside the
/// screen. A tap outside dismisses it; so does choosing something, and the
/// choice runs after the menu is gone.
Future<void> showMessageMenu(
  BuildContext context, {
  required Offset pressPoint,
  required MessageMenuSpec spec,
}) {
  final l10n = AppLocalizations.of(context)!;
  VoidCallback? chosen;
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    // The menu must not take focus: that would close the keyboard and move
    // the transcript under it.
    requestFocus: false,
    barrierLabel: l10n.close,
    barrierColor: const Color(0x00000000),
    transitionDuration: const Duration(milliseconds: 150),
    pageBuilder: (dialogContext, _, _) => CustomSingleChildLayout(
      delegate: _MenuLayout(
        pressPoint: pressPoint,
        padding: MediaQuery.paddingOf(dialogContext),
      ),
      child: _MessageMenu(
        spec: spec,
        onChosen: (callback) {
          chosen = callback;
          Navigator.of(dialogContext).pop();
        },
      ),
    ),
    transitionBuilder: (_, animation, _, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutBack,
        reverseCurve: Curves.easeIn,
      );
      return FadeTransition(
        opacity: animation,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.6, end: 1).animate(curved),
          alignment: Alignment.bottomCenter,
          child: child,
        ),
      );
    },
  ).then((_) {
    final callback = chosen;
    if (callback == null) return;
    ConduitHaptics.selectionClick();
    callback();
  });
}

class _MenuLayout extends SingleChildLayoutDelegate {
  const _MenuLayout({required this.pressPoint, required this.padding});

  static const double _gap = Spacing.md;
  static const double _margin = Spacing.sm;

  final Offset pressPoint;
  final EdgeInsets padding;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      constraints.loosen();

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final minLeft = padding.left + _margin;
    final maxLeft = size.width - padding.right - childSize.width - _margin;
    final minTop = padding.top + _margin;
    final maxTop = size.height - padding.bottom - childSize.height - _margin;
    final left = (pressPoint.dx - childSize.width / 2).clamp(
      minLeft,
      maxLeft < minLeft ? minLeft : maxLeft,
    );
    final top = (pressPoint.dy - childSize.height - _gap).clamp(
      minTop,
      maxTop < minTop ? minTop : maxTop,
    );
    return Offset(left, top);
  }

  @override
  bool shouldRelayout(_MenuLayout oldDelegate) =>
      pressPoint != oldDelegate.pressPoint || padding != oldDelegate.padding;
}

class _MessageMenu extends StatefulWidget {
  const _MessageMenu({required this.spec, required this.onChosen});

  final MessageMenuSpec spec;
  final ValueChanged<VoidCallback> onChosen;

  @override
  State<_MessageMenu> createState() => _MessageMenuState();
}

class _MessageMenuState extends State<_MessageMenu> {
  static const double _cardRadius = 20;

  bool _showingMore = false;

  @override
  Widget build(BuildContext context) {
    final spec = widget.spec;
    final onReaction = spec.onReaction;
    return Column(
      key: const ValueKey<String>('message-action-menu'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (onReaction != null && !_showingMore) ...[
          QuickReplyPill(
            onSelected: (reaction) =>
                widget.onChosen(() => onReaction(reaction)),
          ),
          const SizedBox(height: Spacing.xs),
        ],
        _card(context, _showingMore ? _moreList(context) : _actionRow(context)),
      ],
    );
  }

  Widget _card(BuildContext context, Widget child) {
    final theme = context.conduitTheme;
    return Container(
      padding: const EdgeInsets.all(Spacing.xxs),
      decoration: BoxDecoration(
        color: theme.surfaceBackground,
        borderRadius: BorderRadius.circular(_cardRadius),
        border: Border.all(
          color: theme.textPrimary.withValues(alpha: 0.12),
          width: BorderWidth.thin,
        ),
        boxShadow: const [
          BoxShadow(
            color: Color(0x33000000),
            blurRadius: 16,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: child,
    );
  }

  Widget _actionRow(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spec = widget.spec;
    return Row(
      key: const ValueKey<String>('message-menu-actions'),
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final action in spec.actions) _actionButton(context, action),
        if (spec.more.isNotEmpty && spec.moreIcon != null)
          _actionButton(
            context,
            MessageMenuAction(
              id: 'more',
              icon: spec.moreIcon!,
              label: l10n.more,
              onTap: () => setState(() => _showingMore = true),
            ),
            closesMenu: false,
          ),
      ],
    );
  }

  Widget _actionButton(
    BuildContext context,
    MessageMenuAction action, {
    bool closesMenu = true,
  }) {
    final theme = context.conduitTheme;
    final enabled = action.onTap != null;
    final color = action.destructive
        ? theme.error
        : theme.textPrimary.withValues(alpha: enabled ? 0.9 : 0.36);
    return Semantics(
      button: true,
      enabled: enabled,
      label: action.label,
      excludeSemantics: true,
      child: GestureDetector(
        key: ValueKey<String>('message-menu-${action.id}'),
        behavior: HitTestBehavior.opaque,
        onTap: !enabled
            ? null
            : () {
                final onTap = action.onTap!;
                if (closesMenu) {
                  widget.onChosen(onTap);
                } else {
                  ConduitHaptics.selectionClick();
                  onTap();
                }
              },
        child: SizedBox(
          width: 64,
          height: 58,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(action.icon, size: 22, color: color),
              const SizedBox(height: Spacing.xxs),
              Text(
                action.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  color: color,
                  decoration: TextDecoration.none,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _moreList(BuildContext context) {
    final theme = context.conduitTheme;
    return Column(
      key: const ValueKey<String>('message-menu-more'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final action in widget.spec.more)
          Builder(
            builder: (context) {
              final enabled = action.onTap != null;
              final color = action.destructive
                  ? theme.error
                  : theme.textPrimary.withValues(alpha: enabled ? 0.9 : 0.36);
              return Semantics(
                button: true,
                enabled: enabled,
                label: action.label,
                excludeSemantics: true,
                child: GestureDetector(
                  key: ValueKey<String>('message-menu-${action.id}'),
                  behavior: HitTestBehavior.opaque,
                  onTap: enabled ? () => widget.onChosen(action.onTap!) : null,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      minHeight: 44,
                      minWidth: 200,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: Spacing.md,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(action.icon, size: 20, color: color),
                          const SizedBox(width: Spacing.md),
                          Text(
                            action.label,
                            style: TextStyle(
                              fontSize: 15,
                              color: color,
                              decoration: TextDecoration.none,
                              fontWeight: FontWeight.w400,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
      ],
    );
  }
}
