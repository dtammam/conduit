import 'dart:async';
import 'dart:math' as math;

import 'package:conduit/core/services/haptic_service.dart';
import 'package:conduit/shared/utils/conversation_context_menu.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit/shared/widgets/platform_ui/vocabulary.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import '../../../shared/theme/theme_extensions.dart';
import 'conversation_tile.dart';

/// Called when a dragged chat is dropped on a target that accepts it.
///
/// [targetFolderId] is null when the chat should leave its folder.
typedef ChatFolderDropCallback = void Function(
  Conversation conversation,
  String? currentFolderId,
  String? targetFolderId,
);

/// Follows a chat dragged from the chats drawer onto a folder.
///
/// A drag starts from a held press on a chat (see
/// [ConduitContextMenuHoldDrag]) and follows that pointer through the
/// [GestureBinding] pointer router, so it survives the dragged row scrolling
/// away or rebuilding. [ChatFolderDropTarget]s register themselves here; the
/// one under the finger is highlighted and receives the drop.
class ChatFolderDragController extends ChangeNotifier {
  ChatFolderDragController({
    required this.scrollController,
    required this.viewportKey,
    required this.onDrop,
    required this.onHoverExpand,
  });

  /// The list that scrolls while the finger rests near its top or bottom.
  final ScrollController scrollController;

  /// Key on the scroll view, used to find its edges on screen.
  final GlobalKey viewportKey;

  final ChatFolderDropCallback onDrop;

  /// Called after the finger rests on a collapsed folder for
  /// [hoverExpandDelay].
  final ValueChanged<String> onHoverExpand;

  static const Duration hoverExpandDelay = Duration(milliseconds: 600);
  static const double autoScrollEdgeExtent = 72;
  static const double autoScrollMaxStep = 14;
  static const Duration _autoScrollInterval = Duration(milliseconds: 16);

  final Set<_ChatFolderDropTargetState> _targets =
      <_ChatFolderDropTargetState>{};
  final ValueNotifier<Offset> _position = ValueNotifier<Offset>(Offset.zero);
  _ChatDrag? _drag;
  _ChatFolderDropTargetState? _hovered;
  OverlayEntry? _previewEntry;
  Timer? _hoverExpandTimer;
  Timer? _autoScrollTimer;
  bool _disposed = false;

  bool get isDragging => _drag != null;

  /// Whether the dragged chat came from a folder, so it can leave it.
  bool get isDraggingFolderedChat => _drag?.currentFolderId != null;

  /// Whether releasing now would move the chat into [folderId], or out of
  /// its folder when [folderId] is null.
  bool isHovering(String? folderId) {
    final hovered = _hovered;
    return hovered != null && hovered.widget.folderId == folderId;
  }

  void start({
    required BuildContext context,
    required ConduitContextMenuDragStartDetails details,
    required Conversation conversation,
    required String title,
  }) {
    if (_disposed) return;
    _end(drop: false);
    // A scroll that won the pointer first keeps it.
    if (scrollController.hasClients &&
        scrollController.position.isScrollingNotifier.value) {
      return;
    }
    final folderId = conversation.folderId;
    _drag = _ChatDrag(
      pointer: details.pointer,
      conversation: conversation,
      currentFolderId: folderId == null || folderId.isEmpty ? null : folderId,
    );
    _position.value = details.globalPosition;
    GestureBinding.instance.pointerRouter.addRoute(
      details.pointer,
      _handlePointerEvent,
    );
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay != null) {
      final entry = OverlayEntry(
        builder: (context) =>
            _ChatDragPreview(position: _position, title: title),
      );
      _previewEntry = entry;
      overlay.insert(entry);
    }
    _autoScrollTimer = Timer.periodic(
      _autoScrollInterval,
      (_) => _autoScrollTick(),
    );
    ConduitHaptics.lightImpact();
    notifyListeners();
    _updateHover();
  }

  /// Ends a drag without moving anything.
  void cancel() => _end(drop: false);

  void _handlePointerEvent(PointerEvent event) {
    if (event.pointer != _drag?.pointer) return;
    if (event is PointerMoveEvent) {
      _position.value = event.position;
      _updateHover();
    } else if (event is PointerUpEvent) {
      _position.value = event.position;
      _updateHover();
      _end(drop: true);
    } else if (event is PointerCancelEvent) {
      _end(drop: false);
    }
  }

  void _end({required bool drop}) {
    final drag = _drag;
    if (drag == null) return;
    final hovered = _hovered;
    GestureBinding.instance.pointerRouter.removeRoute(
      drag.pointer,
      _handlePointerEvent,
    );
    _drag = null;
    _hovered = null;
    _hoverExpandTimer?.cancel();
    _hoverExpandTimer = null;
    _autoScrollTimer?.cancel();
    _autoScrollTimer = null;
    _previewEntry?.remove();
    _previewEntry?.dispose();
    _previewEntry = null;
    if (!_disposed) notifyListeners();
    if (!drop || hovered == null || _disposed) return;
    ConduitHaptics.lightImpact();
    onDrop(drag.conversation, drag.currentFolderId, hovered.widget.folderId);
  }

  void _updateHover() {
    final drag = _drag;
    if (drag == null) return;
    final point = _position.value;
    _ChatFolderDropTargetState? next;
    final viewport = _globalRect(viewportKey.currentContext);
    if (viewport == null || viewport.contains(point)) {
      for (final target in _targets) {
        final rect = _globalRect(target.context);
        if (rect == null || !rect.contains(point)) continue;
        if (target.widget.enabled &&
            target.widget.folderId != drag.currentFolderId) {
          next = target;
        }
        break;
      }
    }
    if (identical(next, _hovered)) return;
    _hovered = next;
    _hoverExpandTimer?.cancel();
    _hoverExpandTimer = null;
    final hovered = next;
    final folderId = hovered?.widget.folderId;
    if (hovered != null && folderId != null && hovered.widget.expandOnHover) {
      _hoverExpandTimer = Timer(hoverExpandDelay, () {
        _hoverExpandTimer = null;
        if (identical(_hovered, hovered) && hovered.mounted) {
          onHoverExpand(folderId);
        }
      });
    }
    notifyListeners();
  }

  void _autoScrollTick() {
    if (_drag == null || !scrollController.hasClients) return;
    final viewport = _globalRect(viewportKey.currentContext);
    if (viewport == null) return;
    final dy = _position.value.dy;
    final topEdge = viewport.top + autoScrollEdgeExtent;
    final bottomEdge = viewport.bottom - autoScrollEdgeExtent;
    double step = 0;
    if (dy < topEdge) {
      step =
          -autoScrollMaxStep *
          math.min(1, (topEdge - dy) / autoScrollEdgeExtent);
    } else if (dy > bottomEdge) {
      step =
          autoScrollMaxStep *
          math.min(1, (dy - bottomEdge) / autoScrollEdgeExtent);
    }
    if (step == 0) return;
    final position = scrollController.position;
    final next = (position.pixels + step).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if (next == position.pixels) return;
    position.jumpTo(next);
    _updateHover();
  }

  static Rect? _globalRect(BuildContext? context) {
    final box = context?.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  void _register(_ChatFolderDropTargetState target) => _targets.add(target);

  void _unregister(_ChatFolderDropTargetState target) {
    _targets.remove(target);
    if (identical(_hovered, target)) {
      _hovered = null;
      _hoverExpandTimer?.cancel();
      _hoverExpandTimer = null;
    }
  }

  @override
  void dispose() {
    _end(drop: false);
    _disposed = true;
    _position.dispose();
    super.dispose();
  }
}

