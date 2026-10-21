import 'dart:async';

import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit_core/database/chat_database_repository.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/folder.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/sync/chat_locks.dart';
import 'package:conduit/core/services/native_sheet_bridge.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/widgets/measure_size.dart';
import 'package:conduit/shared/widgets/themed_dialogs.dart';
import 'package:conduit/shared/widgets/themed_sheets.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:conduit/core/services/haptic_service.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:conduit_core/features/chat/providers/chat_providers.dart'
    as chat;
import 'package:conduit/features/chat/widgets/chat_share_sheet.dart';
import 'package:conduit/features/navigation/widgets/folder_tree_guides.dart';

/// Defines an action for use in Conduit context menus.
class ConduitContextMenuAction {
  final IconData cupertinoIcon;
  final String? sfSymbol;
  final IconData materialIcon;
  final String label;
  final Future<void> Function() onSelected;
  final VoidCallback? onBeforeClose;
  final bool destructive;

  const ConduitContextMenuAction({
    required this.cupertinoIcon,
    this.sfSymbol,
    required this.materialIcon,
    required this.label,
    required this.onSelected,
    this.onBeforeClose,
    this.destructive = false,
  });
}

/// How long a press must stay put on iOS before moving it drags.
///
/// The iOS menu preview starts its 800 ms lift once the press is recognized
/// (after [kPressTimeout]), claims the pointer halfway through, about 500 ms
/// after touch down, and opens the menu at about 900 ms. Moving between this
/// delay and the menu opening drags; moving earlier stays a scroll or a swipe.
const Duration kConduitContextMenuHoldDragDelay = Duration(milliseconds: 600);

/// How long a held press waits, after the long press is recognized, before
/// the menu opens on platforms other than iOS when [ConduitContextMenu.holdDrag]
/// is set. Moving in this window drags; lifting opens the menu at once.
const Duration kConduitContextMenuHeldMenuDelay = Duration(milliseconds: 300);

/// Where a held press turned into a drag.
class ConduitContextMenuDragStartDetails {
  const ConduitContextMenuDragStartDetails({
    required this.pointer,
    required this.globalPosition,
  });

  /// The pointer that is dragging. It stays down; the receiver follows it
  /// until it lifts or is cancelled.
  final int pointer;
  final Offset globalPosition;
}

/// Lets a held press on a [ConduitContextMenu] child turn into a drag.
///
/// A press that moves before the menu claims it is left to scrolling and
/// swipes, as before. A press that stays put opens the menu as before. A press
/// held until the menu claims it and then moved past touch slop, before the
/// menu opens, stops the menu and hands the pointer to [onStart].
///
/// The window closes when the menu opens because opening it pushes a route,
/// and a route push cancels every pointer that is down.
class ConduitContextMenuHoldDrag {
  const ConduitContextMenuHoldDrag({required this.onStart});

  final void Function(ConduitContextMenuDragStartDetails details) onStart;
}

/// A long-press context menu widget with platform-specific presentation.
///
/// The app keeps its own action model so call sites can share haptics and
/// icons while the menu presentation follows the current platform. On iOS we
/// keep the child size stable during preview because stock
/// [CupertinoContextMenu] can assert when the child is laid out by flex-based
/// parents.
class ConduitContextMenu extends StatefulWidget {
  final List<ConduitContextMenuAction> actions;
  final Widget child;
  final WidgetBuilder? topWidgetBuilder;
  final Widget Function(BuildContext context, Widget child)? previewBuilder;
  final bool stabilizePreviewSize;

  /// When set, holding the child and then moving starts a drag instead of
  /// opening the menu. Ignored when there are no [actions].
  final ConduitContextMenuHoldDrag? holdDrag;

  const ConduitContextMenu({
    super.key,
    required this.actions,
    required this.child,
    this.topWidgetBuilder,
    this.previewBuilder,
    this.stabilizePreviewSize = true,
    this.holdDrag,
  });

  @override
  State<ConduitContextMenu> createState() => _ConduitContextMenuState();
}

class _ConduitContextMenuState extends State<ConduitContextMenu> {
  Size? _childSize;

  // Rebuilding the iOS menu under a new key drops its opening preview.
  int _menuGeneration = 0;
  int? _holdPointer;
  Offset? _holdOrigin;
  Timer? _holdTimer;
  bool _menuClaimedHold = false;
  Timer? _heldMenuTimer;

