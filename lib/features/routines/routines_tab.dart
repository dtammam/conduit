import 'dart:async';

import 'package:conduit/features/automations/views/scheduled_task_format.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/services/navigation_service.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/widgets/adaptive_date_time_picker.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit_core/features/automations/automation_schedule.dart';
import 'package:conduit_core/features/automations/models/automation.dart';
import 'package:conduit_core/features/automations/providers/automation_providers.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'push_registration.dart';
import 'routines_providers.dart';
import 'routines_service.dart';

/// Every automation, paused ones included, soonest next run first; the
/// paused ones follow, by name.
List<Automation> sortRoutines(Iterable<Automation> tasks) {
  final list = tasks.toList();
  list.sort((a, b) {
    final an = a.nextRunNs;
    final bn = b.nextRunNs;
    if (an != null && bn != null) return an.compareTo(bn);
    if (an != null) return -1;
    if (bn != null) return 1;
    if (a.isActive != b.isActive) return a.isActive ? -1 : 1;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });
  return list;
}

/// What to show for a routine's latest run, or null for nothing: the first
/// lines of its last reply, or "Nothing new" when the latest run had nothing
/// to say.
({String? text, DateTime? quietAt})? routineResultLine(RoutineLast? last) {
  if (last == null) return null;
  final quiet = last.quietAt;
  final at = last.at;
  if (quiet != null && (at == null || quiet.isAfter(at))) {
    return (text: null, quietAt: quiet);
  }
  final text = last.text.trim();
  if (text.isEmpty) return null;
  return (text: text, quietAt: null);
}

/// The Routines tab of the assistant sheet: every automation with its
/// schedule, next run and last result and an on/off switch, then quiet hours
/// and notifications for the routines server.
class RoutinesTab extends ConsumerStatefulWidget {
  const RoutinesTab({super.key});

  @override
  ConsumerState<RoutinesTab> createState() => _RoutinesTabState();
}

class _RoutinesTabState extends ConsumerState<RoutinesTab> {
  final Set<String> _toggling = <String>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(ref.read(pushRegistrationProvider.notifier).refresh());
      unawaited(_loadAllPages());
    });
  }

  /// The list loads a page at a time; a routines list is short, so the rest
  /// come in straight away.
  Future<void> _loadAllPages() async {
    try {
      final notifier = ref.read(automationsProvider.notifier);
      final owner = notifier.captureOwner();
      if (owner == null) return;
      for (var i = 0; i < 10; i++) {
        final data = ref.read(automationsProvider).asData?.value;
        if (data == null || !data.hasMore || !mounted) return;
        await notifier.loadMore(owner: owner);
      }
    } catch (_) {
      // A list that failed to load shows its error state; the user's own
      // refresh is the retry.
    }
  }

  Future<void> _toggle(Automation task, bool active) async {
    final l10n = AppLocalizations.of(context)!;
    final notifier = ref.read(automationsProvider.notifier);
    final owner = notifier.captureOwner();
    if (owner == null) return;
    setState(() => _toggling.add(task.id));
    try {
      await notifier.setActive(task.id, active, owner: owner);
    } catch (error) {
      if (mounted) {
        AdaptiveSnackBar.show(
          context,
          message: scheduledTaskErrorText(
            l10n,
            error,
            fallback: l10n.routinesToggleFailed,
          ),
          type: AdaptiveSnackBarType.error,
        );
      }
    } finally {
      if (mounted) setState(() => _toggling.remove(task.id));
    }
  }

  void _open(Automation task) {
    Navigator.of(context).maybePop();
    unawaited(
      NavigationService.router.pushNamed<void>(
        RouteNames.scheduledTaskDetail,
        pathParameters: {'id': task.id},
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final tasks = ref.watch(automationsProvider);
    final data = tasks.asData?.value;
    final server = ref.watch(routinesServerProvider).asData?.value;
    final lasts = ref.watch(routinesLastProvider).asData?.value;

    final children = <Widget>[];
    if (data == null && tasks.isLoading) {
      children.add(
        const Padding(
          padding: EdgeInsets.symmetric(vertical: Spacing.lg),
          child: Center(child: AdaptiveProgressIndicator.activity()),
        ),
      );
    } else {
      final sorted = sortRoutines(data?.items ?? const <Automation>[]);
      if (sorted.isEmpty) {
        children.add(
          Padding(
            padding: const EdgeInsets.symmetric(vertical: Spacing.lg),
            child: Text(
              l10n.routinesEmpty,
              key: const ValueKey('routines-empty'),
              textAlign: TextAlign.center,
              style: AppTypography.bodyMediumStyle.copyWith(
                color: theme.textSecondary,
              ),
            ),
          ),
        );
      }
      for (final task in sorted) {
        children.add(
          _RoutineRow(
            task: task,
            last: lasts?[routineSlugOf(task.prompt)],
            busy: _toggling.contains(task.id),
            onToggle: (value) => _toggle(task, value),
            onTap: () => _open(task),
          ),
        );
      }
      if (server != null && lasts == null && sorted.isNotEmpty) {
        children.add(
          _Note(
            key: const ValueKey('routines-last-unavailable'),
            text: l10n.routinesServerUnavailable,
          ),
        );
      }
    }

    children
      ..add(const SizedBox(height: Spacing.md))
      ..add(_SectionTitle(l10n.routinesQuietHours))
      ..add(
        server == null
            ? _Note(
                key: const ValueKey('routines-quiet-unset'),
                text: l10n.routinesServerNotSet,
              )
            : const _QuietHoursSection(),
      )
      ..add(const SizedBox(height: Spacing.md))
      ..add(_SectionTitle(l10n.routinesNotifications))
      ..add(_NotificationsSection(serverSet: server != null));

    return ListView(children: children);
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.xs),
      child: Text(
        text,
        style: AppTypography.bodyMediumStyle.copyWith(
          color: theme.textPrimary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Spacing.xs),
      child: Text(
        text,
        style: AppTypography.bodySmallStyle.copyWith(
          color: theme.textSecondary,
        ),
      ),
    );
  }
}

