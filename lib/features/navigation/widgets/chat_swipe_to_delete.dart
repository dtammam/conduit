import 'package:conduit/core/services/haptic_service.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit/shared/widgets/platform_ui/vocabulary.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import '../../../shared/theme/theme_extensions.dart';
import 'conversation_tile.dart';

/// How long a swiped chat can be brought back before it is deleted.
const Duration kChatSwipeDeleteUndoWindow = Duration(seconds: 4);

/// A right swipe on a chat row that deletes it.
///
/// Only a rightward drag is claimed. A leftward one is left to the drawer's
/// swipe-to-close and a vertical one to scrolling, and a press held until the
/// row's menu claims it never reaches this gesture. Releasing past
/// [threshold] of the row's width, or flinging right, calls [onDelete];
/// otherwise the row springs back.
class ChatSwipeToDelete extends StatefulWidget {
  const ChatSwipeToDelete({
    super.key,
    required this.onDelete,
    required this.child,
    this.enabled = true,
  });

  final VoidCallback onDelete;
  final Widget child;
  final bool enabled;

  /// Fraction of the row's width past which a release deletes.
  static const double threshold = 0.4;

  /// Rightward speed, in logical pixels per second, that deletes on release.
  static const double flingVelocity = 700;

  @override
  State<ChatSwipeToDelete> createState() => _ChatSwipeToDeleteState();
}

class _ChatSwipeToDeleteState extends State<ChatSwipeToDelete>
    with SingleTickerProviderStateMixin {
  late final AnimationController _offset = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );
  double _width = 0;
  bool _pastThreshold = false;
  bool _deleting = false;

  @override
  void dispose() {
    _offset.dispose();
    super.dispose();
  }

  void _handleStart(DragStartDetails details) {
    _offset.stop();
  }

  void _handleUpdate(DragUpdateDetails details) {
    if (_width <= 0 || _deleting) return;
    _offset.value = (_offset.value + (details.primaryDelta ?? 0) / _width)
        .clamp(0.0, 1.0);
    final past = _offset.value >= ChatSwipeToDelete.threshold;
    if (past != _pastThreshold) {
      _pastThreshold = past;
      if (past) ConduitHaptics.lightImpact();
    }
  }

  void _handleEnd(DragEndDetails details) {
    if (_deleting) return;
    final velocity = details.primaryVelocity ?? 0;
    final deletes =
        _offset.value >= ChatSwipeToDelete.threshold ||
        (velocity >= ChatSwipeToDelete.flingVelocity && _offset.value > 0);
    _pastThreshold = false;
    if (!deletes) {
      _offset.animateBack(0, curve: Curves.easeOutBack);
      return;
    }
    _deleting = true;
    _offset.animateTo(1, curve: Curves.easeOut).whenCompleteOrCancel(() {
      if (mounted) widget.onDelete();
    });
  }

  void _handleCancel() {
    if (_deleting) return;
    _pastThreshold = false;
    _offset.animateBack(0, curve: Curves.easeOutBack);
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    final theme = context.conduitTheme;
    final destructive = theme.statusPalette.destructive;
    return RawGestureDetector(
      gestures: <Type, GestureRecognizerFactory>{
        _RightSwipeGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<_RightSwipeGestureRecognizer>(
              () => _RightSwipeGestureRecognizer(debugOwner: this),
              (recognizer) {
                recognizer
                  ..gestureSettings = MediaQuery.maybeGestureSettingsOf(context)
                  ..onStart = _handleStart
                  ..onUpdate = _handleUpdate
                  ..onEnd = _handleEnd
                  ..onCancel = _handleCancel;
              },
            ),
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          _width = constraints.maxWidth;
          return AnimatedBuilder(
            animation: _offset,
            child: widget.child,
            builder: (context, child) {
              final value = _offset.value;
              return Stack(
                children: [
                  if (value > 0)
                    Positioned.fill(
                      child: Padding(
                        padding: kConversationTileMargin,
                        child: DecoratedBox(
                          key: const ValueKey<String>(
                            'chat-swipe-delete-background',
                          ),
                          decoration: BoxDecoration(
                            color: destructive.base,
                            borderRadius: BorderRadius.circular(
                              AppBorderRadius.md,
                            ),
                          ),
                          // The row always slides to the physical right, so
                          // the icon sits on the left it uncovers, in RTL too.
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: Spacing.md,
                              ),
                              child: Icon(
                                PlatformInfo.isIOS
                                    ? CupertinoIcons.delete
                                    : Icons.delete_rounded,
                                color: destructive.onBase,
                                size: IconSize.listItem,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  Transform.translate(
                    offset: Offset(value * _width, 0),
                    child: child,
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

/// A horizontal drag that only ever claims rightward movement.
final class _RightSwipeGestureRecognizer
    extends HorizontalDragGestureRecognizer {
  _RightSwipeGestureRecognizer({super.debugOwner});

  Offset? _origin;
  bool _disqualified = false;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    _origin = event.position;
    _disqualified = false;
    super.addAllowedPointer(event);
  }

  @override
  void handleEvent(PointerEvent event) {
    final origin = _origin;
    if (event is PointerMoveEvent && origin != null) {
      final delta = event.position - origin;
      final slop = computeHitSlop(event.kind, gestureSettings);
      // Left belongs to the drawer's swipe-to-close, vertical to the list.
      if ((delta.dx < -slop && delta.dx.abs() > delta.dy.abs()) ||
          (delta.dy.abs() > slop && delta.dy.abs() > delta.dx.abs())) {
        _disqualified = true;
      }
    }
    super.handleEvent(event);
  }

  @override
  bool hasSufficientGlobalDistanceToAccept(
    PointerDeviceKind pointerDeviceKind,
    double? deviceTouchSlop,
  ) =>
      !_disqualified &&
      globalDistanceMoved > computeHitSlop(pointerDeviceKind, gestureSettings);

  @override
  void didStopTrackingLastPointer(int pointer) {
    super.didStopTrackingLastPointer(pointer);
    _origin = null;
    _disqualified = false;
  }

  @override
  String get debugDescription => 'chat row swipe to delete';
}
