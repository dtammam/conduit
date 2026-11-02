import 'dart:async';

import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit/shared/widgets/themed_sheets.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'musey_actions_provider.dart';
import 'musey_api.dart';

/// Sends the composed text into the current chat as a normal user message.
/// True when the chat took it.
typedef MuseySend = Future<bool> Function(String text);

/// The actions whose label or id contains [query] (case-insensitive), in the
/// relay's order. An empty query keeps all.
List<MuseyAction> filterMuseyActions(List<MuseyAction> actions, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return actions;
  return [
    for (final a in actions)
      if (a.label.toLowerCase().contains(q) || a.id.toLowerCase().contains(q))
        a,
  ];
}

IconData _iconFor(String? sfSymbol) {
  final name = sfSymbol ?? '';
  if (name.contains('cart') || name.contains('basket')) {
    return CupertinoIcons.cart;
  }
  if (name.contains('checkmark') || name.contains('checklist')) {
    return CupertinoIcons.checkmark_circle;
  }
  if (name.contains('house') || name.contains('broom')) {
    return CupertinoIcons.house;
  }
  if (name.contains('dollar') || name.contains('creditcard')) {
    return CupertinoIcons.money_dollar_circle;
  }
  return CupertinoIcons.wrench;
}

/// Opens the actions sheet over the chat. With [initial] it opens straight on
/// that action (the "/" shortcut).
Future<void> showMuseyActionsSheet(
  BuildContext context, {
  required MuseySend send,
  MuseyAction? initial,
}) {
  return ThemedSheets.showCustom<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => MuseyActionsSheet(send: send, initial: initial),
  );
}

/// The wrench sheet: the list of actions, then the form of the one picked.
class MuseyActionsSheet extends ConsumerStatefulWidget {
  const MuseyActionsSheet({super.key, required this.send, this.initial});

  final MuseySend send;
  final MuseyAction? initial;

  @override
  ConsumerState<MuseyActionsSheet> createState() => _MuseyActionsSheetState();
}

class _MuseyActionsSheetState extends ConsumerState<MuseyActionsSheet> {
  MuseyAction? _picked;

  @override
  void initState() {
    super.initState();
    _picked = widget.initial;
    if (widget.initial == null) {
      Future<void>.microtask(
        () => ref.read(museyActionsProvider.notifier).load(),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final picked = _picked;
    final inset = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: inset),
      child: ConduitModalSheetSurface(
        child: SafeArea(
          top: false,
          child: picked == null
              ? MuseyActionList(onPick: (a) => setState(() => _picked = a))
              : MuseyActionForm(
                  key: ValueKey<String>('musey-form-${picked.id}'),
                  action: picked,
                  send: widget.send,
                  onBack: widget.initial == null
                      ? () => setState(() => _picked = null)
                      : null,
                  onDone: () => Navigator.of(context).maybePop(),
                ),
        ),
      ),
    );
  }
}

class _SheetTitle extends StatelessWidget {
  const _SheetTitle({required this.title, this.onBack});

