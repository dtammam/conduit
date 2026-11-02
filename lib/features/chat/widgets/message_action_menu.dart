import 'dart:async';

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
    this.onBreak,
  });

  final List<MessageMenuAction> actions;
  final List<MessageMenuAction> more;

  /// The icon of the More button, shown when [more] is not empty.
  final IconData? moreIcon;
  final ValueChanged<QuickReplyReaction>? onReaction;

  /// The 💥 after the reactions: marks the reply as broken.
  final VoidCallback? onBreak;
}

/// Opens a message's menu on a long press of [child].
///
/// The press is claimed at 400 ms, before text selection's own long press, so
/// while [enabled] a long press no longer selects a word. The detector stays
/// in the tree when disabled so the content keeps its state. [buildMenu] is
/// called when the press happens, so the menu reflects the message as it is
/// then.
///
/// While a text field has focus (the composer, keyboard up) the message text
/// cannot take it. Touching selectable text focuses its selection region on
/// touch down, long before the press is recognised; that pulled focus out of
/// the composer, the keyboard went down, the tab bar and composer resized and
/// the whole transcript moved, then the keyboard came back when the menu
/// opened and it moved again.
class MessageMenuLongPress extends StatefulWidget {
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
  State<MessageMenuLongPress> createState() => _MessageMenuLongPressState();
}

class _MessageMenuLongPressState extends State<MessageMenuLongPress> {
  /// Never focused itself; its only job is to switch focus off for the message
  /// text under it while a text field holds focus.
  final FocusNode _guard = FocusNode(
    debugLabel: 'MessageMenuLongPress',
    canRequestFocus: false,
    skipTraversal: true,
  );
  FocusNode? _focusBeforePress;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_syncGuard);
    _syncGuard();
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_syncGuard);
    _guard.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(MessageMenuLongPress oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncGuard();
  }

  /// Off while the content is being edited ([MessageMenuLongPress.enabled] is
  /// false then): the edit field is under the guard and must take focus.
  void _syncGuard() {
    final editing =
        FocusManager.instance.primaryFocus?.context
            ?.findAncestorWidgetOfExactType<EditableText>() !=
        null;
    _guard.descendantsAreFocusable = !(editing && widget.enabled);
  }

  @override
  Widget build(BuildContext context) {
    return RawGestureDetector(
      behavior: HitTestBehavior.translucent,
      gestures: widget.enabled
          ? <Type, GestureRecognizerFactory>{
              LongPressGestureRecognizer:
                  GestureRecognizerFactoryWithHandlers<
                    LongPressGestureRecognizer
                  >(
                    () => LongPressGestureRecognizer(
                      duration: MessageMenuLongPress.pressDuration,
                    ),
                    (recognizer) => recognizer
                      ..onLongPressDown = (_) {
                        _focusBeforePress = FocusManager.instance.primaryFocus;
                      }
                      ..onLongPressStart = (details) {
                        // Other focus (not a text field) that the touch took
                        // goes back to what held it before.
                        final previous = _focusBeforePress;
                        if (previous != null &&
                            previous.context != null &&
                            !previous.hasPrimaryFocus) {
                          previous.requestFocus();
                        }
                        ConduitHaptics.selectionClick();
                        showMessageMenu(
                          context,
                          pressPoint: details.globalPosition,
                          spec: widget.buildMenu(),
                        );
                      },
                  ),
            }
          : const <Type, GestureRecognizerFactory>{},
      child: Focus(
        focusNode: _guard,
        canRequestFocus: false,
        skipTraversal: true,
        child: widget.child,
      ),
    );
  }
}

/// Shows the menu above [pressPoint] (global coordinates), kept inside the
/// screen. A tap outside dismisses it; so does choosing something, and the
/// choice runs after the menu is gone.
///
/// The menu is an entry in the root [Overlay], not a pushed route. A route
/// covers the page under it: every widget that reads `ModalRoute.isCurrent`
/// rebuilds as covered (the composer swaps its glass shell and removes its
/// native buttons, assistant rows stop following a streaming reply and catch
/// up when the menu closes) and the page's focus scope is re-requested on
/// pop. The transcript moved with that churn. An overlay entry leaves the page
/// untouched, takes no focus and keeps the keyboard where it was.
Future<void> showMessageMenu(
  BuildContext context, {
  required Offset pressPoint,
  required MessageMenuSpec spec,
}) {
  final overlay = Overlay.of(context, rootOverlay: true);
  final padding = MediaQuery.paddingOf(context);
  final barrierLabel = AppLocalizations.of(context)!.close;
  final done = Completer<void>();
  VoidCallback? chosen;
  final key = GlobalKey<_MessageMenuHostState>();
  late final OverlayEntry entry;
  var removed = false;

  void remove() {
    if (removed) return;
    removed = true;
    entry.remove();
    entry.dispose();
    done.complete();
  }

  entry = OverlayEntry(
    builder: (_) => _MessageMenuHost(
      key: key,
      pressPoint: pressPoint,
      padding: padding,
      spec: spec,
      barrierLabel: barrierLabel,
      onChosen: (callback) {
        chosen = callback;
        key.currentState?.dismiss();
      },
      onDismissed: remove,
    ),
  );
  overlay.insert(entry);

  return done.future.then((_) {
    final callback = chosen;
    if (callback == null) return;
    ConduitHaptics.selectionClick();
    callback();
  });
}

