import 'package:checks/checks.dart';
import 'package:conduit/features/notifications/providers/scheduled_task_reminders_provider.dart';
import 'package:conduit/features/notifications/services/local_notification_service.dart';
import 'package:conduit/features/notifications/services/scheduled_task_reminders.dart';
import 'package:conduit_core/features/automations/models/automation.dart';
import 'package:conduit_core/features/notifications/models/app_notification.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

final _now = DateTime.utc(2024, 1, 1, 12);

int _ns(DateTime time) => time.toUtc().microsecondsSinceEpoch * 1000;

Automation _task(
  String id, {
  String name = 'Daily summary',
  bool active = true,
  List<DateTime>? runs,
  DateTime? nextRunAt,
  AutomationRun? lastRun,
}) => Automation(
  id: id,
  userId: 'user-1',
  name: name,
  data: const {'prompt': 'p', 'model_id': 'm', 'rrule': ''},
  isActive: active,
  nextRunAtNs: nextRunAt == null ? null : _ns(nextRunAt),
  nextRunsNs: runs?.map(_ns).toList(),
  lastRun: lastRun,
);

AutomationRun _run(String automationId, DateTime at, {String? chatId}) =>
    AutomationRun(
      id: 'run-$automationId-${at.millisecondsSinceEpoch}',
      automationId: automationId,
      status: AutomationRun.statusSuccess,
      chatId: chatId,
      createdAtNs: _ns(at),
    );

/// Records what the reminders ask of the system, and holds pending
/// notifications like iOS does.
class _FakeNotifications implements ScheduledReminderNotifications {
  final Map<int, PendingScheduledReminder> held = {};
  final List<int> cancelled = [];
  final List<int> scheduledIds = [];

  @override
  bool supported = true;

  @override
  Future<List<PendingScheduledReminder>> pending() async =>
      held.values.toList();

  @override
  Future<void> schedule(
    ScheduledTaskReminder reminder, {
    required String title,
  }) async {
    scheduledIds.add(reminder.id);
    held[reminder.id] = (
      id: reminder.id,
      title: title,
      payload: reminder.payload,
    );
  }

  @override
  Future<void> cancel(int id) async {
    cancelled.add(id);
    held.remove(id);
  }
}

class _MockLocal extends Mock implements LocalNotificationService {}