String _moment(BuildContext context, DateTime time) {
  final locale = Localizations.localeOf(context).toString();
  final date = DateFormat.MMMd(locale);
  return (MediaQuery.alwaysUse24HourFormatOf(context)
          ? date.add_Hm()
          : date.add_jm())
      .format(time);
}

class _RoutineRow extends StatelessWidget {
  const _RoutineRow({
    required this.task,
    required this.last,
    required this.busy,
    required this.onToggle,
    required this.onTap,
  });

  final Automation task;
  final RoutineLast? last;
  final bool busy;
  final ValueChanged<bool> onToggle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final next = formatServerTime(context, task.nextRunNs);
    final schedule = AutomationSchedule.parse(task.rrule);
    final subtitle = [
      if (schedule is RawAutomationSchedule)
        l10n.scheduledTaskScheduleCustom
      else
        scheduleSummary(context, l10n, schedule),
      if (!task.isActive)
        l10n.scheduledTaskStatusPaused
      else if (next == null)
        l10n.scheduledTaskNoNextRun
      else
        l10n.scheduledTaskNextRun(next),
    ].join(' · ');
    final result = routineResultLine(last);
    return GestureDetector(
      key: ValueKey('routine-row-${task.id}'),
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Spacing.xs),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    task.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.bodyLargeStyle.copyWith(
                      color: task.isActive
                          ? theme.textPrimary
                          : theme.textSecondary,
                    ),
                  ),
                  Text(
                    subtitle,
                    style: AppTypography.bodySmallStyle.copyWith(
                      color: theme.textSecondary,
                    ),
                  ),
                  if (result != null)
                    Padding(
                      padding: const EdgeInsets.only(top: Spacing.xxs),
                      child: Text(
                        result.text ??
                            l10n.routinesNothingNew(
                              _moment(context, result.quietAt!),
                            ),
                        key: ValueKey('routine-result-${task.id}'),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.bodySmallStyle.copyWith(
                          color: theme.textSecondary,
                          fontStyle: result.text == null
                              ? FontStyle.italic
                              : FontStyle.normal,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: Spacing.sm),
            AdaptiveSwitch(
              key: ValueKey('routine-switch-${task.id}'),
              value: task.isActive,
              onChanged: busy ? null : onToggle,
              semanticLabel: task.name,
            ),
          ],
        ),
      ),
    );
  }
}

class _QuietHoursSection extends ConsumerWidget {
  const _QuietHoursSection();

  static ({int hour, int minute})? _parse(String value) {
    final parts = value.split(':');
    if (parts.length != 2) return null;
    final hour = int.tryParse(parts[0]);
    final minute = int.tryParse(parts[1]);
    if (hour == null || minute == null) return null;
    return (hour: hour, minute: minute);
  }

  static String _format(({int hour, int minute}) time) =>
      '${time.hour.toString().padLeft(2, '0')}:'
      '${time.minute.toString().padLeft(2, '0')}';

