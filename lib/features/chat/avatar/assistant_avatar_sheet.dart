import 'dart:async';
import 'dart:convert';

import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit_core/features/automations/providers/automation_providers.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/utils/debug_logger.dart';

import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:video_player/video_player.dart';
import 'package:conduit_core/features/chat/server_speech/server_speech_providers.dart';

import 'persona_appearance_service.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart' show Scaffold, Tooltip;

import '../widgets/message_bubble_colors.dart';
import 'assistant_action_log.dart';
import 'assistant_activity.dart';
import 'assistant_avatar_accent.dart';
import 'assistant_avatar_media.dart';
import 'assistant_pending_approval.dart';
import 'omni_tab_bar.dart';
import '../../routines/push_registration.dart';
import '../musey/musey_feed_providers.dart';
import '../musey/musey_feed_views.dart';

import 'package:conduit/shared/widgets/adaptive_toolbar_components.dart';
import 'package:conduit_core/features/chat/omni/omni_chat.dart'
    show storedOmniChatId;

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

/// The pages behind the avatar circle and the bottom bar, as in Muse: Feed,
/// Ideas, Routines and More (Activity, Approvals, Appearance), each its own
/// full page: a round menu button, the persona pill and an optional action on
/// top, a large title, then the content. Moving between them is the bottom
/// bar only, with the current one selected.
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

  /// The page to open on; Approvals while a prompt waits, else Activity.
  final AssistantSheetTab? initialTab;

  /// Limits the activity list to calls of these messages.
  final Set<String>? messageIds;

  @override
  ConsumerState<AssistantAvatarSheet> createState() =>
      _AssistantAvatarSheetState();
}

/// Opens the assistant page over the chat, full screen.
Future<void> showAssistantPage(
  BuildContext context, {
  required AssistantAvatarSheet Function() builder,
}) {
  return Navigator.of(context).push<void>(
    // A short fade, not the iOS slide (2026-11-05): these are tabs, and in Dean's
    // recording the slide left the body black on the left for about half a second
    // with native glass views on both pages. The back button still returns.
    PageRouteBuilder<void>(
      settings: const RouteSettings(name: 'assistant-page'),
      transitionDuration: const Duration(milliseconds: 140),
      reverseTransitionDuration: const Duration(milliseconds: 140),
      pageBuilder: (_, _, _) => builder(),
      transitionsBuilder: (_, animation, _, child) =>
          FadeTransition(opacity: animation, child: child),
    ),
  );
}

class _AssistantAvatarSheetState extends ConsumerState<AssistantAvatarSheet> {
  late AssistantSheetTab _tab;
  Set<String>? _filter;

  /// Activity, Approvals or Appearance was opened from the More page, so the
  /// top-left button goes back there.
  bool _fromMore = false;

  @override
  void initState() {
    super.initState();
    _filter = widget.messageIds;
    var tab =
        widget.initialTab ??
        (ref.read(assistantApprovalProvider) != null
            ? AssistantSheetTab.approvals
            : AssistantSheetTab.activity);
    if (tab == AssistantSheetTab.chat) tab = AssistantSheetTab.activity;
    _tab = tab;
    if (_tab == AssistantSheetTab.activity) _viewActivity();
  }