class _ChatDrag {
  const _ChatDrag({
    required this.pointer,
    required this.conversation,
    required this.currentFolderId,
  });

  final int pointer;
  final Conversation conversation;
  final String? currentFolderId;
}

/// A row a dragged chat can be dropped on.
///
/// [folderId] is the folder the chat moves into, or null for the top-level
/// chats section, which takes the chat out of its folder.
class ChatFolderDropTarget extends StatefulWidget {
  const ChatFolderDropTarget({
    super.key,
    required this.controller,
    required this.folderId,
    required this.child,
    this.enabled = true,
    this.highlight = true,
    this.expandOnHover = false,
    this.highlightPadding = kConversationTileMargin,
  });

  final ChatFolderDragController controller;
  final String? folderId;
  final Widget child;

  /// Whether a chat can be dropped here, for example a writable folder.
  final bool enabled;

  /// Whether this row draws the hover highlight. Rows inside a section can
  /// accept a drop while the section header shows it.
  final bool highlight;

  /// Whether resting on this row expands it, for collapsed folders.
  final bool expandOnHover;

  final EdgeInsets highlightPadding;

  @override
  State<ChatFolderDropTarget> createState() => _ChatFolderDropTargetState();
}

class _ChatFolderDropTargetState extends State<ChatFolderDropTarget> {
  @override
  void initState() {
    super.initState();
    widget.controller._register(this);
  }

  @override
  void didUpdateWidget(covariant ChatFolderDropTarget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller._unregister(this);
      widget.controller._register(this);
    }
  }

  @override
  void dispose() {
    widget.controller._unregister(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.highlight) return widget.child;
    final folderKey = widget.folderId ?? 'top-level';
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, child) {
        final hovered = widget.controller.isHovering(widget.folderId);
        final theme = context.conduitTheme;
        return Stack(
          children: [
            child!,
            if (hovered)
              Positioned.fill(
                child: IgnorePointer(
                  child: Padding(
                    padding: widget.highlightPadding,
                    child: DecoratedBox(
                      key: ValueKey<String>('chat-drop-highlight-$folderKey'),
                      decoration: BoxDecoration(
                        color: theme.navigationSelected.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(AppBorderRadius.md),
                        border: Border.all(
                          color: theme.navigationSelected,
                          width: BorderWidth.medium,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
      child: widget.child,
    );
  }
}

class _ChatDragPreview extends StatelessWidget {
  const _ChatDragPreview({required this.position, required this.title});

  final ValueListenable<Offset> position;
  final String title;

  static const double _width = 220;
  static const double _liftAboveFinger = 56;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final textStyle = AppTypography.sidebarTitleStyle.copyWith(
      color: theme.textPrimary,
      decoration: TextDecoration.none,
    );
    final preview = IgnorePointer(
      child: SizedBox(
        width: _width,
        child: DecoratedBox(
          key: const ValueKey<String>('chat-drag-preview'),
          decoration: BoxDecoration(
            color: theme.surfaceContainer,
            borderRadius: BorderRadius.circular(AppBorderRadius.md),
            boxShadow: theme.popoverShadows,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Spacing.md,
              vertical: Spacing.sm,
            ),
            child: Row(
              children: [
                Icon(
                  PlatformInfo.isIOS
                      ? CupertinoIcons.chat_bubble
                      : Icons.chat_bubble_outline_rounded,
                  size: IconSize.listItem,
                  color: theme.iconSecondary,
                ),
                const SizedBox(width: Spacing.sm),
                Expanded(
                  child: DefaultTextStyle(
                    style: textStyle,
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textStyle,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    return ValueListenableBuilder<Offset>(
      valueListenable: position,
      builder: (context, offset, child) => Positioned(
        left: offset.dx - _width / 2,
        top: offset.dy - _liftAboveFinger,
        child: child!,
      ),
      child: preview,
    );
  }
}