  @override
  void didUpdateWidget(covariant ConduitContextMenu oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.holdDrag == null) _resetHold();
  }

  @override
  void dispose() {
    _holdTimer?.cancel();
    _heldMenuTimer?.cancel();
    super.dispose();
  }

  void _handlePointerDown(PointerDownEvent event) {
    if (_holdPointer != null || event.buttons != kPrimaryButton) return;
    if (widget.holdDrag == null) return;
    _holdPointer = event.pointer;
    _holdOrigin = event.position;
    _menuClaimedHold = false;
    _holdTimer?.cancel();
    // Elsewhere the long press recognizer reports the claim itself.
    _holdTimer = PlatformInfo.isIOS
        ? Timer(kConduitContextMenuHoldDragDelay, () => _menuClaimedHold = true)
        : null;
  }

  void _handlePointerMove(PointerMoveEvent event) {
    final origin = _holdOrigin;
    if (event.pointer != _holdPointer || origin == null) return;
    final slop = computeHitSlop(
      event.kind,
      MediaQuery.maybeGestureSettingsOf(context),
    );
    if ((event.position - origin).distance <= slop) return;
    if (!_menuClaimedHold) {
      // Moving early is a scroll or a swipe; leave it to them.
      _resetHold();
      return;
    }
    final holdDrag = widget.holdDrag;
    _resetHold();
    if (holdDrag == null) return;
    _stopMenu();
    holdDrag.onStart(
      ConduitContextMenuDragStartDetails(
        pointer: event.pointer,
        globalPosition: event.position,
      ),
    );
  }

  void _handlePointerEnd(PointerEvent event) {
    if (event.pointer == _holdPointer) _resetHold();
  }

  void _resetHold() {
    _holdTimer?.cancel();
    _holdTimer = null;
    _holdPointer = null;
    _holdOrigin = null;
    _menuClaimedHold = false;
  }

  /// Keeps the menu this press began from opening.
  void _stopMenu() {
    _heldMenuTimer?.cancel();
    _heldMenuTimer = null;
    if (PlatformInfo.isIOS && mounted) {
      setState(() => _menuGeneration++);
    }
  }

  void _handleHeldLongPressStart(List<AdaptiveContextMenuAction> actions) {
    if (_holdPointer == null) return;
    _menuClaimedHold = true;
    _heldMenuTimer?.cancel();
    _heldMenuTimer = Timer(
      kConduitContextMenuHeldMenuDelay,
      () => _showHeldMenu(actions),
    );
  }

  void _handleHeldLongPressUp(List<AdaptiveContextMenuAction> actions) {
    if (_heldMenuTimer == null) return;
    _showHeldMenu(actions);
  }

  void _showHeldMenu(List<AdaptiveContextMenuAction> actions) {
    _heldMenuTimer?.cancel();
    _heldMenuTimer = null;
    if (!mounted) return;
    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.attached) return;
    final topLeft = renderObject.localToGlobal(Offset.zero);
    final bottomRight = renderObject.localToGlobal(
      renderObject.size.bottomRight(Offset.zero),
    );
    showAdaptiveContextMenu(
      context: context,
      actions: actions,
      globalAnchor: Rect.fromPoints(topLeft, bottomRight),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.actions.isEmpty) {
      return widget.child;
    }
    final menu = _buildMenu(context);
    if (widget.holdDrag == null) {
      return menu;
    }
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _handlePointerDown,
      onPointerMove: _handlePointerMove,
      onPointerUp: _handlePointerEnd,
      onPointerCancel: _handlePointerEnd,
      child: menu,
    );
  }

  Widget _buildMenu(BuildContext context) {
    final adaptiveActions = [
      for (final action in widget.actions)
        AdaptiveContextMenuAction(
          title: action.label,
          icon: action.materialIcon,
          isDestructive: action.destructive,
          onPressed: () {
            ConduitHaptics.selectionClick();
            action.onBeforeClose?.call();
            action.onSelected();
          },
        ),
    ];

    if (PlatformInfo.isIOS) {
      return GestureDetector(
        behavior: HitTestBehavior.translucent,
        onSecondaryTapDown: (details) => showAdaptiveContextMenu(
          context: context,
          actions: adaptiveActions,
          globalAnchor: Rect.fromLTWH(
            details.globalPosition.dx,
            details.globalPosition.dy,
            0,
            0,
          ),
        ),
        child: _buildCupertinoContextMenu(context),
      );
    }

    if (widget.holdDrag != null) {
      // Same menu as [AdaptiveContextMenu], held back briefly so a held press
      // can still become a drag before the menu's route cancels the pointer.
      return GestureDetector(
        onSecondaryTapDown: (details) => showAdaptiveContextMenu(
          context: context,
          actions: adaptiveActions,
          globalAnchor: Rect.fromLTWH(
            details.globalPosition.dx,
            details.globalPosition.dy,
            0,
            0,
          ),
        ),
        onLongPressStart: (_) => _handleHeldLongPressStart(adaptiveActions),
        onLongPressUp: () => _handleHeldLongPressUp(adaptiveActions),
        child: widget.child,
      );
    }

    return AdaptiveContextMenu(actions: adaptiveActions, child: widget.child);
  }

  Widget _buildCupertinoContextMenu(BuildContext context) {
    final contextMenu = CupertinoContextMenu.builder(
      key: ValueKey<int>(_menuGeneration),
      actions: [
        for (final action in widget.actions)
          CupertinoContextMenuAction(
            isDestructiveAction: action.destructive,
            trailingIcon: action.cupertinoIcon,
            onPressed: () {
              Navigator.of(context, rootNavigator: true).pop();
              Future.microtask(() {
                ConduitHaptics.selectionClick();
                action.onBeforeClose?.call();
                action.onSelected();
              });
            },
            child: Text(action.label),
          ),
      ],
      builder: (context, animation) {
        final previewChild = IgnorePointer(
          ignoring: animation.value > 0,
          child: widget.child,
        );
        final size = widget.stabilizePreviewSize ? _childSize : null;
        Widget preview = previewChild;
        if (animation.value > 0 && size != null) {
          preview = SizedBox(
            width: size.width,
            height: size.height,
            child: previewChild,
          );
        }

        final previewBuilder = widget.previewBuilder;
        if (animation.value > 0 && previewBuilder != null) {
          preview = previewBuilder(context, preview);
        }

        final topWidgetBuilder = widget.topWidgetBuilder;
        if (animation.value > 0 && topWidgetBuilder != null) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              topWidgetBuilder(context),
              const SizedBox(height: Spacing.sm),
              preview,
            ],
          );
        }

        return preview;
      },
    );

    if (!widget.stabilizePreviewSize) {
      return contextMenu;
    }

    return MeasureSize(onChange: _handleChildSizeChanged, child: contextMenu);
  }

  void _handleChildSizeChanged(Size size) {
    if (!size.width.isFinite ||
        !size.height.isFinite ||
        size.width <= 0 ||
        size.height <= 0 ||
        _childSize == size) {
      return;
    }
    _childSize = size;
  }
}

