import 'dart:async';
import 'dart:convert';

import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit_core/features/automations/providers/automation_providers.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../widgets/message_bubble_colors.dart';
import 'assistant_action_log.dart';
import 'assistant_activity.dart';
import 'assistant_avatar_accent.dart';
import 'assistant_avatar_media.dart';
import 'assistant_pending_approval.dart';
import '../../routines/routines_tab.dart';

const String _logScope = 'chat/avatar-activity';

/// The word shown for [activity] in the pill and the sheet's status line.
String assistantActivityLabel(
  AppLocalizations l10n,
  AssistantActivity activity,
) => switch (activity) {
  AssistantActivity.idle => l10n.assistantActivityIdle,
  AssistantActivity.working => l10n.assistantActivityWorking,
  AssistantActivity.making => l10n.assistantActivityMaking,
  AssistantActivity.done => l10n.assistantActivityDone,
};

/// [text] pretty-printed when it is JSON (also JSON inside a JSON string),
/// otherwise as it is.
String prettyToolPayload(String text) {
  Object? value = text.trim();
  try {
    for (var depth = 0; depth < 3 && value is String; depth++) {
      final decoded = jsonDecode(value);
      if (decoded is String && decoded == value) break;
      value = decoded;
    }
  } on FormatException {
    // Not JSON: show the text as it is.
  }
  if (value is Map || value is List) {
    return const JsonEncoder.withIndent('  ').convert(value);
  }
  return text;
}

/// The sheet behind the avatar circle: a status page for the assistant with
/// the recorded tool calls, a waiting approval, scheduled tasks and, under
/// Appearance, the per-state clips and the bubble color.
class AssistantAvatarSheet extends ConsumerStatefulWidget {
  const AssistantAvatarSheet({
    super.key,
    required this.store,
    this.onChanged,
    this.modelName,
    this.avatar,
    this.initialTab,
    this.messageIds,
  });

  final AssistantAvatarMediaStore store;
  final Future<void> Function()? onChanged;

  /// The model's name, for the header.
  final String? modelName;

  /// What the avatar circle shows right now; the model's initial when null.
  final Widget? avatar;

  /// The tab to open on; Approvals while a prompt waits, else Activity.
  final AssistantSheetTab? initialTab;

  /// Limits the activity list to calls of these messages.
  final Set<String>? messageIds;

  @override
  ConsumerState<AssistantAvatarSheet> createState() =>
      _AssistantAvatarSheetState();
}

class _AssistantAvatarSheetState extends ConsumerState<AssistantAvatarSheet> {
  late AssistantSheetTab _tab;
  Set<String>? _filter;

  /// Failures that were unseen when the Activity tab was first shown, kept
  /// on its label for as long as the sheet is open.
  int _carriedFailures = 0;

  @override
  void initState() {
    super.initState();
    _filter = widget.messageIds;
    _tab =
        widget.initialTab ??
        (ref.read(assistantApprovalProvider) != null
            ? AssistantSheetTab.approvals
            : AssistantSheetTab.activity);
    if (_tab == AssistantSheetTab.activity) _viewActivity();
  }