  /// The Activity page is on screen: the failures in it count as seen.
  void _viewActivity() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        ref.read(assistantActionLogProvider.notifier).markFailuresSeen(),
      );
    });
  }

  /// A bar tap: the chat closes the page, the others switch to their page.
  void _select(AssistantSheetTab tab) {
    if (tab == AssistantSheetTab.chat) {
      Navigator.of(context).maybePop();
      return;
    }
    _fromMore = false;
    if (tab == _tab) return;
    setState(() => _tab = tab);
    if (tab == AssistantSheetTab.activity) _viewActivity();
  }

  void _openFromMore(AssistantSheetTab tab) {
    setState(() {
      _fromMore = true;
      _tab = tab;
    });
    if (tab == AssistantSheetTab.activity) _viewActivity();
  }

  void _back() {
    if (_fromMore) {
      setState(() {
        _fromMore = false;
        _tab = AssistantSheetTab.more;
      });
      return;
    }
    Navigator.of(context).maybePop();
  }

  /// Takes the person to the chat and sends [text] there as a normal message.
  void _sendToChat(String text) {
    final omniId = storedOmniChatId();
    final active = ref.read(activeConversationProvider)?.id;
    final chatId = omniId ?? active;
    if (chatId == null) return;
    final open = ref.read(assistantOpenChatProvider);
    final reply = ref.read(routineReplyProvider.notifier);
    Navigator.of(context).maybePop();
    if (active != chatId) unawaited(open(chatId));
    reply.request(RoutineReplyRequest(chatId: chatId, text: text));
  }

  Future<void> _startFeedRun() async {
    final l10n = AppLocalizations.of(context)!;
    final started = await ref.read(feedProvider.notifier).startRun();
    if (!mounted) return;
    AdaptiveSnackBar.show(
      context,
      message: started
          ? l10n.museyFeedRefreshStarted
          : l10n.museyFeedRefreshFailed,
      type: AdaptiveSnackBarType.info,
    );
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

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    // Routines come from the account's scheduled tasks and from the routines
    // server, so the page is there when either exists.
    final routinesAvailable =
        ref.watch(automationsAvailableProvider) ||
        ref.watch(
          appSettingsProvider.select((s) => s.routinesServerUrl.isNotEmpty),
        );
    final approval = ref.watch(assistantApprovalProvider);
    final tab = _tab == AssistantSheetTab.routines && !routinesAvailable
        ? AssistantSheetTab.activity
        : _tab;
    final title = switch (tab) {
      AssistantSheetTab.activity => l10n.assistantSheetTabActivity,
      AssistantSheetTab.approvals => l10n.assistantSheetTabApprovals,
      AssistantSheetTab.routines => l10n.assistantSheetTabRoutines,
      AssistantSheetTab.appearance => l10n.assistantSheetTabAppearance,
      AssistantSheetTab.feed => l10n.museyTabFeed,
      AssistantSheetTab.ideas => l10n.museyTabIdeas,
      AssistantSheetTab.more || AssistantSheetTab.chat => l10n.museyTabMore,
    };
    final hasCalls = ref.watch(
      assistantActionLogProvider.select((log) => log.records.isNotEmpty),
    );
    final Widget? action = switch (tab) {
      // The pages with a real action: clear the log, start a Feed run.
      AssistantSheetTab.activity => _RoundButton(
        key: const ValueKey('assistant-activity-clear'),
        symbol: 'trash',
        label: l10n.clear,
        onTap: hasCalls ? _confirmClear : null,
      ),
      AssistantSheetTab.feed => _RoundButton(
        key: const ValueKey('musey-feed-refresh'),
        symbol: 'arrow.clockwise',
        label: l10n.museyFeedRefresh,
        onTap: _startFeedRun,
      ),
      _ => null,
    };
    final back = _fromMore;
    // A Scaffold, so snack bars and the keyboard inset work on this page.
    return Scaffold(
      key: const ValueKey('assistant-sheet-body'),
      backgroundColor: theme.surfaceBackground,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                Spacing.screenPadding,
                Spacing.xs,
                Spacing.screenPadding,
                0,
              ),
              child: _PageTopRow(
                modelName: widget.modelName,
                avatar: widget.avatar,
                leadingSymbol: back ? 'chevron.left' : 'line.3.horizontal',
                onLeading: _back,
                action: action,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Spacing.screenPadding,
              Spacing.lg,
              Spacing.screenPadding,
              Spacing.sm,
            ),
            // The interests button rides at the right of the title line
            // without making it taller, so the title keeps its place on
            // every tab.
            child: Stack(
              children: [
                Padding(
                  padding: EdgeInsets.only(
                    right: tab == AssistantSheetTab.feed ? _roundButtonSize : 0,
                  ),
                  child: Text(
                    title,
                    key: const ValueKey('assistant-page-title'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.titleLargeStyle.copyWith(
                      color: theme.textPrimary,
                      fontSize: 28,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                if (tab == AssistantSheetTab.feed)
                  Positioned.fill(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: SizedBox(
                        width: _roundButtonSize,
                        height: _roundButtonSize,
                        child: _RoundButton(
                          key: const ValueKey('musey-feed-interests'),
                          symbol: 'slider.horizontal.3',
                          label: l10n.museyFeedInterests,
                          onTap: () =>
                              unawaited(showFeedInterestsSheet(context)),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Spacing.screenPadding,
              ),
              child: switch (tab) {
                AssistantSheetTab.feed => FeedTab(onDiscuss: _sendToChat),
                AssistantSheetTab.ideas => IdeasTab(onOpen: _sendToChat),
                AssistantSheetTab.more ||
                AssistantSheetTab.chat => _MoreTab(onSelect: _openFromMore),
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
                    modelName: widget.modelName,
                    avatar: widget.avatar,
                  ),
                ),
              },
            ),
          ),
          OmniTabBar(selected: tab, onOpen: _select),
        ],
      ),
    );
  }
}