/// Builds a list of actions for conversation context menus.
///
/// Use with [ConduitContextMenu]:
/// ```dart
/// ConduitContextMenu(
///   actions: buildConversationActions(context: context, ref: ref, conversation: conv),
///   child: MyWidget(),
/// )
/// ```
List<ConduitContextMenuAction> buildConversationActions({
  required BuildContext context,
  required WidgetRef ref,
  required dynamic conversation,
}) {
  final foldersEnabled = ref.watch(foldersAvailableProvider);
  final folders = foldersEnabled
      ? ref
            .watch(foldersProvider)
            .maybeWhen(
              data: (folders) => folders,
              orElse: () => const <Folder>[],
            )
      : const <Folder>[];

  return buildConversationActionsWithFolders(
    context: context,
    ref: ref,
    conversation: conversation,
    foldersEnabled: foldersEnabled,
    folders: folders,
  );
}

List<ConduitContextMenuAction> buildConversationActionsWithFolders({
  required BuildContext context,
  required WidgetRef ref,
  required dynamic conversation,
  required bool foldersEnabled,
  required List<Folder> folders,
  VoidCallback? onSelect,
}) {
  if (conversation == null) {
    return [];
  }

  final l10n = AppLocalizations.of(context)!;
  final bool isPinned = conversation.pinned == true;
  final bool isArchived = conversation.archived == true;
  final bool isOnDevice = isDirectLocalConversation(conversation);
  final selectionId = conversationScopedId(conversation);
  final currentFolderId = _conversationFolderId(conversation);
  final canMove =
      !isOnDevice &&
      foldersEnabled &&
      (folders.any((folder) => folder.id != currentFolderId) ||
          currentFolderId != null);

  Future<void> togglePin() async {
    final errorMessage = l10n.failedToUpdatePin;
    try {
      await chat.pinConversation(ref, selectionId, !isPinned);
    } catch (_) {
      if (!context.mounted) return;
      await _showConversationError(context, errorMessage);
    }
  }

  Future<void> toggleArchive() async {
    final errorMessage = l10n.failedToUpdateArchive;
    try {
      await chat.archiveConversation(ref, selectionId, !isArchived);
    } catch (_) {
      if (!context.mounted) return;
      await _showConversationError(context, errorMessage);
    }
  }

  Future<void> rename() async {
    await _renameConversation(
      context,
      ref,
      selectionId,
      conversation.title ?? '',
      isOnDevice: isOnDevice,
    );
  }

  Future<void> deleteConversation() async {
    await _confirmAndDeleteConversation(
      context,
      ref,
      conversation,
      isOnDevice: isOnDevice,
    );
  }

  Future<void> shareConversation() async {
    if (!context.mounted) return;
    await showChatShareSheet(context: context, conversation: conversation);
  }

  Future<void> moveConversation() async {
    await _moveConversation(
      context,
      ref,
      selectionId,
      currentFolderId: currentFolderId,
      folders: folders,
    );
  }

  return [
    ConduitContextMenuAction(
      cupertinoIcon: isPinned
          ? CupertinoIcons.pin_slash
          : CupertinoIcons.pin_fill,
      sfSymbol: isPinned ? 'pin.slash' : 'pin.fill',
      materialIcon: isPinned ? Icons.push_pin_outlined : Icons.push_pin_rounded,
      label: isPinned ? l10n.unpin : l10n.pin,
      onBeforeClose: () => ConduitHaptics.lightImpact(),
      onSelected: togglePin,
    ),
    ConduitContextMenuAction(
      cupertinoIcon: isArchived
          ? CupertinoIcons.archivebox_fill
          : CupertinoIcons.archivebox,
      sfSymbol: isArchived ? 'archivebox.fill' : 'archivebox',
      materialIcon: isArchived
          ? Icons.unarchive_rounded
          : Icons.archive_rounded,
      label: isArchived ? l10n.unarchive : l10n.archive,
      onBeforeClose: () => ConduitHaptics.lightImpact(),
      onSelected: toggleArchive,
    ),
    if (!isOnDevice)
      ConduitContextMenuAction(
        cupertinoIcon: CupertinoIcons.share,
        sfSymbol: 'square.and.arrow.up',
        materialIcon: Icons.ios_share_rounded,
        label: l10n.shareChat,
        onBeforeClose: () => ConduitHaptics.selectionClick(),
        onSelected: shareConversation,
      ),
    ConduitContextMenuAction(
      cupertinoIcon: CupertinoIcons.pencil,
      sfSymbol: 'pencil',
      materialIcon: Icons.edit_rounded,
      label: l10n.rename,
      onBeforeClose: () => ConduitHaptics.selectionClick(),
      onSelected: rename,
    ),
    if (canMove)
      ConduitContextMenuAction(
        cupertinoIcon: CupertinoIcons.folder,
        sfSymbol: 'folder',
        materialIcon: Icons.drive_file_move_outline,
        label: l10n.move,
        onBeforeClose: () => ConduitHaptics.selectionClick(),
        onSelected: moveConversation,
      ),
    if (onSelect != null)
      ConduitContextMenuAction(
        cupertinoIcon: CupertinoIcons.check_mark_circled,
        sfSymbol: 'checkmark.circle',
        materialIcon: Icons.check_circle_outline_rounded,
        label: l10n.selectChats,
        onBeforeClose: () => ConduitHaptics.selectionClick(),
        onSelected: () async => onSelect(),
      ),
    ConduitContextMenuAction(
      cupertinoIcon: CupertinoIcons.delete,
      sfSymbol: 'trash',
      materialIcon: Icons.delete_rounded,
      label: l10n.delete,
      destructive: true,
      onBeforeClose: () => ConduitHaptics.mediumImpact(),
      onSelected: deleteConversation,
    ),
  ];
}