  Future<void> _pick(
    BuildContext context,
    WidgetRef ref, {
    required String current,
    required bool start,
  }) async {
    final initial = _parse(current) ?? (hour: 22, minute: 0);
    final picked = await showAdaptiveHourMinutePicker(
      context,
      hour: initial.hour,
      minute: initial.minute,
    );
    if (picked == null) return;
    final controller = ref.read(pushSettingsProvider.notifier);
    if (start) {
      await controller.change(quietStart: _format(picked));
    } else {
      await controller.change(quietEnd: _format(picked));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final settings = ref.watch(pushSettingsProvider);
    final value = settings.asData?.value;
    if (value == null) {
      return settings.isLoading
          ? const Padding(
              padding: EdgeInsets.symmetric(vertical: Spacing.md),
              child: Center(child: AdaptiveProgressIndicator.activity()),
            )
          : _Note(
              key: const ValueKey('routines-quiet-unavailable'),
              text: l10n.routinesServerUnavailable,
            );
    }
    Widget timeRow(String label, String time, bool start) {
      final parsed = _parse(time);
      return GestureDetector(
        key: ValueKey('routines-quiet-${start ? 'start' : 'end'}'),
        behavior: HitTestBehavior.opaque,
        onTap: () => _pick(context, ref, current: time, start: start),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: Spacing.xs),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: AppTypography.bodyLargeStyle.copyWith(
                    color: value.quiet
                        ? theme.textPrimary
                        : theme.textSecondary,
                  ),
                ),
              ),
              Text(
                parsed == null
                    ? time
                    : formatWallClockTime(context, parsed.hour, parsed.minute),
                style: AppTypography.bodyLargeStyle.copyWith(
                  color: theme.textSecondary,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                l10n.routinesQuietHoursDescription,
                style: AppTypography.bodySmallStyle.copyWith(
                  color: theme.textSecondary,
                ),
              ),
            ),
            const SizedBox(width: Spacing.sm),
            AdaptiveSwitch(
              key: const ValueKey('routines-quiet-switch'),
              value: value.quiet,
              onChanged: (on) => unawaited(
                ref.read(pushSettingsProvider.notifier).change(quiet: on),
              ),
              semanticLabel: l10n.routinesQuietHours,
            ),
          ],
        ),
        timeRow(l10n.routinesQuietFrom, value.quietStart, true),
        timeRow(l10n.routinesQuietUntil, value.quietEnd, false),
      ],
    );
  }
}

class _NotificationsSection extends ConsumerStatefulWidget {
  const _NotificationsSection({required this.serverSet});

  final bool serverSet;

  @override
  ConsumerState<_NotificationsSection> createState() =>
      _NotificationsSectionState();
}

class _NotificationsSectionState extends ConsumerState<_NotificationsSection> {
  bool _sending = false;

  Future<void> _turnOn() async {
    final ok = await ref.read(pushRegistrationProvider.notifier).enable();
    if (!mounted || ok) return;
    AdaptiveSnackBar.show(
      context,
      message: AppLocalizations.of(context)!.routinesPushDenied,
      type: AdaptiveSnackBarType.error,
    );
  }

  Future<void> _sendTest() async {
    final l10n = AppLocalizations.of(context)!;
    final server = await ref.read(routinesServerProvider.future);
    if (server == null || !mounted) return;
    setState(() => _sending = true);
    final ok = await ref
        .read(routinesServiceProvider)
        .sendTest(
          base: server.base,
          token: server.token,
          title: l10n.routinesTestTitle,
          body: l10n.routinesTestBody,
        );
    if (!mounted) return;
    setState(() => _sending = false);
    AdaptiveSnackBar.show(
      context,
      message: ok ? l10n.routinesTestSent : l10n.routinesServerUnavailable,
      type: ok ? AdaptiveSnackBarType.success : AdaptiveSnackBarType.error,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final platform = ref.watch(pushPlatformProvider);
    if (!platform.supported) {
      return _Note(
        key: const ValueKey('routines-push-unsupported'),
        text: l10n.routinesPushUnsupported,
      );
    }
    if (!widget.serverSet) {
      return _Note(
        key: const ValueKey('routines-push-unset'),
        text: l10n.routinesServerNotSet,
      );
    }
    final status = ref.watch(pushRegistrationProvider);
    final enabled = ref.watch(
      appSettingsProvider.select((s) => s.routinesPushEnabled),
    );
    final permission = switch (status.authorization) {
      'authorized' || 'provisional' || 'ephemeral' => l10n.routinesPushAllowed,
      'denied' => l10n.routinesPushDenied,
      _ => l10n.routinesPushNotAsked,
    };
    final server = enabled && status.registered
        ? l10n.routinesPushRegistered
        : l10n.routinesPushNotRegistered;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          permission,
          key: const ValueKey('routines-push-permission'),
          style: AppTypography.bodyMediumStyle.copyWith(
            color: theme.textPrimary,
          ),
        ),
        Text(
          server,
          key: const ValueKey('routines-push-registered'),
          style: AppTypography.bodySmallStyle.copyWith(
            color: theme.textSecondary,
          ),
        ),
        const SizedBox(height: Spacing.sm),
        Row(
          children: [
            if (!enabled || !status.allowed)
              AdaptiveButton(
                key: const ValueKey('routines-push-turn-on'),
                onPressed: status.busy ? null : _turnOn,
                label: l10n.routinesPushTurnOn,
                style: AdaptiveButtonStyle.tinted,
                size: AdaptiveButtonSize.small,
                useNative: false,
              )
            else ...[
              AdaptiveButton(
                key: const ValueKey('routines-push-test'),
                onPressed: _sending ? null : _sendTest,
                label: l10n.routinesSendTest,
                style: AdaptiveButtonStyle.tinted,
                size: AdaptiveButtonSize.small,
                useNative: false,
              ),
              const SizedBox(width: Spacing.xs),
              AdaptiveButton(
                key: const ValueKey('routines-push-turn-off'),
                onPressed: () => unawaited(
                  ref.read(pushRegistrationProvider.notifier).disable(),
                ),
                label: l10n.routinesPushTurnOff,
                size: AdaptiveButtonSize.small,
                useNative: false,
              ),
            ],
          ],
        ),
      ],
    );
  }
}
