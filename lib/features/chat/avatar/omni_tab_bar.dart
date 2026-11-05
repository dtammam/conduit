import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/utils/adaptive_glass.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit_core/features/automations/providers/automation_providers.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart' show Brightness, Theme, Tooltip;

import 'assistant_action_log.dart';
import 'assistant_pending_approval.dart';

/// The glass capsule of icon buttons under the Omni chat's composer (and on the
/// assistant pages), laid out like Muse's: one tap away, the assistant's
/// Activity, Approvals, Routines and Appearance pages. The names are only
/// semantics labels and tooltips. On a page, [selected] sits on a dark pill.
/// It is hidden while the keyboard is up.
class OmniTabBar extends ConsumerWidget {
  const OmniTabBar({
    super.key,
    required this.onOpen,
    this.keyboardVisible = false,
    this.keyboardProgress,
    this.selected,
  });

  /// The page showing now, drawn on a pill; none in the chat itself.
  final AssistantSheetTab? selected;

  /// Whether the keyboard is up. The caller reads it above the page's
  /// scaffold, which removes the keyboard inset from its body.
  final bool keyboardVisible;

  /// How far the keyboard is up, 0 (down) to 1 (fully up): the caller
  /// divides the keyboard's own inset by its full height each frame, so the
  /// bar gives its room back as the keyboard rises and takes it again as it
  /// falls, in step with the keyboard and with no jump in the composer. When
  /// null, [keyboardVisible] decides: 1 when up, else 0.
  final double? keyboardProgress;

  /// Opens the page for [tab] over the chat.
  final void Function(AssistantSheetTab tab) onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final progress = (keyboardProgress ?? (keyboardVisible ? 1.0 : 0.0)).clamp(
      0.0,
      1.0,
    );
    if (progress >= 1) {
      return const SizedBox(
        key: ValueKey('omni-tab-bar-hidden'),
        height: _gapAboveKeyboard,
      );
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
        selected: selected == AssistantSheetTab.activity,
        symbol: 'list.bullet.rectangle',
        label: l10n.assistantSheetTabActivity,
        badge: failures,
        badgeColor: theme.error,
        onTap: () => onOpen(AssistantSheetTab.activity),
      ),
      _TabButton(
        id: 'approvals',
        selected: selected == AssistantSheetTab.approvals,
        symbol: 'checkmark.seal',
        label: l10n.assistantSheetTabApprovals,
        badge: pendingApproval ? 1 : 0,
        badgeColor: theme.warning,
        onTap: () => onOpen(AssistantSheetTab.approvals),
      ),
      if (routinesAvailable)
        _TabButton(
          id: 'routines',
          selected: selected == AssistantSheetTab.routines,
          symbol: 'alarm',
          label: l10n.assistantSheetTabRoutines,
          onTap: () => onOpen(AssistantSheetTab.routines),
        ),
      _TabButton(
        id: 'appearance',
        selected: selected == AssistantSheetTab.appearance,
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
    final bar = Padding(
      padding: const EdgeInsets.fromLTRB(
        _sideMargin,
        _gapBelowComposer,
        _sideMargin,
        _gapAboveBottomEdge,
      ),
      child: capsule,
    );
    if (progress <= 0) return bar;
    // Part way: the bar's room shrinks to the composer's own gap above the
    // keyboard as the keyboard comes up, and it fades out.
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRect(
          child: Align(
            alignment: Alignment.bottomCenter,
            heightFactor: 1 - progress,
            child: IgnorePointer(
              ignoring: progress > 0.5,
              child: Opacity(opacity: 1 - progress, child: bar),
            ),
          ),
        ),
        SizedBox(height: _gapAboveKeyboard * progress),
      ],
    );
  }
}

const double _capsuleInset = 4;

/// Muse's measures, in points: 60 tall, 21 from the sides, 11 under the
/// composer and 22 from the bottom edge of the screen (above the home
/// indicator, which the bar overlaps).
const double _capsuleHeight = 60;
const double _sideMargin = 21;
const double _gapBelowComposer = 10;
const double _gapAboveBottomEdge = 22;

/// The composer's gap above the keyboard once the bar is gone.
const double _gapAboveKeyboard = Spacing.sm;

class _TabButton extends StatelessWidget {
  const _TabButton({
    required this.id,
    required this.symbol,
    required this.label,
    this.onTap,
    this.selected = false,
    this.badge = 0,
    this.badgeColor,
  });

  final String id;
  final String symbol;
  final String label;
  final VoidCallback? onTap;
  final bool selected;
  final int badge;
  final Color? badgeColor;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      excludeSemantics: true,
      onTap: onTap,
      child: Tooltip(
        message: label,
        child: GestureDetector(
          key: ValueKey('omni-tab-$id'),
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Center(
            child: Stack(
              alignment: Alignment.center,
              children: [
                // The dark pill behind the selected icon, as in Muse.
                Container(
                  key: selected ? ValueKey('omni-tab-selected-$id') : null,
                  height: _capsuleHeight - 2 * _capsuleInset,
                  constraints: const BoxConstraints(minWidth: 56),
                  decoration: BoxDecoration(
                    color: selected
                        ? theme.textPrimary.withValues(alpha: 0.12)
                        : null,
                    borderRadius: BorderRadius.circular(
                      (_capsuleHeight - 2 * _capsuleInset) / 2,
                    ),
                  ),
                  alignment: Alignment.center,
                  child: Icon(
                    cupertinoIconForSFSymbol(symbol),
                    size: IconSize.lg,
                    color: selected ? theme.textPrimary : theme.iconSecondary,
                  ),
                ),
                if (badge > 0)
                  Positioned(
                    top: 8,
                    right: 12,
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
      ),
    );
  }
}