String? _conversationFolderId(dynamic conversation) {
  try {
    final value = conversation.folderId;
    if (value is String && value.isNotEmpty) {
      return value;
    }
  } catch (_) {}
  return null;
}

/// A folder picked to move chats into; [folderId] is null for no folder.
class ConversationMoveTarget {
  const ConversationMoveTarget({required this.folderId});

  final String? folderId;
}

Future<void> _moveConversation(
  BuildContext context,
  WidgetRef ref,
  String conversationId, {
  required String? currentFolderId,
  required List<Folder> folders,
}) async {
  final target = await _showConversationMoveSheet(
    context,
    folders: folders,
    currentFolderId: currentFolderId,
  );
  if (!context.mounted || target == null) return;
  await moveConversationToFolder(
    context,
    ref,
    conversationId,
    currentFolderId: currentFolderId,
    targetFolderId: target.folderId,
  );
}

/// Moves the chat with scoped id [conversationId] into [targetFolderId], or
/// out of any folder when it is null, and updates the cached chats.
///
/// The "Move" menu action and dragging a chat onto a folder both land here.
/// Returns false when the move failed; the failure is shown in a dialog
/// unless [reportErrors] is false, so a caller moving several chats can
/// report them together.
Future<bool> moveConversationToFolder(
  BuildContext context,
  WidgetRef ref,
  String conversationId, {
  required String? currentFolderId,
  required String? targetFolderId,
  bool reportErrors = true,
}) async {
  if (targetFolderId == currentFolderId) return true;
  final rawConversationId = ChatStorageIdentity.parse(conversationId).rawId;

  final l10n = AppLocalizations.of(context)!;
  try {
    final api = ref.read(apiServiceProvider);
    if (api == null) throw Exception('No API service');
    await api.moveConversationToFolder(rawConversationId, targetFolderId);
    if (!context.mounted) return true;

    ConduitHaptics.selectionClick();
    ref
        .read(conversationsProvider.notifier)
        .updateConversation(
          conversationId,
          (conversation) => conversation.copyWith(
            folderId: targetFolderId,
            updatedAt: DateTime.now(),
          ),
          trustFolderConversation:
              targetFolderId != null && targetFolderId.isNotEmpty,
        );

    final activeConversation = ref.read(activeConversationProvider);
    if (activeConversation != null &&
        conversationMatchesScopedId(activeConversation, conversationId)) {
      ref
          .read(activeConversationProvider.notifier)
          .set(
            activeConversation.copyWith(
              folderId: targetFolderId,
              updatedAt: DateTime.now(),
            ),
          );
    }
    refreshConversationsCache(ref, includeFolders: true);
    return true;
  } catch (_) {
    if (reportErrors && context.mounted) {
      await _showConversationError(context, l10n.failedToMoveChat);
    }
    return false;
  }
}