  final String title;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.sm),
      child: Row(
        children: [
          if (onBack != null)
            GestureDetector(
              key: const ValueKey<String>('musey-back'),
              behavior: HitTestBehavior.opaque,
              onTap: onBack,
              child: Padding(
                padding: const EdgeInsets.only(right: Spacing.sm),
                child: Icon(
                  CupertinoIcons.chevron_back,
                  size: IconSize.medium,
                  color: theme.textPrimary,
                ),
              ),
            ),
          Expanded(
            child: Text(
              title,
              style: AppTypography.bodyLargeStyle.copyWith(
                fontWeight: FontWeight.w600,
                color: theme.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The action list: the cached list shows at once and refreshes under it; with
/// nothing cached and no answer, a plain error with a retry.
class MuseyActionList extends ConsumerWidget {
  const MuseyActionList({super.key, required this.onPick});

  final ValueChanged<MuseyAction> onPick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(museyActionsProvider);
    final theme = context.conduitTheme;
    final actions = state.actions;
    final Widget body;
    if (actions == null) {
      if (state.error != null) {
        body = Column(
          key: const ValueKey<String>('musey-actions-error'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              state.error!,
              style: AppTypography.bodyMediumStyle.copyWith(
                color: theme.textSecondary,
              ),
            ),
            const SizedBox(height: Spacing.md),
            ConduitButton(
              key: const ValueKey<String>('musey-actions-retry'),
              text: 'Retry',
              isFullWidth: true,
              onPressed: () =>
                  unawaited(ref.read(museyActionsProvider.notifier).load()),
            ),
          ],
        );
      } else {
        body = const Padding(
          key: ValueKey<String>('musey-actions-loading'),
          padding: EdgeInsets.symmetric(vertical: Spacing.lg),
          child: Center(
            child: ConduitLoadingIndicator(size: IconSize.lg, isCompact: true),
          ),
        );
      }
    } else if (actions.isEmpty) {
      body = Text(
        'No actions yet.',
        key: const ValueKey<String>('musey-actions-empty'),
        style: AppTypography.bodyMediumStyle.copyWith(
          color: theme.textSecondary,
        ),
      );
    } else {
      body = Column(
        key: const ValueKey<String>('musey-actions-list'),
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final action in actions) ...[
            MuseyActionRow(action: action, onTap: () => onPick(action)),
            const SizedBox(height: Spacing.xs),
          ],
        ],
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SheetTitle(title: 'Actions'),
        Flexible(child: SingleChildScrollView(child: body)),
        const SizedBox(height: Spacing.sm),
      ],
    );
  }
}

class MuseyActionRow extends StatelessWidget {
  const MuseyActionRow({
    super.key,
    required this.action,
    required this.onTap,
    this.selected = false,
  });

  final MuseyAction action;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    return Semantics(
      button: true,
      label: action.label,
      excludeSemantics: true,
      onTap: onTap,
      child: ConduitCard(
        key: ValueKey<String>('musey-action-${action.id}'),
        onTap: onTap,
        isSelected: selected,
        padding: const EdgeInsets.symmetric(
          horizontal: Spacing.md,
          vertical: Spacing.sm + Spacing.xxs,
        ),
        child: Row(
          children: [
            Icon(
              _iconFor(action.icon),
              size: IconSize.medium,
              color: theme.textPrimary,
            ),
            const SizedBox(width: Spacing.sm + Spacing.xs),
            Expanded(
              child: Text(
                action.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTypography.bodyLargeStyle.copyWith(
                  color: theme.textPrimary,
                ),
              ),
            ),
            Icon(
              CupertinoIcons.chevron_forward,
              size: IconSize.small,
              color: theme.iconSecondary,
            ),
          ],
        ),
      ),
    );
  }
}