/// The overlay entry's content: a transparent barrier and the menu, animated
/// in and out.
class _MessageMenuHost extends StatefulWidget {
  const _MessageMenuHost({
    super.key,
    required this.pressPoint,
    required this.padding,
    required this.spec,
    required this.barrierLabel,
    required this.onChosen,
    required this.onDismissed,
  });

  final Offset pressPoint;
  final EdgeInsets padding;
  final MessageMenuSpec spec;
  final String barrierLabel;
  final ValueChanged<VoidCallback> onChosen;
  final VoidCallback onDismissed;

  @override
  State<_MessageMenuHost> createState() => _MessageMenuHostState();
}

class _MessageMenuHostState extends State<_MessageMenuHost>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 150),
  );
  late final CurvedAnimation _curved = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutBack,
    reverseCurve: Curves.easeIn,
  );
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _controller.forward();
  }

  /// Plays the exit, then tells the opener to remove the entry.
  void dismiss() {
    if (_closing) return;
    _closing = true;
    _controller.reverse().whenComplete(widget.onDismissed);
  }

  @override
  void dispose() {
    _curved.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox.expand(
      child: Stack(
        children: [
          Positioned.fill(
            child: Semantics(
              label: widget.barrierLabel,
              button: true,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: dismiss,
              ),
            ),
          ),
          Positioned.fill(
            child: CustomSingleChildLayout(
              delegate: _MenuLayout(
                pressPoint: widget.pressPoint,
                padding: widget.padding,
              ),
              child: FadeTransition(
                opacity: _controller,
                child: ScaleTransition(
                  scale: Tween<double>(begin: 0.6, end: 1).animate(_curved),
                  alignment: Alignment.bottomCenter,
                  child: _MessageMenu(
                    spec: widget.spec,
                    onChosen: widget.onChosen,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
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
            onBreak: spec.onBreak == null
                ? null
                : () => widget.onChosen(spec.onBreak!),
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
    final media = MediaQuery.of(context);
    // The card never grows past the screen: the row scrolls sideways instead
    // of clipping its last buttons, with an edge fade where more is hidden.
    final maxWidth =
        media.size.width -
        media.padding.horizontal -
        2 * Spacing.sm -
        2 * Spacing.xxs;
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth > 0 ? maxWidth : 0),
      child: _ScrollingActionRow(
        key: const ValueKey<String>('message-menu-actions'),
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
      ),
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

/// A horizontally scrollable row of menu buttons. A soft fade on each edge
/// that has more behind it shows the row scrolls.
class _ScrollingActionRow extends StatefulWidget {
  const _ScrollingActionRow({super.key, required this.children});

  final List<Widget> children;

  @override
  State<_ScrollingActionRow> createState() => _ScrollingActionRowState();
}

class _ScrollingActionRowState extends State<_ScrollingActionRow> {
  static const double _fade = 24;

  final ScrollController _controller = ScrollController();
  bool _fadeStart = false;
  bool _fadeEnd = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_update);
    WidgetsBinding.instance.addPostFrameCallback((_) => _update());
  }

  @override
  void dispose() {
    _controller.removeListener(_update);
    _controller.dispose();
    super.dispose();
  }

  void _update() {
    if (!mounted || !_controller.hasClients) return;
    final position = _controller.position;
    final start = position.pixels > 1;
    final end = position.pixels < position.maxScrollExtent - 1;
    if (start != _fadeStart || end != _fadeEnd) {
      setState(() {
        _fadeStart = start;
        _fadeEnd = end;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final row = SingleChildScrollView(
      controller: _controller,
      scrollDirection: Axis.horizontal,
      child: Row(mainAxisSize: MainAxisSize.min, children: widget.children),
    );
    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (bounds) {
        final fade = bounds.width <= 0 ? 0.0 : _fade / bounds.width;
        return LinearGradient(
          colors: [
            _fadeStart ? const Color(0x00FFFFFF) : const Color(0xFFFFFFFF),
            const Color(0xFFFFFFFF),
            const Color(0xFFFFFFFF),
            _fadeEnd ? const Color(0x00FFFFFF) : const Color(0xFFFFFFFF),
          ],
          stops: [0, fade, 1 - fade, 1],
        ).createShader(bounds);
      },
      child: row,
    );
  }
}