/// The More page: Activity, Approvals and Appearance as rows.
class _MoreTab extends ConsumerWidget {
  const _MoreTab({required this.onSelect});

  final void Function(AssistantSheetTab tab) onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final failures = ref.watch(
      assistantActionLogProvider.select((log) => log.unseenFailures),
    );
    final waiting = ref.watch(assistantApprovalProvider) != null;
    return ListView(
      key: const ValueKey('musey-more-list'),
      children: [
        const MuseyDivider(),
        MoreRow(
          key: const ValueKey('musey-more-activity'),
          symbol: 'list.bullet.rectangle',
          label: l10n.assistantSheetTabActivity,
          hint: l10n.museyMoreActivityHint,
          badgeColor: failures > 0 ? theme.error : null,
          onTap: () => onSelect(AssistantSheetTab.activity),
        ),
        const MuseyDivider(),
        MoreRow(
          key: const ValueKey('musey-more-approvals'),
          symbol: 'checkmark.seal',
          label: l10n.assistantSheetTabApprovals,
          hint: l10n.museyMoreApprovalsHint,
          badgeColor: waiting ? theme.warning : null,
          onTap: () => onSelect(AssistantSheetTab.approvals),
        ),
        const MuseyDivider(),
        MoreRow(
          key: const ValueKey('musey-more-appearance'),
          symbol: 'paintpalette',
          label: l10n.assistantSheetTabAppearance,
          hint: l10n.museyMoreAppearanceHint,
          onTap: () => onSelect(AssistantSheetTab.appearance),
        ),
        const MuseyDivider(),
      ],
    );
  }
}

/// A 44 pt round button of the page's top row, the same control the chat
/// page's app bar uses.
class _RoundButton extends StatelessWidget {
  const _RoundButton({
    super.key,
    required this.symbol,
    required this.label,
    required this.onTap,
  });

  final String symbol;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    return Opacity(
      opacity: onTap == null ? 0.4 : 1,
      child: Tooltip(
        message: label,
        child: ConduitAdaptiveAppBarIconButton(
          icon: cupertinoIconForSFSymbol(symbol)!,
          iosSymbol: symbol,
          semanticLabel: label,
          onPressed: onTap,
          iconColor: theme.textPrimary,
        ),
      ),
    );
  }
}

const double _roundButtonSize = 44;

/// The top row: the round menu button (back to the chat, or to More), the
/// persona's avatar and name in a pill, and the page's own action when it has
/// one.
class _PageTopRow extends StatelessWidget {
  const _PageTopRow({
    required this.modelName,
    required this.avatar,
    required this.leadingSymbol,
    required this.onLeading,
    required this.action,
  });