String _two(int n) => n.toString().padLeft(2, '0');
String formatMuseyDate(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
    '${_two(d.month)}-${_two(d.day)}';
String formatMuseyTime(DateTime d) => '${_two(d.hour)}:${_two(d.minute)}';

/// The form of one action. A required choice that is the only required field
/// sends the moment it is tapped.
class MuseyActionForm extends ConsumerStatefulWidget {
  const MuseyActionForm({
    super.key,
    required this.action,
    required this.send,
    required this.onDone,
    this.onBack,
    this.now,
  });

  final MuseyAction action;
  final MuseySend send;

  /// Called after the text went into the chat.
  final VoidCallback onDone;
  final VoidCallback? onBack;

  /// The clock for date and time defaults (tests set it).
  final DateTime Function()? now;

  @override
  ConsumerState<MuseyActionForm> createState() => _MuseyActionFormState();
}

class _MuseyActionFormState extends ConsumerState<MuseyActionForm> {
  final Map<String, String> _choices = {};
  final Map<String, TextEditingController> _texts = {};
  final Map<String, DateTime> _moments = {};
  final Map<String, String> _fieldErrors = {};
  bool _sending = false;
  String? _error;

  DateTime get _now => (widget.now ?? DateTime.now)();

  @override
  void initState() {
    super.initState();
    for (final f in widget.action.fields) {
      final d = f.defaultValue;
      switch (f.type) {
        case MuseyFieldType.choice:
          if (d is String && f.options.any((o) => o.value == d)) {
            _choices[f.key] = d;
          }
        case MuseyFieldType.text:
        case MuseyFieldType.number:
          _texts[f.key] = TextEditingController(text: d?.toString() ?? '');
        case MuseyFieldType.date:
        case MuseyFieldType.time:
          _moments[f.key] = _parseMoment(f, d) ?? _now;
      }
    }
    // An action with nothing to fill in (undo) runs on the pick.
    if (widget.action.fields.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_submit(const <String, Object?>{}));
      });
    }
  }

  DateTime? _parseMoment(MuseyField f, Object? d) {
    if (d is! String) return null;
    final base = _now;
    if (f.type == MuseyFieldType.date) {
      final p = DateTime.tryParse(d);
      return p == null ? null : DateTime(p.year, p.month, p.day);
    }
    final m = RegExp(r'^(\d{1,2}):(\d{2})').firstMatch(d);
    if (m == null) return null;
    return DateTime(
      base.year,
      base.month,
      base.day,
      int.parse(m.group(1)!),
      int.parse(m.group(2)!),
    );
  }

  @override
  void dispose() {
    for (final c in _texts.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// The slots to send, or null with [_fieldErrors] set when a required field
  /// is empty or a number is not one.
  /// The current value of a field for `show_when`: the picked option or the
  /// typed text, null while empty.
  String? _valueOf(String key) {
    final choice = _choices[key];
    if (choice != null) return choice;
    final text = _texts[key]?.text.trim();
    return text == null || text.isEmpty ? null : text;
  }

  Map<String, Object?>? _collect() {
    final slots = <String, Object?>{};
    final errors = <String, String>{};
    for (final f in widget.action.fields) {
      // A field that is not showing is neither checked nor sent.
      if (!f.visibleGiven(_valueOf)) continue;
      switch (f.type) {
        case MuseyFieldType.choice:
          final v = _choices[f.key];
          if (v == null) {
            if (f.mustFill) errors[f.key] = 'Pick one';
          } else {
            slots[f.key] = v;
          }
        case MuseyFieldType.text:
          final v = _texts[f.key]!.text.trim();
          if (v.isEmpty) {
            if (f.mustFill) errors[f.key] = 'Required';
          } else {
            slots[f.key] = v;
          }
        case MuseyFieldType.number:
          final v = _texts[f.key]!.text.trim();
          if (v.isEmpty) {
            if (f.mustFill) errors[f.key] = 'Required';
          } else {
            final n = num.tryParse(v.replaceAll(',', '.'));
            if (n == null) {
              errors[f.key] = 'Enter a number';
            } else {
              slots[f.key] = n;
            }
          }
        case MuseyFieldType.date:
          slots[f.key] = formatMuseyDate(_moments[f.key]!);
        case MuseyFieldType.time:
          slots[f.key] = formatMuseyTime(_moments[f.key]!);
      }
    }
    setState(() {
      _fieldErrors
        ..clear()
        ..addAll(errors);
    });
    return errors.isEmpty ? slots : null;
  }

  Future<void> _submit([Map<String, Object?>? preset]) async {
    if (_sending) return;
    final slots = preset ?? _collect();
    if (slots == null) return;
    final api = ref.read(museyApiProvider);
    if (api == null) {
      setState(() => _error = 'No relay is set up.');
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      // The composed text goes to the chat exactly as returned: it holds an
      // invisible marker, so nothing here trims or rewrites it.
      final text = await api.compose(widget.action.id, slots);
      final sent = await widget.send(text);
      if (!mounted) return;
      if (sent) {
        widget.onDone();
      } else {
        setState(() {
          _sending = false;
          _error = 'Musey is busy. Try again in a moment.';
        });
      }
    } on MuseyApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _error = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _error = 'Something went wrong. Try again.';
      });
    }
  }

  void _pickChoice(MuseyField f, MuseyOption o) {
    setState(() {
      _choices[f.key] = o.value;
      _fieldErrors.remove(f.key);
    });
    if (widget.action.oneTapFieldGiven(_valueOf)?.key == f.key) {
      unawaited(_submit(_collect()));
    }
  }

  Future<void> _pickMoment(MuseyField f) async {
    var value = _moments[f.key]!;
    final isDate = f.type == MuseyFieldType.date;
    await ThemedSheets.showCustom<void>(
      context: context,
      builder: (sheetContext) => ConduitModalSheetSurface(
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _SheetTitle(title: f.label),
              SizedBox(
                height: 200,
                child: CupertinoDatePicker(
                  mode: isDate
                      ? CupertinoDatePickerMode.date
                      : CupertinoDatePickerMode.time,
                  initialDateTime: value,
                  use24hFormat: MediaQuery.alwaysUse24HourFormatOf(sheetContext),
                  onDateTimeChanged: (d) => value = d,
                ),
              ),
              const SizedBox(height: Spacing.sm),
              ConduitButton(
                text: 'Done',
                isFullWidth: true,
                onPressed: () => Navigator.of(sheetContext).pop(),
              ),
              const SizedBox(height: Spacing.sm),
            ],
          ),
        ),
      ),
    );
    if (mounted) setState(() => _moments[f.key] = value);
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final fields = [
      for (final f in widget.action.fields)
        if (f.visibleGiven(_valueOf)) f,
    ];
    final oneTap = widget.action.oneTapFieldGiven(_valueOf);
    final onlyTheOneTap = oneTap != null && fields.length == 1;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SheetTitle(title: widget.action.label, onBack: widget.onBack),
        Flexible(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final f in fields) ...[
                  _buildField(f, theme),
                  if (f.note != null)
                    Padding(
                      padding: const EdgeInsets.only(top: Spacing.xs),
                      child: Text(
                        f.note!,
                        key: ValueKey<String>('musey-note-${f.key}'),
                        style: AppTypography.labelSmallStyle.copyWith(
                          color: theme.textSecondary,
                        ),
                      ),
                    ),
                  const SizedBox(height: Spacing.sm),
                ],
              ],
            ),
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: Spacing.sm),
            child: Text(
              _error!,
              key: const ValueKey<String>('musey-form-error'),
              style: AppTypography.bodyMediumStyle.copyWith(
                color: theme.error,
              ),
            ),
          ),
        if (!onlyTheOneTap)
          ConduitButton(
            key: const ValueKey<String>('musey-send'),
            text: 'Send',
            isFullWidth: true,
            isLoading: _sending,
            onPressed: _sending ? null : () => unawaited(_submit()),
          ),
        const SizedBox(height: Spacing.sm),
      ],
    );
  }

  Widget _label(MuseyField f, ConduitThemeExtension theme) => Padding(
    padding: const EdgeInsets.only(bottom: Spacing.xs),
    child: Text(
      f.label,
      style: AppTypography.labelSmallStyle.copyWith(
        color: theme.textSecondary,
        fontWeight: FontWeight.w600,
      ),
    ),
  );

  Widget _fieldError(MuseyField f, ConduitThemeExtension theme) {
    final e = _fieldErrors[f.key];
    if (e == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: Spacing.xs),
      child: Text(
        e,
        key: ValueKey<String>('musey-error-${f.key}'),
        style: AppTypography.labelSmallStyle.copyWith(color: theme.error),
      ),
    );
  }

  Widget _buildField(MuseyField f, ConduitThemeExtension theme) {
    switch (f.type) {
      case MuseyFieldType.choice:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _label(f, theme),
            for (final o in f.options) ...[
              _OptionRow(
                key: ValueKey<String>('musey-option-${f.key}-${o.value}'),
                label: o.label,
                selected: _choices[f.key] == o.value,
                onTap: _sending ? null : () => _pickChoice(f, o),
              ),
              const SizedBox(height: Spacing.xs),
            ],
            _fieldError(f, theme),
          ],
        );
      case MuseyFieldType.text:
      case MuseyFieldType.number:
        final isNumber = f.type == MuseyFieldType.number;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _label(f, theme),
            AdaptiveTextField(
              key: ValueKey<String>('musey-field-${f.key}'),
              controller: _texts[f.key],
              keyboardType: isNumber
                  ? const TextInputType.numberWithOptions(decimal: true)
                  : TextInputType.text,
              textCapitalization: isNumber
                  ? TextCapitalization.none
                  : TextCapitalization.sentences,
              textInputAction: TextInputAction.done,
              onChanged: (_) {
                if (_fieldErrors.containsKey(f.key)) {
                  setState(() => _fieldErrors.remove(f.key));
                }
              },
              onSubmitted: (_) => unawaited(_submit()),
            ),
            _fieldError(f, theme),
          ],
        );
      case MuseyFieldType.date:
      case MuseyFieldType.time:
        final value = _moments[f.key]!;
        final shown = f.type == MuseyFieldType.date
            ? formatMuseyDate(value)
            : formatMuseyTime(value);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _label(f, theme),
            ConduitCard(
              key: ValueKey<String>('musey-field-${f.key}'),
              onTap: () => unawaited(_pickMoment(f)),
              padding: const EdgeInsets.symmetric(
                horizontal: Spacing.md,
                vertical: Spacing.sm + Spacing.xxs,
              ),
              child: Text(
                shown,
                style: AppTypography.bodyLargeStyle.copyWith(
                  color: theme.textPrimary,
                ),
              ),
            ),
          ],
        );
    }
  }
}

