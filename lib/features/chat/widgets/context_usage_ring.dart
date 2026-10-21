import 'dart:math' as math;

import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/utils/adaptive_glass.dart';
import 'package:conduit/shared/widgets/adaptive_selection_sheet.dart';
import 'package:conduit/shared/widgets/adaptive_toolbar_components.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit/shared/widgets/themed_sheets.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../providers/context_usage_providers.dart';

/// Diameter of the ring beside the context sheet's title.
const double kContextUsageRingDiameter = 21;

/// Diameter of the ring glyph inside its circular toolbar button: the extent
/// of the SF Symbols in the neighboring glass buttons, so it reads as an icon.
const double kContextUsageRingButtonDiameter =
    kConduitNativeSingleActionSymbolExtent;
const double _kContextUsageRingStroke = 2.25;

/// Context windows offered from the sheet's Edit picker.
const List<int> kContextWindowOptions = <int>[
  4 * 1024,
  8 * 1024,
  16 * 1024,
  32 * 1024,
  64 * 1024,
  128 * 1024,
  256 * 1024,
  512 * 1024,
  1024 * 1024,
];

String _formatPercent(BuildContext context, double fraction) =>
    NumberFormat.percentPattern(Localizations.localeOf(context).toLanguageTag())
        .format(fraction);

Color contextUsageTint(ConduitThemeExtension theme, ContextUsageLevel level) =>
    switch (level) {
      ContextUsageLevel.normal => theme.textSecondary,
      ContextUsageLevel.warning => theme.warning,
      ContextUsageLevel.critical => theme.error,
    };

/// The chat app bar's context meter: hidden until the conversation has
/// something to count, then a ring that fills with the share of the model's
/// context window in use. With no known window the ring stays empty with a
/// question mark, and the sheet offers to set one. It sits on the bar's
/// leading side, right after the menu button.
class ContextUsageRingButton extends ConsumerWidget {
  const ContextUsageRingButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final usage = ref.watch(chatContextUsageProvider);
    if (usage == null) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context)!;
    final fraction = usage.fraction;
    final label = fraction == null
        ? l10n.contextUsageRingUnknownLabel
        : l10n.contextUsageRingLabel(_formatPercent(context, fraction));
    final controlExtent = conduitScaledControlExtent(context);
    void open() => showContextUsageSheet(context);
    final ring = ContextUsageRing(
      fraction: fraction,
      diameter: kContextUsageRingButtonDiameter,
    );

    // The same circle as the menu and trailing toolbar buttons. Their native
    // glass buttons can only hold an SF Symbol, so the ring sits on the
    // toolbar's shared glass surface for Flutter content instead: the same
    // system Liquid Glass, diameter, hit target and hiding under sheets.
    // Without native glass it is the opaque circle the icon buttons use.
    final Widget button = conduitUsesOpaqueGlassFallback()
        ? SizedBox.square(
            dimension: controlExtent,
            child: FloatingAppBarButton(
              onTap: open,
              isCircular: true,
              child: ring,
            ),
          )
        : buildConduitAdaptiveToolbarPillSurface(
            width: controlExtent,
            height: controlExtent,
            onPressed: open,
            child: Center(child: ring),
          );
    return Semantics(
      key: const ValueKey('chat-context-usage-ring'),
      label: label,
      button: true,
      excludeSemantics: true,
      onTap: open,
      child: button,
    );
  }
}

/// The ring glyph alone: a thin track and an arc for [fraction], or an empty
/// track with a question mark when [fraction] is null.
class ContextUsageRing extends StatelessWidget {
  const ContextUsageRing({
    super.key,
    required this.fraction,
    this.diameter = kContextUsageRingDiameter,
  });

  final double? fraction;
  final double diameter;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final value = fraction;
    final level = value == null
        ? ContextUsageLevel.normal
        : contextUsageLevel(value);
    final tint = contextUsageTint(theme, level);
    return SizedBox.square(
      dimension: diameter,
      child: CustomPaint(
        painter: ContextUsageRingPainter(
          fraction: value ?? 0,
          trackColor: theme.textTertiary.withValues(alpha: 0.35),
          arcColor: tint,
        ),
        child: value == null
            ? Center(
                child: Text(
                  '?',
                  textScaler: TextScaler.noScaling,
                  style: AppTypography.labelSmallStyle.copyWith(
                    color: theme.textSecondary,
                    fontWeight: FontWeight.w600,
                    height: 1,
                  ),
                ),
              )
            : null,
      ),
    );
  }
}

class ContextUsageRingPainter extends CustomPainter {
  const ContextUsageRingPainter({
    required this.fraction,
    required this.trackColor,
    required this.arcColor,
  });

  final double fraction;
  final Color trackColor;
  final Color arcColor;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(
      _kContextUsageRingStroke / 2,
      _kContextUsageRingStroke / 2,
      size.width - _kContextUsageRingStroke,
      size.height - _kContextUsageRingStroke,
    );
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _kContextUsageRingStroke
      ..color = trackColor;
    canvas.drawOval(rect, track);
    final sweep = fraction.clamp(0.0, 1.0) * 2 * math.pi;
    if (sweep <= 0) return;
    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _kContextUsageRingStroke
      ..strokeCap = StrokeCap.round
      ..color = arcColor;
    canvas.drawArc(rect, -math.pi / 2, sweep, false, arc);
  }

  @override
  bool shouldRepaint(ContextUsageRingPainter oldDelegate) =>
      oldDelegate.fraction != fraction ||
      oldDelegate.trackColor != trackColor ||
      oldDelegate.arcColor != arcColor;
}

