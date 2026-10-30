import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/utils/adaptive_glass.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit_core/features/automations/providers/automation_providers.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart' show Brightness, Theme;

import 'assistant_action_log.dart';
import 'assistant_pending_approval.dart';

/// The glass capsule of labelled buttons under the Omni chat's composer: one
/// tap away, the assistant's Activity, Approvals, Routines and Appearance
/// pages, each with its glyph over a one-word label. The chat itself needs no
/// button, since the bar only shows there. It is hidden while the keyboard is
/// up.
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
    final pills = [
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
    ];
    // The capsule is drawn like the composer's shell: native glass where iOS
    // supports it (the same backdrop widget), the themed opaque surface and
    // hairline border elsewhere, and the composer's soft shadow in light mode.
    const radius = BorderRadius.all(Radius.circular(_capsuleHeight / 2));
    final nativeGlass = conduitSupportsNativeGlass();
    final isLight = Theme.of(context).brightness == Brightness.light;
    Widget capsule = SizedBox(
      key: const ValueKey('omni-tab-bar'),
      height: _capsuleHeight,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (nativeGlass)
            const Positioned.fill(
              child: IgnorePointer(
                child: AdaptiveGlassBackdrop(
                  key: ValueKey('omni-tab-bar-glass'),
                  borderRadius: radius,
                ),
              ),
            )
          else
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: theme.surfaceContainerHighest,
                    borderRadius: radius,
                    border: Border.all(
                      color: theme.cardBorder,
                      width: BorderWidth.thin,
                    ),
                  ),
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(_capsuleInset),
            child: Row(
              children: [for (final pill in pills) Expanded(child: pill)],
            ),
          ),
        ],
      ),
    );
    if (isLight) {
      capsule = DecoratedBox(
        decoration: const BoxDecoration(
          borderRadius: radius,
          boxShadow: [
            BoxShadow(
              color: Color(0x18000000),
              blurRadius: 16,
              spreadRadius: -2,
              offset: Offset(0, 4),
            ),
            BoxShadow(
              color: Color(0x0A000000),
              blurRadius: 4,
              spreadRadius: 0,
              offset: Offset(0, 1),
            ),
          ],
        ),
        child: capsule,
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Spacing.screenPadding,
        Spacing.xs,
        Spacing.screenPadding,
        Spacing.sm,
      ),
      child: capsule,
    );
  }
}

const double _capsuleInset = 4;
const double _capsuleHeight = 64 + 2 * _capsuleInset;

class _TabButton extends StatelessWidget {
  const _TabButton({
    required this.id,
    required this.symbol,
    required this.label,
    this.onTap,
    this.badge = 0,
    this.badgeColor,
  });

  final String id;
  final String symbol;
  final String label;
  final VoidCallback? onTap;
  final int badge;
  final Color? badgeColor;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      onTap: onTap,
      child: GestureDetector(
        key: ValueKey('omni-tab-$id'),
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  cupertinoIconForSFSymbol(symbol),
                  size: IconSize.lg,
                  color: theme.iconSecondary,
                ),
                const SizedBox(height: Spacing.xxs),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Spacing.xs),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      label,
                      maxLines: 1,
                      style: AppTypography.captionStyle.copyWith(
                        color: theme.textSecondary,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            if (badge > 0)
              Align(
                alignment: const Alignment(0.38, -0.78),
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
    );
  }
}