class _OptionRow extends StatelessWidget {
  const _OptionRow({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      excludeSemantics: true,
      onTap: onTap,
      child: ConduitCard(
        onTap: onTap,
        isSelected: selected,
        padding: const EdgeInsets.symmetric(
          horizontal: Spacing.md,
          vertical: Spacing.sm + Spacing.xxs,
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: AppTypography.bodyLargeStyle.copyWith(
                  color: theme.textPrimary,
                ),
              ),
            ),
            if (selected)
              Icon(
                CupertinoIcons.checkmark_alt,
                size: IconSize.small,
                color: theme.textPrimary,
              ),
          ],
        ),
      ),
    );
  }
}

/// The list above the composer for the "/" shortcut: the actions matching
/// what follows the slash. A tap picks one.
class MuseySlashOverlay extends ConsumerWidget {
  const MuseySlashOverlay({
    super.key,
    required this.query,
    required this.selectionIndex,
    required this.onPicked,
    this.below,
  });

  final String query;

  /// The highlighted row of the actions; a value past the last action
  /// highlights none of them (the highlight is then in [below]).
  final int selectionIndex;
  final ValueChanged<MuseyAction> onPicked;

  /// The saved prompts list, shown under a thin divider after the actions.
  final Widget? below;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = context.conduitTheme;
    final all = ref.watch(museyActionsProvider).actions ?? const [];
    final items = filterMuseyActions(all, query);
    final brightness = Theme.of(context).brightness;
    final below = this.below;
    // No matching action: the saved prompts list stands alone, as it always
    // has.
    if (items.isEmpty && below != null) return below;
    final list = items.isEmpty
        ? Padding(
            padding: const EdgeInsets.all(Spacing.md),
            child: Text(
              all.isEmpty ? 'Loading actions' : 'No matching action',
              style: AppTypography.bodyMediumStyle.copyWith(
                color: theme.textSecondary,
              ),
            ),
          )
        : ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 240),
            child: _slashRows(theme, items),
          );
    return Container(
      key: const ValueKey<String>('musey-slash-overlay'),
      decoration: BoxDecoration(
        color: theme.cardBackground,
        borderRadius: BorderRadius.circular(AppBorderRadius.card),
        border: Border.all(
          color: theme.cardBorder.withValues(
            alpha: brightness == Brightness.dark ? 0.6 : 0.4,
          ),
          width: BorderWidth.thin,
        ),
      ),
      child: below == null
          ? list
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                list,
                Container(
                  key: const ValueKey<String>('musey-slash-divider'),
                  height: BorderWidth.thin,
                  color: theme.dividerColor,
                ),
                below,
              ],
            ),
    );
  }

  Widget _slashRows(ConduitThemeExtension theme, List<MuseyAction> items) {
    return Builder(
      builder: (context) => ListView.builder(
        shrinkWrap: true,
        padding: EdgeInsets.zero,
        physics: const ClampingScrollPhysics(),
        itemCount: items.length,
        itemBuilder: (_, i) {
          final a = items[i];
          final active = i == selectionIndex;
          return InkWell(
            key: ValueKey<String>('musey-slash-${a.id}'),
            onTap: () => onPicked(a),
            child: Container(
              color: active ? theme.textPrimary.withValues(alpha: 0.06) : null,
              padding: const EdgeInsets.symmetric(
                horizontal: Spacing.md,
                vertical: Spacing.sm + Spacing.xxs,
              ),
              child: Row(
                children: [
                  Icon(
                    _iconFor(a.icon),
                    size: IconSize.medium,
                    color: theme.textPrimary,
                  ),
                  const SizedBox(width: Spacing.sm + Spacing.xs),
                  Expanded(
                    child: Text(
                      a.label,
                      style: AppTypography.bodyLargeStyle.copyWith(
                        color: theme.textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
