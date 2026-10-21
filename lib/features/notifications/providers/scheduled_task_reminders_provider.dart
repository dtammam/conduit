import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:conduit_core/features/automations/models/automation.dart';
import 'package:conduit_core/features/automations/providers/automation_providers.dart';
import 'package:conduit_core/features/notifications/models/app_notification.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/settings_service.dart';

import '../../../core/utils/current_localizations.dart';
import '../services/local_notification_service.dart';
import '../services/scheduled_task_reminders.dart';

/// Whether this device can hold scheduled task reminders (iOS).
final scheduledTaskRemindersSupportedProvider = Provider<bool>(
  (ref) =>
      ref.read(localNotificationServiceProvider).supportsScheduledNotifications,
);

/// Whether reminders should be scheduled: the device supports them,
/// notifications are on and the user turned reminders on.
bool scheduledTaskRemindersWanted(AppSettings settings) =>
    settings.notificationsEnabled &&
    settings.notificationScheduledTaskReminders;

/// [LocalNotificationService] as the reminders see it.
class LocalScheduledReminderNotifications
    implements ScheduledReminderNotifications {
  LocalScheduledReminderNotifications(
    this._local, {
    required bool Function() playSound,
  }) : _playSound = playSound;

  final LocalNotificationService _local;
  final bool Function() _playSound;

  @override
  bool get supported => _local.supportsScheduledNotifications;

  @override
  Future<List<PendingScheduledReminder>> pending() async => [
    for (final request in await _local.pendingNotifications())
      (id: request.id, title: request.title, payload: request.payload),
  ];

  @override
  Future<void> schedule(
    ScheduledTaskReminder reminder, {
    required String title,
  }) {
    return _local.scheduleAt(
      id: reminder.id,
      title: title,
      // The reply is not known when this is scheduled, so the text cannot
      // quote it; it only says the task ran.
      body: currentAppLocalizations().scheduledTaskReminderBody,
      fireAt: reminder.fireAt,
      payload: reminder.payload,
      playSound: _playSound(),
      // In the foreground the socket's in-app banner covers the reply, so a
      // reminder that comes due then is not shown a second time.
      presentInForeground: false,
    );
  }

  @override
  Future<void> cancel(int id) => _local.cancel(id);
}

/// The pending reminders this app holds, kept for the app's lifetime so a
/// settings or account change does not forget what was scheduled.
final scheduledTaskReminderSyncProvider = Provider<ScheduledTaskReminderSync>((
  ref,
) {
  return ScheduledTaskReminderSync(
    notifications: LocalScheduledReminderNotifications(
      ref.read(localNotificationServiceProvider),
      playSound: () => ref.read(appSettingsProvider).notificationSound,
    ),
    fallbackTitle: () => currentAppLocalizations().scheduledTasksTitle,
  );
});

/// Resyncs reminders whenever what they depend on changes, and on resume.
///
/// Read once after sign-in. It rebuilds when the toggle, the account or the
/// server changes; every build syncs once, which schedules for the account
/// now signed in or cancels every reminder when they are off.
final scheduledTaskRemindersProvider = Provider<ScheduledTaskReminders>((ref) {
  final supported = ref.watch(scheduledTaskRemindersSupportedProvider);
  final wanted = ref.watch(
    appSettingsProvider.select(scheduledTaskRemindersWanted),
  );
  ref.watch(activeServerProvider.select((server) => server.asData?.value?.id));
  ref.watch(openWebUiAuthSessionEpochProvider);
  final enabled = supported && wanted;

  final controller = ScheduledTaskReminders(
    sync: ref.read(scheduledTaskReminderSyncProvider),
    enabled: enabled,
    loadTasks: () => loadScheduledTasksForReminders(ref),
  );
  ref.onDispose(controller.dispose);

  if (enabled) {
    // A create, edit, pause or delete in the app reloads this list.
    ref.listen<AsyncValue<AutomationsData>>(automationsProvider, (
      previous,
      next,
    ) {
      final data = next.asData?.value;
      if (data != null && !identical(previous?.asData?.value, data)) {
        controller.request();
      }
    });
    ref.listen<bool>(automationsAvailableProvider, (_, _) {
      controller.request();
    });
    final lifecycle = AppLifecycleListener(onResume: controller.request);
    ref.onDispose(lifecycle.dispose);
  }
  controller.request();
  return controller;
});

/// The signed-in account's active tasks with their upcoming runs, or null
/// when no account can hold reminders: signed out, or the server or the
/// account does not allow scheduled tasks. A failure to tell (offline) throws,
/// so the reminders already scheduled stay.
Future<List<Automation>?> loadScheduledTasksForReminders(Ref ref) async {
  final notifier = ref.read(automationsProvider.notifier);
  final owner = notifier.captureOwner();
  if (owner == null) return null;
  try {
    return await notifier.activeTasksWithUpcomingRuns(
      owner: owner,
      maxTasks: scheduledTaskRemindersMax,
    );
  } on AutomationsUnavailableException {
    final settled =
        ref.read(userPermissionsProvider).hasValue &&
        ref.read(backendConfigProvider).hasValue;
    if (settled) return null;
    rethrow;
  }
}

/// The task a reminder points at, as the server holds it now, or null when
/// no account is signed in.
Future<Automation?> fetchScheduledTaskForReminder(Ref ref, String id) async {
  final notifier = ref.read(automationsProvider.notifier);
  final owner = notifier.captureOwner();
  if (owner == null) return null;
  return notifier.fetch(id, owner: owner);
}

/// One build's view of the reminders: whether they are on, and how to load
/// the tasks they come from.
class ScheduledTaskReminders {
  ScheduledTaskReminders({
    required ScheduledTaskReminderSync sync,
    required this.enabled,
    required Future<List<Automation>?> Function() loadTasks,
    Duration debounce = const Duration(milliseconds: 750),
  }) : _sync = sync,
       _loadTasks = loadTasks {
    _scheduler = ScheduledTaskReminderScheduler(run: _run, debounce: debounce);
  }

  final ScheduledTaskReminderSync _sync;
  final bool enabled;
  final Future<List<Automation>?> Function() _loadTasks;
  late final ScheduledTaskReminderScheduler _scheduler;

  /// Asks for a resync shortly; several requests close together cost one.
  void request() => _scheduler.request();

  /// Resyncs now, for example right after notification permission was
  /// granted.
  Future<void> syncNow() => _scheduler.runNow();

  Future<void> _run() async {
    if (!enabled) {
      await _sync.cancelAll();
      return;
    }
    final tasks = await _loadTasks();
    // A newer build (toggle, account or server change) took over while the
    // tasks loaded; what they would schedule is no longer wanted.
    if (_disposed) return;
    if (tasks == null) {
      await _sync.cancelAll();
      return;
    }
    await _sync.apply(tasks);
  }

  /// The socket alerted the user about [notification]; a reminder for the
  /// same run is cancelled so one run never alerts twice.
  Future<void> onSocketAlert(
    AppNotification notification, {
    required Future<Automation?> Function(String automationId) fetchTask,
  }) async {
    if (!enabled) return;
    await _sync.onSocketAlert(
      source: switch (notification.kind) {
        NotificationKind.chatCompletion => ScheduledTaskAlertSource.chat,
        NotificationKind.channelMessage => ScheduledTaskAlertSource.channel,
      },
      sourceId: notification.sourceId,
      fetchTask: fetchTask,
    );
  }

  bool _disposed = false;

  void dispose() {
    _disposed = true;
    _scheduler.dispose();
  }
}
