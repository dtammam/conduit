import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit_core/features/automations/providers/automation_providers.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'assistant_action_log.dart';
import 'assistant_pending_approval.dart';

/// The pill of icon buttons under the Omni chat's composer: the chat itself
/// (always the selected page) and, one tap away, the assistant's Activity,
/// Approvals, Routines and Appearance pages. It is hidden while the keyboard
/// is up.
class OmniTabBar extends ConsumerWidget {
  const OmniTabBar({
    super.key,
    required this.onOpen,
    this.keyboardVisible = false,
  });

  /// Whether the keyboard is up. The caller reads it above the page's
  /// scaffold, which removes the keyboard inset from its body.
  final bool keyboardVisible;

  /// Opens the page for [tab] over the chat.
  final void Function(AssistantSheetTab tab) onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (keyboardVisible) {
      return const SizedBox.shrink(key: ValueKey('omni-tab-bar-hidden'));
    }
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    // The same rule as the assistant sheet: Routines show when the account
    // has scheduled tasks or a routines server is set.
    final routinesAvailable =
        ref.watch(automationsAvailableProvider) ||
        ref.watch(
          appSettingsProvider.select((s) => s.routinesServerUrl.isNotEmpty),
        );
    final pendingApproval = ref.watch(assistantApprovalProvider) != null;
    final failures = ref.watch(
      assistantActionLogProvider.select((log) => log.unseenFailures),
    );
    return Padding(
      padding: const EdgeInsets.only(top: Spacing.xs, bottom: Spacing.sm),
      child: Center(
        child: Container(
          key: const ValueKey('omni-tab-bar'),
          padding: const EdgeInsets.symmetric(horizontal: Spacing.xs),
          decoration: BoxDecoration(
            color: theme.surfaceContainer,
            borderRadius: BorderRadius.circular(AppBorderRadius.round),
            border: Border.all(
              color: theme.cardBorder,
              width: BorderWidth.thin,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _TabButton(
                id: 'chat',
                symbol: 'bubble.left',
                selectedSymbol: 'bubble.left.fill',
                label: l10n.omniTabChat,
                selected: true,
              ),
              _TabButton(
                id: 'activity',
                symbol: 'list.bullet.rectangle',
                label: l10n.assistantSheetTabActivity,
                badge: failures,
                badgeColor: theme.error,
                onTap: () => onOpen(AssistantSheetTab.activity),
              ),
              _TabButton(
                id: 'approvals',
                symbol: 'checkmark.seal',
                label: l10n.assistantSheetTabApprovals,
                badge: pendingApproval ? 1 : 0,
                badgeColor: theme.warning,
                onTap: () => onOpen(AssistantSheetTab.approvals),
              ),
              if (routinesAvailable)
                _TabButton(
                  id: 'routines',
                  symbol: 'alarm',
                  label: l10n.assistantSheetTabRoutines,
                  onTap: () => onOpen(AssistantSheetTab.routines),
                ),
              _TabButton(
                id: 'appearance',
                symbol: 'paintpalette',
                label: l10n.assistantSheetTabAppearance,
                onTap: () => onOpen(AssistantSheetTab.appearance),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TabButton extends StatelessWidget {
  const _TabButton({
    required this.id,
    required this.symbol,
    required this.label,
    this.selectedSymbol,
    this.selected = false,
    this.onTap,
    this.badge = 0,
    this.badgeColor,
  });

  final String id;
  final String symbol;
  final String? selectedSymbol;
  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final int badge;
  final Color? badgeColor;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final icon = cupertinoIconForSFSymbol(
      selected ? (selectedSymbol ?? symbol) : symbol,
    );
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      excludeSemantics: true,
      onTap: onTap,
      child: GestureDetector(
        key: ValueKey('omni-tab-$id'),
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          width: 52,
          height: 44,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Icon(
                icon,
                size: IconSize.lg,
                color: selected ? theme.buttonPrimary : theme.iconSecondary,
              ),
              if (badge > 0)
                Positioned(
                  top: 6,
                  right: 8,
                  child: Container(
                    key: ValueKey('omni-tab-badge-$id'),
                    width: 9,
                    height: 9,
                    decoration: BoxDecoration(
                      color: badgeColor,
                      shape: BoxShape.circle,
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