/// Shows the "Move to folder" picker the Move action uses, for moving one or
/// more chats. [currentFolderId] is left out of the list; "No folder" is
/// offered when [offerNoFolder] is true, by default when the chats are in a
/// folder. Returns null when the picker is dismissed.
Future<ConversationMoveTarget?> showConversationMoveTargetPicker(
  BuildContext context, {
  required List<Folder> folders,
  required String? currentFolderId,
  bool? offerNoFolder,
}) => _showConversationMoveSheet(
  context,
  folders: folders,
  currentFolderId: currentFolderId,
  offerNoFolder: offerNoFolder ?? currentFolderId != null,
);

Future<ConversationMoveTarget?> _showConversationMoveSheet(
  BuildContext context, {
  required List<Folder> folders,
  required String? currentFolderId,
  bool? offerNoFolder,
}) async {
  final showNoFolder = offerNoFolder ?? currentFolderId != null;
  final l10n = AppLocalizations.of(context)!;
  // A shared folder is a valid destination only with a write grant.
  final treeEntries = folderTreeEntriesForTargets(
    folders: folders.where((folder) => folder.canWrite).toList(),
    omitFolderId: currentFolderId,
  );

  if (Theme.of(context).platform == TargetPlatform.iOS) {
    const noFolderId = '__no_folder__';
    try {
      final selectedId = await NativeSheetBridge.instance
          .presentOptionsSelector(
            title: l10n.moveToFolder,
            options: [
              if (showNoFolder)
                NativeSheetOptionConfig(
                  id: noFolderId,
                  label: l10n.noFolder,
                  sfSymbol: 'folder.badge.minus',
                ),
              for (final entry in treeEntries)
                NativeSheetOptionConfig(
                  id: entry.folder.id,
                  label: entry.folder.name,
                  sfSymbol: 'folder',
                  ancestorHasMoreSiblings: entry.ancestorHasMoreSiblings,
                  showBranch: true,
                  hasMoreSiblings: entry.hasMoreSiblings,
                ),
            ],
            rethrowErrors: true,
          );
      if (selectedId == null) {
        return null;
      }
      if (selectedId == noFolderId) {
        return const ConversationMoveTarget(folderId: null);
      }
      return ConversationMoveTarget(folderId: selectedId);
    } catch (_) {
      if (!context.mounted) {
        return null;
      }
    }
  }

  if (!context.mounted) {
    return null;
  }

  return ThemedSheets.showSurface<ConversationMoveTarget>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) {
      final theme = sheetContext.conduitTheme;
      final maxListHeight = MediaQuery.sizeOf(sheetContext).height * 0.62;

      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.moveToFolder,
            style: AppTypography.headlineSmallStyle.copyWith(
              color: theme.textPrimary,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: Spacing.md),
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxListHeight),
            child: ListView(
              shrinkWrap: true,
              physics: const ClampingScrollPhysics(),
              padding: EdgeInsets.zero,
              children: [
                if (showNoFolder)
                  _MoveTargetTile(
                    icon: PlatformInfo.isIOS
                        ? CupertinoIcons.folder_badge_minus
                        : Icons.folder_off_outlined,
                    label: l10n.noFolder,
                    onTap: () =>
                        Navigator.of(sheetContext)
                            .pop(const ConversationMoveTarget(folderId: null)),
                  ),
                for (final entry in treeEntries)
                  FolderTreeHierarchyNode(
                    key: ValueKey<String>('move-chat-tree-${entry.folder.id}'),
                    ancestorHasMoreSiblings: entry.ancestorHasMoreSiblings,
                    showBranch: true,
                    hasMoreSiblings: entry.hasMoreSiblings,
                    child: _MoveTargetTile(
                      icon: PlatformInfo.isIOS
                          ? CupertinoIcons.folder
                          : Icons.folder_outlined,
                      label: entry.folder.name,
                      onTap: () => Navigator.of(
                        sheetContext,
                      ).pop(ConversationMoveTarget(folderId: entry.folder.id)),
                    ),
                  ),
              ],
            ),
          ),
        ],
      );
    },
  );
}