  /// The Activity tab is on screen: the failures in it count as seen.
  void _viewActivity() {
    _carriedFailures += ref.read(assistantActionLogProvider).unseenFailures;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        ref.read(assistantActionLogProvider.notifier).markFailuresSeen(),
      );
    });
  }

  void _select(AssistantSheetTab tab) {
    if (tab == _tab) return;
    setState(() => _tab = tab);
    if (tab == AssistantSheetTab.activity) _viewActivity();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    // Routines come from the account's scheduled tasks and from the routines
    // server, so the tab is there when either exists.
    final routinesAvailable =
        ref.watch(automationsAvailableProvider) ||
        ref.watch(
          appSettingsProvider.select((s) => s.routinesServerUrl.isNotEmpty),
        );
    final approval = ref.watch(assistantApprovalProvider);
    final unseen = ref.watch(
      assistantActionLogProvider.select((log) => log.unseenFailures),
    );
    final tab = _tab == AssistantSheetTab.routines && !routinesAvailable
        ? AssistantSheetTab.activity
        : _tab;
    final failures = tab == AssistantSheetTab.activity
        ? _carriedFailures + unseen
        : unseen;
    final tabs = <AssistantSheetTab>[
      AssistantSheetTab.activity,
      AssistantSheetTab.approvals,
      if (routinesAvailable) AssistantSheetTab.routines,
      AssistantSheetTab.appearance,
    ];
    final height = MediaQuery.sizeOf(context).height;
    // One height for every tab, so switching tabs never moves the header or
    // the tab control (the same fraction ThemedSheets.showCustom callers such
    // as the channel thread sheet use).
    return SafeArea(
      top: false,
      child: SizedBox(
        key: const ValueKey('assistant-sheet-body'),
        height: height * 0.85,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            Spacing.modalPadding,
            Spacing.sm,
            Spacing.modalPadding,
            Spacing.lg,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _SheetHeader(modelName: widget.modelName, avatar: widget.avatar),
              const SizedBox(height: Spacing.md),
              AdaptiveValueSegmentedControl<AssistantSheetTab>(
                key: const ValueKey('assistant-sheet-tabs'),
                value: tab,
                onChanged: _select,
                segments: [
                  for (final entry in tabs)
                    AdaptiveSegment<AssistantSheetTab>(
                      value: entry,
                      label: _TabLabel(
                        text: switch (entry) {
                          AssistantSheetTab.activity =>
                            l10n.assistantSheetTabActivity,
                          AssistantSheetTab.approvals =>
                            l10n.assistantSheetTabApprovals,
                          AssistantSheetTab.routines =>
                            l10n.assistantSheetTabRoutines,
                          AssistantSheetTab.appearance =>
                            l10n.assistantSheetTabAppearance,
                        },
                        count: switch (entry) {
                          AssistantSheetTab.activity => failures,
                          AssistantSheetTab.approvals =>
                            approval == null ? 0 : 1,
                          _ => 0,
                        },
                        color: entry == AssistantSheetTab.activity
                            ? theme.error
                            : theme.warning,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: Spacing.md),
              Expanded(
                child: switch (tab) {
                  AssistantSheetTab.activity => _ActivityTab(
                    filter: _filter,
                    onClearFilter: () => setState(() => _filter = null),
                  ),
                  AssistantSheetTab.approvals => SingleChildScrollView(
                    child: _ApprovalsTab(approval: approval),
                  ),
                  AssistantSheetTab.routines => const RoutinesTab(),
                  AssistantSheetTab.appearance => SingleChildScrollView(
                    child: _AppearanceTab(
                      store: widget.store,
                      onChanged: widget.onChanged,
                    ),
                  ),
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TabLabel extends StatelessWidget {
  const _TabLabel({
    required this.text,
    required this.count,
    required this.color,
  });

  final String text;
  final int count;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTypography.captionStyle,
          ),
        ),
        if (count > 0) ...[
          const SizedBox(width: Spacing.xxs),
          Container(
            key: ValueKey('assistant-sheet-tab-count-$text'),
            constraints: const BoxConstraints(minWidth: 16),
            padding: const EdgeInsets.symmetric(horizontal: 4),
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(AppBorderRadius.round),
            ),
            child: Text(
              '$count',
              textAlign: TextAlign.center,
              style: AppTypography.micro.copyWith(
                color: const Color(0xFFFFFFFF),
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// The avatar circle, the model's name and the status line the strip shows.
class _SheetHeader extends ConsumerWidget {
  const _SheetHeader({required this.modelName, required this.avatar});

  final String? modelName;
  final Widget? avatar;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final snapshot = ref.watch(
      chatMessagesProvider.select(assistantActivitySnapshot),
    );
    final word = assistantActivityLabel(l10n, snapshot.live);
    final busy = snapshot.live != AssistantActivity.idle;
    final status = busy ? (snapshot.detail ?? word) : word;
    final name = modelName?.trim() ?? '';
    final initial = name.isEmpty
        ? ''
        : String.fromCharCodes(name.runes.take(1)).toUpperCase();
    return Row(
      children: [
        Container(
          key: const ValueKey('assistant-sheet-avatar'),
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: theme.surfaceContainer,
            border: Border.all(color: theme.cardBorder),
          ),
          child: ClipOval(
            child:
                avatar ??
                Center(
                  child: Text(
                    initial,
                    style: AppTypography.titleLargeStyle.copyWith(
                      color: theme.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
          ),
        ),
        const SizedBox(width: Spacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                name.isEmpty ? l10n.assistantAvatar : name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTypography.titleMediumStyle.copyWith(
                  color: theme.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: busy ? theme.warning : theme.success,
                    ),
                  ),
                  const SizedBox(width: Spacing.xs),
                  Flexible(
                    child: Text(
                      status,
                      key: const ValueKey('assistant-sheet-status'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypography.bodySmallStyle.copyWith(
                        color: theme.textSecondary,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// One line of the activity list: a day heading or a recorded call.
sealed class _ActivityItem {
  const _ActivityItem();
}

class _DayHeading extends _ActivityItem {
  const _DayHeading(this.day);
  final DateTime day;
}

class _CallItem extends _ActivityItem {
  const _CallItem(this.record);
  final AssistantActionRecord record;
}

DateTime _dayOf(DateTime time) => DateTime(time.year, time.month, time.day);

class _ActivityTab extends ConsumerStatefulWidget {
  const _ActivityTab({required this.filter, required this.onClearFilter});

  final Set<String>? filter;
  final VoidCallback onClearFilter;

  @override
  ConsumerState<_ActivityTab> createState() => _ActivityTabState();
}

class _ActivityTabState extends ConsumerState<_ActivityTab> {
  final Set<String> _expanded = <String>{};

  String _dayLabel(AppLocalizations l10n, DateTime day) {
    final today = _dayOf(DateTime.now());
    if (day == today) return l10n.today;
    if (day == today.subtract(const Duration(days: 1)) ||
        day == DateTime(today.year, today.month, today.day - 1)) {
      return l10n.yesterday;
    }
    return DateFormat.yMMMd(Localizations.localeOf(context).toString())
        .format(day);
  }

  Future<void> _confirmClear() async {
    final l10n = AppLocalizations.of(context)!;
    final log = ref.read(assistantActionLogProvider.notifier);
    await AdaptiveAlertDialog.show(
      context: context,
      title: l10n.assistantActivityClearTitle,
      message: l10n.assistantActivityClearMessage,
      actions: [
        AlertAction(
          title: l10n.cancel,
          style: AlertActionStyle.cancel,
          onPressed: () {},
        ),
        AlertAction(
          title: l10n.clear,
          style: AlertActionStyle.destructive,
          onPressed: () => unawaited(log.clear()),
        ),
      ],
    );
  }

  void _openInChat(AssistantActionRecord record) {
    final open = ref.read(assistantOpenChatProvider);
    final current = ref.read(activeConversationProvider)?.id;
    Navigator.of(context).maybePop();
    if (current == record.chatId) return;
    unawaited(open(record.chatId));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final log = ref.watch(assistantActionLogProvider);
    final chatId = ref.watch(activeConversationProvider.select((c) => c?.id));
    final filter = widget.filter;
    final records = filter == null
        ? log.records
        : log.records
              .where(
                (record) =>
                    record.chatId == chatId &&
                    filter.contains(record.messageId),
              )
              .toList(growable: false);
    final items = <_ActivityItem>[];
    DateTime? day;
    for (final record in records) {
      final recordDay = _dayOf(record.finishedAt);
      if (recordDay != day) {
        day = recordDay;
        items.add(_DayHeading(recordDay));
      }
      items.add(_CallItem(record));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            if (filter != null)
              AdaptiveChip.input(
                key: const ValueKey('assistant-activity-filter'),
                label: Text(l10n.assistantActivityFromReply),
                onDeleted: widget.onClearFilter,
                deleteButtonTooltipMessage: l10n.assistantActivityShowAll,
              ),
            const Spacer(),
            AdaptiveButton(
              key: const ValueKey('assistant-activity-clear'),
              onPressed: _confirmClear,
              enabled: log.records.isNotEmpty,
              label: l10n.clear,
              style: AdaptiveButtonStyle.plain,
              size: AdaptiveButtonSize.small,
              useNative: false,
            ),
          ],
        ),
        if (items.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: Spacing.lg),
            child: Text(
              l10n.assistantActivityEmpty,
              key: const ValueKey('assistant-activity-empty'),
              textAlign: TextAlign.center,
              style: AppTypography.bodyMediumStyle.copyWith(
                color: theme.textSecondary,
              ),
            ),
          )
        else
          Expanded(
            child: ListView.builder(
              itemCount: items.length,
              itemBuilder: (context, index) {
                final item = items[index];
                return switch (item) {
                  _DayHeading(:final day) => Padding(
                    padding: const EdgeInsets.only(
                      top: Spacing.sm,
                      bottom: Spacing.xs,
                    ),
                    child: Text(
                      _dayLabel(l10n, day),
                      style: AppTypography.labelStyle.copyWith(
                        color: theme.textSecondary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  _CallItem(:final record) => _ActivityRow(
                    record: record,
                    expanded: _expanded.contains(record.key),
                    onToggle: () => setState(() {
                      if (!_expanded.remove(record.key)) {
                        _expanded.add(record.key);
                      }
                    }),
                    onOpenInChat: () => _openInChat(record),
                  ),
                };
              },
            ),
          ),
      ],
    );
  }
}

class _ActivityRow extends StatelessWidget {
  const _ActivityRow({
    required this.record,
    required this.expanded,
    required this.onToggle,
    required this.onOpenInChat,
  });

  final AssistantActionRecord record;
  final bool expanded;
  final VoidCallback onToggle;
  final VoidCallback onOpenInChat;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final failed = record.failed;
    final title = toolStepLabel(record.toolName) ?? record.toolName;
    final preview = toolResultPreview(record, maxLength: 120);
    final time = DateFormat.Hms(Localizations.localeOf(context).toString())
        .format(record.finishedAt);
    return Padding(
      key: ValueKey('assistant-activity-row-${record.key}'),
      padding: const EdgeInsets.symmetric(vertical: Spacing.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            button: true,
            expanded: expanded,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onToggle,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Semantics(
                    label: failed
                        ? l10n.assistantActivityFailed
                        : l10n.assistantActivitySucceeded,
                    child: Icon(
                      cupertinoIconForSFSymbol(
                        failed ? 'xmark.circle.fill' : 'checkmark.circle.fill',
                      ),
                      size: IconSize.md,
                      color: failed ? theme.error : theme.success,
                    ),
                  ),
                  const SizedBox(width: Spacing.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: AppTypography.bodyLargeStyle.copyWith(
                            color: theme.textPrimary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (preview.isNotEmpty)
                          Text(
                            preview,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppTypography.bodySmallStyle.copyWith(
                              color: failed ? theme.error : theme.textSecondary,
                            ),
                          ),
                        Text.rich(
                          TextSpan(
                            text: '$time · ',
                            children: [
                              TextSpan(
                                text: record.toolName,
                                style: TextStyle(
                                  fontFamily: AppTypography.monospaceFontFamily,
                                ),
                              ),
                            ],
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTypography.captionStyle.copyWith(
                            color: theme.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (expanded) ...[
            const SizedBox(height: Spacing.sm),
            _PayloadBlock(
              label: l10n.assistantActivityArguments,
              text: prettyToolPayload(record.arguments),
            ),
            const SizedBox(height: Spacing.sm),
            _PayloadBlock(
              label: l10n.assistantActivityResult,
              text: prettyToolPayload(record.result),
              error: failed,
            ),
            const SizedBox(height: Spacing.sm),
            Row(
              children: [
                if (record.durationSeconds != null)
                  Text(
                    l10n.assistantActivityDuration(record.durationSeconds!),
                    style: AppTypography.captionStyle.copyWith(
                      color: theme.textSecondary,
                    ),
                  ),
                const Spacer(),
                AdaptiveButton(
                  key: ValueKey('assistant-activity-open-${record.key}'),
                  onPressed: onOpenInChat,
                  label: l10n.assistantActivityOpenInChat,
                  style: AdaptiveButtonStyle.tinted,
                  size: AdaptiveButtonSize.small,
                  useNative: false,
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// A labelled, selectable, monospace block with its own scroll.
class _PayloadBlock extends StatelessWidget {
  const _PayloadBlock({
    required this.label,
    required this.text,
    this.error = false,
  });

  final String label;
  final String text;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label.toUpperCase(),
          style: AppTypography.captionStyle.copyWith(
            color: theme.textSecondary,
            letterSpacing: 0.6,
          ),
        ),
        const SizedBox(height: Spacing.xxs),
        Container(
          width: double.infinity,
          constraints: const BoxConstraints(maxHeight: 140),
          padding: const EdgeInsets.all(Spacing.sm),
          decoration: BoxDecoration(
            color: theme.surfaceContainer,
            borderRadius: BorderRadius.circular(AppBorderRadius.sm),
            border: Border.all(color: theme.cardBorder),
          ),
          child: SingleChildScrollView(
            child: AdaptiveSelectableText(
              text.isEmpty ? ' ' : text,
              style: AppTypography.codeStyle.copyWith(
                color: error ? theme.error : theme.textPrimary,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ApprovalsTab extends ConsumerStatefulWidget {
  const _ApprovalsTab({required this.approval});

  final AssistantApproval? approval;

  @override
  ConsumerState<_ApprovalsTab> createState() => _ApprovalsTabState();
}

class _ApprovalsTabState extends ConsumerState<_ApprovalsTab> {
  bool _busy = false;
  bool _failed = false;

  Future<void> _decide(AssistantApproval approval, bool approved) async {
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      await decideAssistantApproval(ref, approval, approved: approved);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'approval-failed',
        scope: _logScope,
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final approval = widget.approval;
    if (approval == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: Spacing.lg),
        child: Text(
          l10n.assistantApprovalsEmpty,
          key: const ValueKey('assistant-approvals-empty'),
          textAlign: TextAlign.center,
          style: AppTypography.bodyMediumStyle.copyWith(
            color: theme.textSecondary,
          ),
        ),
      );
    }
    final prompt = approval.prompt;
    final question = prompt.questions.isEmpty ? null : prompt.questions.first;
    final title =
        question?.header ??
        (prompt.title.trim().isEmpty
            ? l10n.hermesApprovalRequired
            : prompt.title.trim());
    final message = question?.question ?? prompt.message;
    final tool = approval.toolName;
    return Container(
      key: const ValueKey('assistant-approval-card'),
      padding: const EdgeInsets.all(Spacing.md),
      decoration: BoxDecoration(
        color: theme.warningBackground,
        borderRadius: BorderRadius.circular(AppBorderRadius.md),
        border: Border.all(color: theme.warning.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: AppTypography.bodyLargeStyle.copyWith(
              color: theme.textPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (tool != null && tool != title)
            Text(
              tool,
              style: AppTypography.captionStyle.copyWith(
                fontFamily: AppTypography.monospaceFontFamily,
                color: theme.textSecondary,
              ),
            ),
          if (message.trim().isNotEmpty) ...[
            const SizedBox(height: Spacing.xs),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 160),
              child: SingleChildScrollView(
                child: Text(
                  message,
                  style: AppTypography.bodySmallStyle.copyWith(
                    color: theme.textSecondary,
                  ),
                ),
              ),
            ),
          ],
          if (_failed) ...[
            const SizedBox(height: Spacing.xs),
            Text(
              l10n.errorMessage,
              key: const ValueKey('assistant-approval-error'),
              style: AppTypography.bodySmallStyle.copyWith(color: theme.error),
            ),
          ],
          const SizedBox(height: Spacing.md),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (approval.canDecideHere) ...[
                AdaptiveButton(
                  key: const ValueKey('assistant-approval-deny'),
                  onPressed: () => _decide(approval, false),
                  enabled: !_busy,
                  label: l10n.hermesApprovalDenyAction,
                  style: AdaptiveButtonStyle.plain,
                  size: AdaptiveButtonSize.small,
                  useNative: false,
                ),
                const SizedBox(width: Spacing.sm),
                AdaptiveButton(
                  key: const ValueKey('assistant-approval-approve'),
                  onPressed: () => _decide(approval, true),
                  enabled: !_busy,
                  label: l10n.hermesApprovalApproveAction,
                  size: AdaptiveButtonSize.small,
                  useNative: false,
                ),
              ] else
                AdaptiveButton(
                  key: const ValueKey('assistant-approval-answer-in-chat'),
                  onPressed: () => Navigator.of(context).maybePop(),
                  label: l10n.assistantApprovalsAnswerInChat,
                  size: AdaptiveButtonSize.small,
                  useNative: false,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The Appearance tab: assigns a clip to each state and, with Message
/// bubbles on, picks the bubble color.
class _AppearanceTab extends ConsumerStatefulWidget {
  const _AppearanceTab({required this.store, this.onChanged});

  final AssistantAvatarMediaStore store;
  final Future<void> Function()? onChanged;

  @override
  ConsumerState<_AppearanceTab> createState() => _AppearanceTabState();
}

class _AppearanceTabState extends ConsumerState<_AppearanceTab> {
  AssistantAvatarMediaSet _media = AssistantAvatarMediaSet.empty;
  AssistantActivity? _busy;

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  Future<void> _reload() async {
    final media = await widget.store.load();
    if (!mounted) return;
    setState(() => _media = media);
  }

  Future<void> _choose(AssistantActivity state) async {
    setState(() => _busy = state);
    final stored = await widget.store.pickAndAssign(state);
    if (!mounted) return;
    setState(() => _busy = null);
    if (stored == false) {
      AdaptiveSnackBar.show(
        context,
        message: AppLocalizations.of(context)!.assistantAvatarPickFailed,
        type: AdaptiveSnackBarType.error,
      );
      return;
    }
    if (stored == true) await _changed();
  }

  Future<void> _remove(AssistantActivity state) async {
    setState(() => _busy = state);
    await widget.store.remove(state);
    if (!mounted) return;
    setState(() => _busy = null);
    await _changed();
  }

  Future<void> _changed() async {
    await _reload();
    await widget.onChanged?.call();
  }

  String _kindLabel(AppLocalizations l10n, AssistantActivity state) {
    final user = _media.userFiles[state];
    if (user != null) {
      return user.kind == AssistantAvatarMediaKind.video
          ? l10n.assistantAvatarMediaVideo
          : l10n.assistantAvatarMediaImage;
    }
    if (_media.bundled.contains(state)) return l10n.assistantAvatarMediaDefault;
    return l10n.assistantAvatarMediaNone;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final state in AssistantActivity.values)
          _buildRow(context, l10n, theme, state),
        if (ref.watch(
          appSettingsProvider.select((settings) => settings.messageBubbles),
        ))
          _BubbleColorPicker(l10n: l10n, theme: theme),
      ],
    );
  }

  Widget _buildRow(
    BuildContext context,
    AppLocalizations l10n,
    ConduitThemeExtension theme,
    AssistantActivity state,
  ) {
    final hasUserFile = _media.userFiles.containsKey(state);
    final overridesDefault = hasUserFile && _media.bundled.contains(state);
    final busy = _busy != null;
    return Padding(
      key: ValueKey('assistant-avatar-row-${state.name}'),
      padding: const EdgeInsets.symmetric(vertical: Spacing.xs),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  assistantActivityLabel(l10n, state),
                  style: AppTypography.bodyLargeStyle.copyWith(
                    color: theme.textPrimary,
                  ),
                ),
                Text(
                  overridesDefault
                      ? '${_kindLabel(l10n, state)} · '
                            '${l10n.assistantAvatarRemoveRestoresDefault}'
                      : _kindLabel(l10n, state),
                  style: AppTypography.bodySmallStyle.copyWith(
                    color: theme.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: Spacing.sm),
          AdaptiveButton(
            key: ValueKey('assistant-avatar-choose-${state.name}'),
            onPressed: () => _choose(state),
            enabled: !busy,
            label: l10n.assistantAvatarChoose,
            style: AdaptiveButtonStyle.tinted,
            size: AdaptiveButtonSize.small,
            useNative: false,
          ),
          const SizedBox(width: Spacing.xs),
          AdaptiveButton(
            key: ValueKey('assistant-avatar-remove-${state.name}'),
            onPressed: () => _remove(state),
            enabled: !busy && hasUserFile,
            label: l10n.assistantAvatarRemove,
            style: AdaptiveButtonStyle.plain,
            size: AdaptiveButtonSize.small,
            useNative: false,
          ),
        ],
      ),
    );
  }
}

/// The user bubble color choice, shown in the avatar sheet while "Message
/// bubbles" is on: Auto (from the avatar), Gray (the neutral look) and a few
/// swatches, each previewed as the bubble it would make in this theme.
class _BubbleColorPicker extends ConsumerWidget {
  const _BubbleColorPicker({required this.l10n, required this.theme});

  final AppLocalizations l10n;
  final ConduitThemeExtension theme;

  String _swatchLabel(MessageBubbleSwatch swatch) => switch (swatch) {
    MessageBubbleSwatch.gold => l10n.assistantAvatarBubbleColorGold,
    MessageBubbleSwatch.orange => l10n.assistantAvatarBubbleColorOrange,
    MessageBubbleSwatch.pink => l10n.assistantAvatarBubbleColorPink,
    MessageBubbleSwatch.purple => l10n.assistantAvatarBubbleColorPurple,
    MessageBubbleSwatch.blue => l10n.assistantAvatarBubbleColorBlue,
    MessageBubbleSwatch.green => l10n.assistantAvatarBubbleColorGreen,
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(
      appSettingsProvider.select(
        (settings) => settings.assistantAvatarBubbleColor,
      ),
    );
    final auto = ref.watch(assistantAvatarAutoAccentProvider);
    void choose(String value) => ref
        .read(appSettingsProvider.notifier)
        .setAssistantAvatarBubbleColor(value);

    final options = <Widget>[
      _BubbleColorOption(
        key: const ValueKey('bubble-color-auto'),
        label: l10n.assistantAvatarBubbleColorAuto,
        colors: resolveMessageBubbleColors(theme, auto),
        icon: cupertinoIconForSFSymbol('sparkles'),
        selected: selected == assistantAvatarBubbleColorAuto,
        onTap: () => choose(assistantAvatarBubbleColorAuto),
        theme: theme,
      ),
      _BubbleColorOption(
        key: const ValueKey('bubble-color-gray'),
        label: l10n.assistantAvatarBubbleColorGray,
        colors: resolveMessageBubbleColors(theme, null),
        selected: selected == assistantAvatarBubbleColorGray,
        onTap: () => choose(assistantAvatarBubbleColorGray),
        theme: theme,
      ),
      for (final swatch in MessageBubbleSwatch.values)
        _BubbleColorOption(
          key: ValueKey('bubble-color-${swatch.name}'),
          label: _swatchLabel(swatch),
          colors: resolveMessageBubbleColors(theme, swatch.color),
          selected:
              parseBubbleColor(selected)?.toARGB32() == swatch.color.toARGB32(),
          onTap: () => choose(swatch.storageValue),
          theme: theme,
        ),
    ];

    return Padding(
      padding: const EdgeInsets.only(top: Spacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.assistantAvatarBubbleColor,
            style: AppTypography.bodyLargeStyle.copyWith(
              color: theme.textPrimary,
            ),
          ),
          Text(
            l10n.assistantAvatarBubbleColorDescription,
            style: AppTypography.bodySmallStyle.copyWith(
              color: theme.textSecondary,
            ),
          ),
          const SizedBox(height: Spacing.sm),
          Wrap(spacing: Spacing.sm, runSpacing: Spacing.sm, children: options),
        ],
      ),
    );
  }
}

class _BubbleColorOption extends StatelessWidget {
  const _BubbleColorOption({
    super.key,
    required this.label,
    required this.colors,
    required this.selected,
    required this.onTap,
    required this.theme,
    this.icon,
  });

  static const double _size = 40;

  final String label;
  final MessageBubbleColors colors;
  final bool selected;
  final VoidCallback onTap;
  final ConduitThemeExtension theme;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          width: 56,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: _size + 6,
                height: _size + 6,
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: selected
                        ? theme.textPrimary
                        : const Color(0x00000000),
                    width: 2,
                  ),
                ),
                child: Container(
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: colors.userFill,
                  ),
                  child: icon == null
                      ? null
                      : Icon(icon, size: 18, color: colors.userText),
                ),
              ),
              const SizedBox(height: Spacing.xxs),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTypography.captionStyle.copyWith(
                  color: selected ? theme.textPrimary : theme.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
