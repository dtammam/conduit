import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:flutter/widgets.dart';

import '../../../shared/theme/theme_extensions.dart';
import 'conversation_tile.dart';

/// The Omni chat's row, pinned above everything else in the chats drawer.
///
/// It has no swipe or menu: the chat is turned off with the Omni chat
/// setting, not deleted from here.
class OmniChatRow extends StatelessWidget {
  const OmniChatRow({
    super.key,
    required this.title,
    required this.selected,
    required this.onTap,
    this.isLoading = false,
  });

  final String title;
  final bool selected;
  final bool isLoading;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    return ChatStyleSidebarTile(
      selected: selected,
      enabled: !isLoading,
      onTap: onTap,
      semanticLabel: title,
      tintKey: const ValueKey<String>('omni-chat-row-active-tint'),
      child: SidebarListTileContent(
        title: title,
        selected: selected,
        emphasizeTitle: true,
        leading: Icon(
          cupertinoIconForSFSymbol('infinity'),
          color: theme.buttonPrimary,
          size: IconSize.listItem,
        ),
        trailing: isLoading
            ? SizedBox(
                width: IconSize.sm,
                height: IconSize.sm,
                child: AdaptiveProgressIndicator.activity(
                  radius: IconSize.sm / 2,
                  color: theme.loadingIndicator,
                ),
              )
            : null,
      ),
    );
  }
}