class _MoveTargetTile extends StatelessWidget {
  const _MoveTargetTile({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: TouchTarget.listItem),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Spacing.sm,
            vertical: Spacing.sm,
          ),
          child: Row(
            children: [
              Icon(icon, color: theme.iconPrimary, size: IconSize.listItem),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.sidebarTitleStyle.copyWith(
                    color: theme.textPrimary,
                    fontWeight: FontWeight.w400,
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

Future<void> _renameConversation(
  BuildContext context,
  WidgetRef ref,
  String conversationId,
  String currentTitle, {
  required bool isOnDevice,
}) async {
  final rawConversationId = ChatStorageIdentity.parse(conversationId).rawId;
  final l10n = AppLocalizations.of(context)!;
  final newName = await ThemedDialogs.promptTextInput(
    context,
    title: l10n.renameChat,
    hintText: l10n.enterChatName,
    initialValue: currentTitle,
    confirmText: l10n.save,
    cancelText: l10n.cancel,
  );

  if (!context.mounted) return;
  if (newName == null) return;
  if (newName.isEmpty || newName == currentTitle) return;

  final renameError = l10n.failedToRenameChat;
  try {
    if (isOnDevice) {
      await chat.renameDirectLocalConversation(ref, conversationId, newName);
      ConduitHaptics.selectionClick();
      return;
    }
    final api = ref.read(apiServiceProvider);
    if (api == null) throw Exception('No API service');
    // A title being generated for this chat waits for the rename, and keeps
    // it.
    await ref
        .read(chatTitleLocksProvider)
        .runExclusive(
          rawConversationId,
          () => api.updateConversation(rawConversationId, title: newName),
        );
    ConduitHaptics.selectionClick();
    ref
        .read(conversationsProvider.notifier)
        .updateConversationFromRemote(
          conversationId,
          (conversation) =>
              conversation.copyWith(title: newName, updatedAt: DateTime.now()),
        );
    refreshConversationsCache(ref);
    final active = ref.read(activeConversationProvider);
    if (active != null && conversationMatchesScopedId(active, conversationId)) {
      ref
          .read(activeConversationProvider.notifier)
          .set(active.copyWith(title: newName));
    }
  } catch (_) {
    if (!context.mounted) return;
    await _showConversationError(context, renameError);
  }
}

Future<void> _confirmAndDeleteConversation(
  BuildContext context,
  WidgetRef ref,
  Conversation conversation, {
  required bool isOnDevice,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final confirmed = await ThemedDialogs.confirm(
    context,
    title: l10n.deleteChatTitle,
    message: l10n.deleteChatMessage,
    confirmText: l10n.delete,
    isDestructive: true,
  );

  if (!context.mounted) return;
  if (!confirmed) return;

  await deleteConversationNow(
    context,
    ref,
    conversation,
    isOnDevice: isOnDevice,
  );
}

/// Deletes [conversation] without asking, on the server or on the device,
/// and clears it from the open chat and the cached list.
///
/// The menu's Delete action lands here after its confirmation; a swipe lands
/// here once its Undo window has passed. Returns false when the delete
/// failed; the failure is shown in a dialog unless [reportErrors] is false,
/// so a caller deleting several chats can report them together.
Future<bool> deleteConversationNow(
  BuildContext context,
  WidgetRef ref,
  Conversation conversation, {
  bool? isOnDevice,
  bool reportErrors = true,
}) async {
  final conversationId = conversationScopedId(conversation);
  final rawConversationId = ChatStorageIdentity.parse(conversationId).rawId;
  final l10n = AppLocalizations.of(context)!;
  isOnDevice ??= isDirectLocalConversation(conversation);
  final deleteError = l10n.failedToDeleteChat;
  try {
    if (isOnDevice) {
      await chat.deleteDirectLocalConversation(ref, conversationId);
    } else {
      final api = ref.read(apiServiceProvider);
      if (api == null) throw Exception('No API service');
      // Revoke first: a thrown DELETE can still mean the server committed and
      // only its response was lost. A crash must not leave replayable proof for
      // a remotely deleted conversation. Do not restore proof based on an HTTP
      // status: 404 already means the chat is absent, while an auth-looking
      // response may come from an intermediary after an ambiguous upstream
      // outcome. Losing safe continuity is preferable to authorizing replay
      // against a deleted or later-reused conversation id.
      await chat.forgetMixedHermesConversationProvenance(
        ref,
        conversation: conversation,
      );
      await api.deleteConversation(rawConversationId);
      ref
          .read(conversationsProvider.notifier)
          .removeConversation(conversationId);
    }
    ConduitHaptics.mediumImpact();
    final active = ref.read(activeConversationProvider);
    if (active != null && conversationMatchesScopedId(active, conversationId)) {
      chat.clearSelectedFiltersForConversationBoundary(ref);
      ref.read(activeConversationProvider.notifier).clear();
      ref.read(chat.chatMessagesProvider.notifier).clearMessages();
      // Reset to default model for new conversations (fixes #296)
      chat.restoreDefaultModel(ref);
    }
    refreshConversationsCache(ref);
    return true;
  } catch (_) {
    if (reportErrors && context.mounted) {
      await _showConversationError(context, deleteError);
    }
    return false;
  }
}

/// Shows [message] in the error dialog the chat actions use.
Future<void> showConversationErrorDialog(
  BuildContext context,
  String message,
) => _showConversationError(context, message);

Future<void> _showConversationError(
  BuildContext context,
  String message,
) async {
  if (!context.mounted) return;
  final l10n = AppLocalizations.of(context)!;
  final theme = context.conduitTheme;
  await ThemedDialogs.show<void>(
    context,
    title: l10n.errorMessage,
    content: Text(
      message,
      style: AppTypography.bodyMediumStyle.copyWith(color: theme.textSecondary),
    ),
    actions: [
      AdaptiveButton(
        onPressed: () => Navigator.of(context).pop(),
        label: l10n.ok,
        style: AdaptiveButtonStyle.plain,
      ),
    ],
  );
}