void main() {
  group('plan', () {
    test('takes each active task\'s next runs and fires a minute after', () {
      final plan = planScheduledTaskReminders([
        _task(
          'a',
          runs: [
            _now.add(const Duration(hours: 1)),
            _now.add(const Duration(days: 1, hours: 1)),
          ],
        ),
      ], now: _now);

      check(plan).length.equals(2);
      check(plan.first.fireAt)
          .equals(_now.add(const Duration(hours: 1, minutes: 1)));
      check(plan.first.name).equals('Daily summary');
      check(plan[1].fireAt)
          .equals(_now.add(const Duration(days: 1, hours: 1, minutes: 1)));
    });

    test('falls back to next_run_at when the task carries no next_runs', () {
      final plan = planScheduledTaskReminders([
        _task('a', nextRunAt: _now.add(const Duration(hours: 2))),
      ], now: _now);

      check(plan).length.equals(1);
      check(plan.single.runAtNs)
          .equals(_ns(_now.add(const Duration(hours: 2))));
    });

    test('skips paused tasks and runs whose reminder is already past', () {
      final plan = planScheduledTaskReminders([
        _task(
          'paused',
          active: false,
          runs: [_now.add(const Duration(hours: 1))],
        ),
        _task(
          'a',
          runs: [
            // Ran two minutes ago: its reminder fired a minute ago.
            _now.subtract(const Duration(minutes: 2)),
            // Ran 30 seconds ago: its reminder is still ahead.
            _now.subtract(const Duration(seconds: 30)),
          ],
        ),
      ], now: _now);

      check(plan).length.equals(1);
      check(plan.single.automationId).equals('a');
      check(plan.single.fireAt).equals(_now.add(const Duration(seconds: 30)));
    });

    test('holds at most three runs per task and forty in all, soonest '
        'first', () {
      final tasks = [
        for (var t = 0; t < 20; t++)
          _task(
            'task-$t',
            runs: [
              for (var r = 0; r < 5; r++)
                _now.add(Duration(hours: 1 + r * 24, minutes: t)),
            ],
          ),
      ];

      final plan = planScheduledTaskReminders(tasks, now: _now);

      check(plan).length.equals(scheduledTaskRemindersMax);
      final perTask = <String, int>{};
      for (final reminder in plan) {
        perTask.update(reminder.automationId, (n) => n + 1, ifAbsent: () => 1);
      }
      check(perTask.values.every((n) => n <= 3)).isTrue();
      for (var i = 1; i < plan.length; i++) {
        check(plan[i].fireAt.isBefore(plan[i - 1].fireAt)).isFalse();
      }
      // 20 tasks x 3 runs = 60 candidates; the 40 soonest are the first two
      // days' runs.
      check(
        plan.every((r) => r.fireAt.isBefore(_now.add(const Duration(days: 2)))),
      ).isTrue();
    });

    test('ids are stable, unique and inside the reminder block', () {
      final tasks = [
        for (var t = 0; t < 15; t++)
          _task(
            'task-$t',
            runs: [
              for (var r = 0; r < 3; r++)
                _now.add(Duration(hours: 1 + r, minutes: t)),
            ],
          ),
      ];
      final first = planScheduledTaskReminders(tasks, now: _now);
      final again = planScheduledTaskReminders(tasks, now: _now);

      check(first.map((r) => r.id).toSet()).length.equals(first.length);
      check(again.map((r) => r.id).toList())
          .deepEquals(first.map((r) => r.id).toList());
      for (final reminder in first) {
        check(isScheduledTaskReminderId(reminder.id)).isTrue();
      }
      // Message notifications count up from 1, far below the block.
      check(isScheduledTaskReminderId(1)).isFalse();
      check(isScheduledTaskReminderId(100000)).isFalse();
    });
  });

  group('payload', () {
    test('round-trips the task and the run', () {
      final runAt = _ns(_now);
      final tap = ScheduledTaskReminderTap.tryDecode(
        ScheduledTaskReminderTap(automationId: 'a', runAtNs: runAt).encode(),
      );
      check(tap).isNotNull();
      check(tap!.automationId).equals('a');
      check(tap.runAtNs).equals(runAt);
    });

    test('a message notification payload is not a reminder, nor the '
        'reverse', () {
      final message = NotificationTap.encode(
        const AppNotification(
          kind: NotificationKind.chatCompletion,
          title: 't',
          body: 'b',
          sourceId: 'chat-1',
          dedupKey: 'k',
        ),
      );
      check(ScheduledTaskReminderTap.tryDecode(message)).isNull();
      final reminder = const ScheduledTaskReminderTap(automationId: 'a')
          .encode();
      check(NotificationTap.tryDecode(reminder)).isNull();
    });
  });

  group('sync', () {
    late _FakeNotifications notifications;
    late ScheduledTaskReminderSync sync;
    var clock = _now;

    setUp(() {
      clock = _now;
      notifications = _FakeNotifications();
      sync = ScheduledTaskReminderSync(
        notifications: notifications,
        clock: () => clock,
        fallbackTitle: () => 'Scheduled tasks',
        alertMatchRetry: Duration.zero,
      );
    });

    final daily = _task(
      'daily',
      runs: [
        _now.add(const Duration(hours: 1)),
        _now.add(const Duration(days: 1, hours: 1)),
      ],
    );
    final weekly = _task(
      'weekly',
      name: 'Weekly review',
      runs: [_now.add(const Duration(days: 3))],
    );

    test('schedules the plan and leaves an unchanged one alone', () async {
      await sync.apply([daily, weekly]);
      check(notifications.held).length.equals(3);
      check(notifications.held.values.map((p) => p.title).toSet())
          .deepEquals({'Daily summary', 'Weekly review'});

      notifications.scheduledIds.clear();
      await sync.apply([daily, weekly]);
      check(notifications.scheduledIds).isEmpty();
      check(notifications.cancelled).isEmpty();
    });

    test('pausing a task cancels its reminders only', () async {
      await sync.apply([daily, weekly]);
      final weeklyIds = sync.scheduled
          .where((r) => r.automationId == 'weekly')
          .map((r) => r.id)
          .toSet();

      await sync.apply([
        daily,
        _task(
          'weekly',
          active: false,
          runs: [_now.add(const Duration(days: 3))],
        ),
      ]);

      check(notifications.cancelled.toSet()).deepEquals(weeklyIds);
      check(notifications.held).length.equals(2);
    });

    test('deleting a task cancels its reminders', () async {
      await sync.apply([daily, weekly]);
      await sync.apply([weekly]);

      check(notifications.held).length.equals(1);
      check(
        ScheduledTaskReminderTap.tryDecode(
          notifications.held.values.single.payload,
        )!.automationId,
      ).equals('weekly');
    });

    test('never cancels notifications that are not reminders', () async {
      // A pending notification outside the block, and one inside the block
      // whose payload is not a reminder's.
      notifications.held[7] = (id: 7, title: 'x', payload: '{"kind":"x"}');
      notifications.held[scheduledTaskReminderIdBase + 5] = (
        id: scheduledTaskReminderIdBase + 5,
        title: 'x',
        payload: null,
      );

      await sync.apply([daily]);
      await sync.apply(const []);
      await sync.cancelAll();

      check(notifications.held.keys.toSet())
          .deepEquals({7, scheduledTaskReminderIdBase + 5});
      check(notifications.cancelled.contains(7)).isFalse();
    });

    test('cancelAll removes every reminder', () async {
      await sync.apply([daily, weekly]);
      await sync.cancelAll();
      check(notifications.held).isEmpty();
      check(sync.scheduled).isEmpty();
    });

    test('does nothing where scheduling is not supported', () async {
      notifications.supported = false;
      await sync.apply([daily]);
      check(notifications.held).isEmpty();
    });

    test('a task without a name falls back to a generic title', () async {
      await sync.apply([
        _task('a', name: '  ', runs: [_now.add(const Duration(hours: 1))]),
      ]);
      check(notifications.held.values.single.title).equals('Scheduled tasks');
    });

    group('no double alert', () {
      final runAt = _now.add(const Duration(hours: 1));

      Future<void> runDue() async {
        await sync.apply([
          _task('a', runs: [runAt]),
        ]);
        // 20 seconds after the run: its reminder is 40 seconds away.
        clock = runAt.add(const Duration(seconds: 20));
      }

      test('a socket alert for the run\'s chat cancels its reminder', () async {
        await runDue();
        final id = sync.scheduled.single.id;

        await sync.onSocketAlert(
          source: ScheduledTaskAlertSource.chat,
          sourceId: 'chat-9',
          fetchTask: (_) async => _task(
            'a',
            lastRun: _run(
              'a',
              runAt.add(const Duration(seconds: 15)),
              chatId: 'chat-9',
            ),
          ),
        );

        check(notifications.cancelled).deepEquals([id]);
        check(notifications.held).isEmpty();

        // A resync before the reminder's time does not put it back.
        await sync.apply([
          _task('a', runs: [runAt]),
        ]);
        check(notifications.held).isEmpty();
      });

      test('an alert for another chat leaves the reminder', () async {
        await runDue();

        await sync.onSocketAlert(
          source: ScheduledTaskAlertSource.chat,
          sourceId: 'other-chat',
          fetchTask: (_) async =>
              _task('a', lastRun: _run('a', runAt, chatId: 'chat-9')),
        );

        check(notifications.cancelled).isEmpty();
        check(notifications.held).length.equals(1);
      });

      test('an older run with the same chat does not count', () async {
        await runDue();

        await sync.onSocketAlert(
          source: ScheduledTaskAlertSource.chat,
          sourceId: 'chat-9',
          fetchTask: (_) async => _task(
            'a',
            lastRun: _run(
              'a',
              runAt.subtract(const Duration(days: 1)),
              chatId: 'chat-9',
            ),
          ),
        );

        check(notifications.cancelled).isEmpty();
      });

      test('the run recorded just after the socket event is still '
          'matched', () async {
        await runDue();
        var reads = 0;

        await sync.onSocketAlert(
          source: ScheduledTaskAlertSource.chat,
          sourceId: 'chat-9',
          fetchTask: (_) async {
            reads++;
            return _task(
              'a',
              lastRun: reads < 2 ? null : _run('a', runAt, chatId: 'chat-9'),
            );
          },
        );

        check(reads).equals(2);
        check(notifications.held).isEmpty();
      });

      test('no task is read when no reminder is due', () async {
        await sync.apply([
          _task('a', runs: [runAt]),
        ]);
        var reads = 0;

        await sync.onSocketAlert(
          source: ScheduledTaskAlertSource.chat,
          sourceId: 'chat-9',
          fetchTask: (_) async {
            reads++;
            return null;
          },
        );

        check(reads).equals(0);
        check(notifications.held).length.equals(1);
      });

      test('reminders are scheduled silent in the foreground', () async {
        final local = _MockLocal();
        when(() => local.supportsScheduledNotifications).thenReturn(true);
        when(
          () => local.scheduleAt(
            id: any(named: 'id'),
            title: any(named: 'title'),
            body: any(named: 'body'),
            fireAt: any(named: 'fireAt'),
            payload: any(named: 'payload'),
            playSound: any(named: 'playSound'),
            presentInForeground: any(named: 'presentInForeground'),
          ),
        ).thenAnswer((_) async {});
        final adapter = LocalScheduledReminderNotifications(
          local,
          playSound: () => true,
        );
        final reminder = planScheduledTaskReminders([
          _task('a', runs: [runAt]),
        ], now: _now).single;

        await adapter.schedule(reminder, title: 'Daily summary');

        verify(
          () => local.scheduleAt(
            id: reminder.id,
            title: 'Daily summary',
            body: 'Your scheduled task ran. Tap to see the reply.',
            fireAt: reminder.fireAt,
            payload: reminder.payload,
            playSound: true,
            presentInForeground: false,
          ),
        ).called(1);
      });
    });
  });

  group('controller', () {
    late _FakeNotifications notifications;
    late ScheduledTaskReminderSync sync;

    setUp(() {
      notifications = _FakeNotifications();
      sync = ScheduledTaskReminderSync(
        notifications: notifications,
        clock: () => _now,
      );
    });

    final task = _task('a', runs: [_now.add(const Duration(hours: 1))]);

    test('enabled schedules the account\'s tasks', () async {
      final controller = ScheduledTaskReminders(
        sync: sync,
        enabled: true,
        loadTasks: () async => [task],
      );
      await controller.syncNow();
      check(notifications.held).length.equals(1);
      controller.dispose();
    });

    test('turning reminders off cancels them all', () async {
      await sync.apply([task]);
      final controller = ScheduledTaskReminders(
        sync: sync,
        enabled: false,
        loadTasks: () async => fail('nothing is loaded while off'),
      );
      await controller.syncNow();
      check(notifications.held).isEmpty();
      controller.dispose();
    });

    test('signed out, or tasks unavailable, cancels them all', () async {
      await sync.apply([task]);
      final controller = ScheduledTaskReminders(
        sync: sync,
        enabled: true,
        loadTasks: () async => null,
      );
      await controller.syncNow();
      check(notifications.held).isEmpty();
      controller.dispose();
    });

    test('a failed load keeps what is scheduled', () async {
      await sync.apply([task]);
      final controller = ScheduledTaskReminders(
        sync: sync,
        enabled: true,
        loadTasks: () async => throw StateError('offline'),
      );
      await controller.syncNow();
      check(notifications.held).length.equals(1);
      controller.dispose();
    });

    test('a load that finishes after a newer build took over schedules '
        'nothing', () async {
      final controller = ScheduledTaskReminders(
        sync: sync,
        enabled: true,
        loadTasks: () async {
          await Future<void>.delayed(Duration.zero);
          return [task];
        },
      );
      final running = controller.syncNow();
      controller.dispose();
      await running;
      check(notifications.held).isEmpty();
    });

    test('a socket alert is ignored while reminders are off', () async {
      final controller = ScheduledTaskReminders(
        sync: sync,
        enabled: false,
        loadTasks: () async => const [],
      );
      var reads = 0;
      await controller.onSocketAlert(
        const AppNotification(
          kind: NotificationKind.chatCompletion,
          title: 't',
          body: 'b',
          sourceId: 'chat-1',
          dedupKey: 'k',
        ),
        fetchTask: (_) async {
          reads++;
          return null;
        },
      );
      check(reads).equals(0);
      controller.dispose();
    });
  });

  group('tap routing', () {
    final runAt = _now;
    final tap = ScheduledTaskReminderTap(
      automationId: 'a',
      runAtNs: _ns(runAt),
    );

    Future<List<String>> route(
      Future<Automation?> Function(String id) fetchTask,
    ) async {
      final opened = <String>[];
      await routeScheduledTaskReminderTap(
        tap,
        fetchTask: fetchTask,
        openChat: (id) async => opened.add('chat:$id'),
        openChannel: (id) => opened.add('channel:$id'),
        openTask: (id) => opened.add('task:$id'),
      );
      return opened;
    }

    test('opens the chat of the run the reminder was for', () async {
      final opened = await route(
        (_) async => _task(
          'a',
          lastRun: _run(
            'a',
            runAt.add(const Duration(seconds: 40)),
            chatId: 'chat-9',
          ),
        ),
      );
      check(opened).deepEquals(['chat:chat-9']);
    });

    test('opens the channel for a channel result', () async {
      final opened = await route(
        (_) async =>
            _task('a', lastRun: _run('a', runAt, chatId: 'channel:ch-1')),
      );
      check(opened).deepEquals(['channel:ch-1']);
    });

    test(
      'opens the task when its latest run is older than the reminder',
      () async {
        final opened = await route(
          (_) async => _task(
            'a',
            lastRun: _run(
              'a',
              runAt.subtract(const Duration(days: 1)),
              chatId: 'yesterday',
            ),
          ),
        );
        check(opened).deepEquals(['task:a']);
      },
    );

    test('opens the task when it has never recorded a run', () async {
      final opened = await route((_) async => _task('a'));
      check(opened).deepEquals(['task:a']);
    });

    test('opens the task when it cannot be read', () async {
      final opened = await route((_) async => throw StateError('offline'));
      check(opened).deepEquals(['task:a']);
    });

    test('opens the task when no account is signed in', () async {
      final opened = await route((_) async => null);
      check(opened).deepEquals(['task:a']);
    });
  });
}