/// Shows the numbers behind the ring, with the context window's Edit.
Future<void> showContextUsageSheet(BuildContext context) {
  return ThemedSheets.showSurface<void>(
    context: context,
    showHandle: false,
    padding: const EdgeInsets.all(Spacing.lg),
    builder: (sheetContext) => const ContextUsageSheetContent(),
  );
}

class ContextUsageSheetContent extends ConsumerWidget {
  const ContextUsageSheetContent({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final usage = ref.watch(chatContextUsageProvider);
    final rows = <Widget>[];
    if (usage != null) {
      final tokens = usage.usedTokens;
      rows.add(
        _ContextUsageRow(
          label: l10n.contextUsageUsed,
          value: usage.tokens.estimated
              ? l10n.contextUsageAboutTokens(tokens)
              : l10n.contextUsageTokens(tokens),
        ),
      );
      final window = usage.contextWindow;
      rows.add(
        _ContextUsageRow(
          label: l10n.contextUsageWindow,
          value: window == null
              ? l10n.contextUsageWindowNotSet
              : l10n.contextUsageTokens(window),
          detail: switch (usage.windowSource) {
            ContextWindowSource.model => l10n.contextUsageSourceModel,
            ContextWindowSource.user => l10n.contextUsageSourceUser,
            ContextWindowSource.directDefault =>
              l10n.contextUsageSourceDirectDefault,
            null => null,
          },
          action: AdaptiveButton(
            key: const ValueKey('context-usage-edit-window'),
            onPressed: () => _editWindow(context, ref, usage),
            label: window == null ? l10n.contextUsageSetWindow : l10n.edit,
            style: AdaptiveButtonStyle.plain,
            size: AdaptiveButtonSize.small,
          ),
        ),
      );
      if (usage.fraction case final fraction?) {
        rows.add(
          _ContextUsageRow(
            label: l10n.contextUsageFilled,
            value: _formatPercent(context, fraction),
            valueColor: contextUsageTint(theme, contextUsageLevel(fraction)),
          ),
        );
      }
      if (usage.tokens.promptTokens case final prompt?) {
        rows.add(
          _ContextUsageRow(
            label: l10n.contextUsageLastPrompt,
            value: l10n.contextUsageTokens(prompt),
          ),
        );
      }
      if (usage.tokens.completionTokens case final completion?) {
        rows.add(
          _ContextUsageRow(
            label: l10n.contextUsageLastReply,
            value: l10n.contextUsageTokens(completion),
          ),
        );
      }
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            ContextUsageRing(fraction: usage?.fraction),
            const SizedBox(width: Spacing.sm),
            Text(
              l10n.contextUsageTitle,
              style: AppTypography.bodyLargeStyle.copyWith(
                fontWeight: FontWeight.w600,
                color: theme.textPrimary,
              ),
            ),
          ],
        ),
        const SizedBox(height: Spacing.lg),
        ...rows,
        if (usage != null) ...[
          const SizedBox(height: Spacing.xs),
          Text(
            usage.tokens.estimated
                ? l10n.contextUsageEstimateNote
                : l10n.contextUsageReportedNote,
            style: AppTypography.labelSmallStyle.copyWith(
              color: theme.textTertiary,
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _editWindow(
    BuildContext context,
    WidgetRef ref,
    ContextUsage usage,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final current = usage.contextWindow;
    final canClear =
        !usage.isDirect && usage.windowSource == ContextWindowSource.user;
    const clearValue = -1;
    final options = <int>[...kContextWindowOptions, if (canClear) clearValue];
    final selected = await showAdaptiveSelectionSheet<int>(
      context: context,
      builder: (sheetContext) => AdaptiveSelectionSheet(
        title: l10n.contextUsageWindow,
        description: l10n.contextUsagePickerDescription,
        itemCount: options.length,
        itemBuilder: (itemContext, index) {
          final value = options[index];
          return AdaptiveSelectionTile(
            key: ValueKey<String>('context-window-option-$value'),
            title: value == clearValue
                ? l10n.clear
                : l10n.contextUsageTokens(value),
            selected: value == current,
            onTap: () => Navigator.of(sheetContext).pop(value),
          );
        },
      ),
    );
    if (selected == null) return;
    if (selected == clearValue) {
      await ref
          .read(contextWindowOverridesProvider.notifier)
          .clear(usage.modelId);
    } else if (usage.isDirect) {
      await ref
          .read(directContextLengthOverridesProvider.notifier)
          .set(usage.modelId, selected);
    } else {
      await ref
          .read(contextWindowOverridesProvider.notifier)
          .set(usage.modelId, selected);
    }
  }
}

class _ContextUsageRow extends StatelessWidget {
  const _ContextUsageRow({
    required this.label,
    required this.value,
    this.detail,
    this.valueColor,
    this.action,
  });

  final String label;
  final String value;
  final String? detail;
  final Color? valueColor;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Text(
              label,
              style: AppTypography.bodyMediumStyle.copyWith(
                color: theme.textSecondary,
              ),
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                value,
                style: AppTypography.bodyMediumStyle.copyWith(
                  fontWeight: FontWeight.w600,
                  fontFamily: AppTypography.monospaceFontFamily,
                  color: valueColor ?? theme.textPrimary,
                ),
              ),
              if (detail != null)
                Text(
                  detail!,
                  style: AppTypography.labelSmallStyle.copyWith(
                    color: theme.textTertiary,
                  ),
                ),
            ],
          ),
          if (action != null) ...[const SizedBox(width: Spacing.sm), action!],
        ],
      ),
    );
  }
}