  final String? modelName;
  final Widget? avatar;
  final String leadingSymbol;
  final VoidCallback onLeading;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final name = modelName?.trim() ?? '';
    final initial = name.isEmpty
        ? ''
        : String.fromCharCodes(name.runes.take(1)).toUpperCase();
    return SizedBox(
      height: _roundButtonSize,
      child: Row(
        children: [
          SizedBox(
            width: _roundButtonSize,
            height: _roundButtonSize,
            child: KeyedSubtree(
              key: const ValueKey('assistant-page-menu'),
              child: _RoundButton(
                symbol: leadingSymbol,
                label: l10n.back,
                onTap: onLeading,
              ),
            ),
          ),
          Expanded(
            child: Center(
              child: Container(
                key: const ValueKey('assistant-sheet-pill'),
                height: 36,
                padding: const EdgeInsets.only(right: Spacing.md, left: 4),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(AppBorderRadius.round),
                  color: theme.surfaceContainer,
                  border: Border.all(color: theme.cardBorder, width: 0.5),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      key: const ValueKey('assistant-sheet-avatar'),
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: theme.surfaceContainerHighest,
                      ),
                      child: ClipOval(
                        child:
                            avatar ??
                            Center(
                              child: Text(
                                initial,
                                style: AppTypography.labelStyle.copyWith(
                                  color: theme.textPrimary,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                      ),
                    ),
                    const SizedBox(width: Spacing.sm),
                    Flexible(
                      child: Text(
                        name.isEmpty ? l10n.assistantAvatar : name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.bodyMediumStyle.copyWith(
                          color: theme.textPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          SizedBox(
            width: _roundButtonSize,
            height: _roundButtonSize,
            child: action,
          ),
        ],
      ),
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
        if (filter != null)
          Align(
            alignment: Alignment.centerLeft,
            child: AdaptiveChip.input(
              key: const ValueKey('assistant-activity-filter'),
              label: Text(l10n.assistantActivityFromReply),
              onDeleted: widget.onClearFilter,
              deleteButtonTooltipMessage: l10n.assistantActivityShowAll,
            ),
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
  const _AppearanceTab({
    required this.store,
    this.onChanged,
    this.modelName,
    this.avatar,
  });

  final AssistantAvatarMediaStore store;
  final Future<void> Function()? onChanged;
  final String? modelName;
  final Widget? avatar;

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
    final media = await widget.store.load(
      personaId: ref.read(activePersonaAppearanceProvider)?.id,
    );
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
    final persona = ref.watch(activePersonaAppearanceProvider);
    final name = (persona?.name.trim().isNotEmpty ?? false)
        ? persona!.name.trim()
        : (widget.modelName?.trim() ?? '');
    final voice = ref.watch(
      directVoiceProviderProvider.select((v) => v?.settings.speechVoice),
    );
    final initial = name.isEmpty
        ? ''
        : String.fromCharCodes(name.runes.take(1)).toUpperCase();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // The active persona: a larger avatar, its name and its voice.
        Padding(
          key: const ValueKey('assistant-appearance-header'),
          padding: const EdgeInsets.only(bottom: Spacing.md),
          child: Column(
            children: [
              Container(
                width: 88,
                height: 88,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: theme.surfaceContainer,
                  border: Border.all(color: theme.cardBorder, width: 0.5),
                ),
                child: ClipOval(
                  child:
                      widget.avatar ??
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
              if (name.isNotEmpty) ...[
                const SizedBox(height: Spacing.sm),
                Text(
                  name,
                  style: AppTypography.bodyLargeStyle.copyWith(
                    color: theme.textPrimary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
              if (voice != null && voice.trim().isNotEmpty)
                Text(
                  l10n.museyAppearanceVoice(voice.trim()),
                  key: const ValueKey('assistant-appearance-voice'),
                  style: AppTypography.bodySmallStyle.copyWith(
                    color: theme.textSecondary,
                  ),
                ),
            ],
          ),
        ),
        for (final state in AssistantActivity.values) ...[
          const MuseyDivider(),
          _buildRow(context, l10n, theme, state),
        ],
        const MuseyDivider(),
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
      padding: const EdgeInsets.symmetric(vertical: Spacing.sm),
      child: Row(
        children: [
          // A small muted loop of the state's own clip, or a quiet square.
          _ClipPreview(
            key: ValueKey('assistant-avatar-preview-${state.name}'),
            media: _media.ownMedia(state),
          ),
          const SizedBox(width: Spacing.md),
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

/// A 56 pt rounded square showing [media] as a muted, looping clip (or an
/// image), and a quiet empty square when there is none. It plays only while
/// it is on screen and the app is active, and with Reduce Motion it shows
/// the first frame and stays still. It owns its player and lets it go when
/// the page is left.
class _ClipPreview extends StatefulWidget {
  const _ClipPreview({super.key, required this.media});

  final AssistantAvatarMedia? media;

  @override
  State<_ClipPreview> createState() => _ClipPreviewState();
}

class _ClipPreviewState extends State<_ClipPreview>
    with WidgetsBindingObserver {
  static const double _size = 56;

  VideoPlayerController? _controller;
  bool _ready = false;
  bool _failed = false;
  bool _still = false;
  bool _active = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _open();
  }

  @override
  void didUpdateWidget(_ClipPreview old) {
    super.didUpdateWidget(old);
    if (old.media?.id != widget.media?.id) {
      _close();
      _open();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (still != _still) {
      _still = still;
      unawaited(_sync());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _active = state == AppLifecycleState.resumed;
    unawaited(_sync());
  }

  void _open() {
    final media = widget.media;
    if (media == null || media.kind != AssistantAvatarMediaKind.video) return;
    try {
      // Silent, and mixing with other apps' audio, like the avatar's clips.
      final options = VideoPlayerOptions(mixWithOthers: true);
      final controller = media.isBundled
          ? VideoPlayerController.asset(media.path, videoPlayerOptions: options)
          : VideoPlayerController.file(
              File(media.path),
              videoPlayerOptions: options,
            );
      _controller = controller;
      unawaited(() async {
        try {
          await controller.initialize();
          await controller.setLooping(true);
          await controller.setVolume(0);
          if (!mounted || _controller != controller) return;
          setState(() => _ready = true);
          await _sync();
        } catch (_) {
          if (mounted && _controller == controller) {
            setState(() => _failed = true);
          }
        }
      }());
    } catch (_) {
      _failed = true;
    }
  }

  Future<void> _sync() async {
    final controller = _controller;
    if (controller == null || !_ready || !mounted) return;
    try {
      if (_active && !_still) {
        await controller.play();
      } else {
        await controller.pause();
        if (_still) await controller.seekTo(Duration.zero);
      }
    } catch (_) {}
  }

  void _close() {
    final controller = _controller;
    _controller = null;
    _ready = false;
    _failed = false;
    if (controller != null) unawaited(controller.dispose());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final media = widget.media;
    Widget content;
    final controller = _controller;
    if (media != null &&
        media.kind == AssistantAvatarMediaKind.image &&
        !media.isBundled) {
      content = Image.file(
        File(media.path),
        width: _size,
        height: _size,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => const SizedBox.shrink(),
      );
    } else if (controller != null && _ready && !_failed) {
      final size = controller.value.size;
      content = FittedBox(
        fit: BoxFit.cover,
        clipBehavior: Clip.hardEdge,
        child: SizedBox(
          width: size.width <= 0 ? _size : size.width,
          height: size.height <= 0 ? _size : size.height,
          child: VideoPlayer(controller),
        ),
      );
    } else {
      content = const SizedBox.shrink();
    }
    return Container(
      width: _size,
      height: _size,
      decoration: BoxDecoration(
        color: theme.surfaceContainer,
        borderRadius: BorderRadius.circular(14),
      ),
      clipBehavior: Clip.antiAlias,
      child: content,
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
          // Rows of four, each cell an equal share of the width, so eight
          // swatches read as two even rows and not five and three.
          Column(
            key: const ValueKey('bubble-color-grid'),
            children: [
              for (var i = 0; i < options.length; i += 4)
                Padding(
                  padding: EdgeInsets.only(top: i == 0 ? 0 : Spacing.sm),
                  child: Row(
                    children: [
                      for (var j = i; j < i + 4; j++)
                        Expanded(
                          child: j < options.length
                              ? Center(child: options[j])
                              : const SizedBox.shrink(),
                        ),
                    ],
                  ),
                ),
            ],
          ),
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
                textAlign: TextAlign.center,
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
