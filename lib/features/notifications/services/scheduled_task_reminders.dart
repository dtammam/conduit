import 'dart:async';
import 'dart:convert';

import 'package:conduit_core/features/automations/models/automation.dart';
import 'package:conduit_core/utils/debug_logger.dart';

/// Reminders for Open WebUI scheduled tasks, scheduled on this device ahead of
/// each task's known run times.
///
/// The server runs a task on its own schedule and the app only hears about
/// the reply over its socket, which iOS suspends in the background. A local
/// notification scheduled from the server's `next_runs` fires even when the
/// app is suspended or closed, with no push service involved. It is posted a
/// little after the run so the reply is likely written by then, and its text
/// cannot contain the reply: the reply does not exist when the notification
/// is scheduled.

/// How long after a run its reminder fires, so the reply is likely done.
const Duration scheduledTaskReminderDelay = Duration(minutes: 1);

/// Upcoming runs scheduled per task.
const int scheduledTaskRemindersPerTask = 3;

/// Reminders scheduled at once for this feature. iOS keeps at most 64 pending
/// local notifications per app and drops the rest, so this leaves room for
/// everything else the app schedules.
const int scheduledTaskRemindersMax = 40;

/// The block of notification ids this feature owns. Message notifications
/// count up from 1, so they stay far below it. Every id in the block belongs
/// to a reminder, which lets a resync cancel and replace only reminders.
const int scheduledTaskReminderIdBase = 0x40000000;
const int scheduledTaskReminderIdSpan = 1 << 24;

/// How much earlier than the run it is for a recorded run may be dated and
/// still count as that run.
const Duration scheduledTaskRunMatchTolerance = Duration(minutes: 1);

const String _payloadKind = 'scheduledTaskReminder';

bool isScheduledTaskReminderId(int id) =>
    id >= scheduledTaskReminderIdBase &&
    id < scheduledTaskReminderIdBase + scheduledTaskReminderIdSpan;

/// The id for one run of one task, the same on every resync so an unchanged
/// reminder is left as it is.
int scheduledTaskReminderId(String automationId, int runAtNs) {
  // FNV-1a, 32 bits, folded into the block.
  var hash = 0x811c9dc5;
  for (final unit in utf8.encode('$automationId|$runAtNs')) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return scheduledTaskReminderIdBase + (hash % scheduledTaskReminderIdSpan);
}

/// One reminder: a run of a task and when to tell the user about it.
class ScheduledTaskReminder {
  const ScheduledTaskReminder({
    required this.id,
    required this.automationId,
    required this.name,
    required this.runAtNs,
    required this.fireAt,
  });

  final int id;
  final String automationId;
  final String name;
  final int runAtNs;

  /// UTC.
  final DateTime fireAt;

  DateTime get runAt =>
      DateTime.fromMicrosecondsSinceEpoch(runAtNs ~/ 1000, isUtc: true);

  String get key => scheduledTaskReminderKey(automationId, runAtNs);

  String get payload => ScheduledTaskReminderTap(
    automationId: automationId,
    runAtNs: runAtNs,
  ).encode();

  @override
  String toString() => 'ScheduledTaskReminder($id, $automationId, $runAtNs)';
}

String scheduledTaskReminderKey(String automationId, int runAtNs) =>
    '$automationId|$runAtNs';

/// A tap on a reminder, decoded from its payload.
class ScheduledTaskReminderTap {
  const ScheduledTaskReminderTap({required this.automationId, this.runAtNs});

  final String automationId;

  /// The run the reminder was for, in epoch nanoseconds.
  final int? runAtNs;

  String encode() => jsonEncode({
    'kind': _payloadKind,
    'automationId': automationId,
    // A string: nanosecond epochs exceed what a JSON number keeps exactly in
    // some decoders.
    if (runAtNs != null) 'runAt': runAtNs.toString(),
  });

  static ScheduledTaskReminderTap? tryDecode(String? payload) {
    if (payload == null || payload.isEmpty) return null;
    try {
      final map = jsonDecode(payload);
      if (map is! Map || map['kind'] != _payloadKind) return null;
      final id = map['automationId'];
      if (id is! String || id.isEmpty) return null;
      return ScheduledTaskReminderTap(
        automationId: id,
        runAtNs: epochNanoseconds(map['runAt']),
      );
    } catch (_) {
      return null;
    }
  }
}

/// The reminders to hold for [tasks] at [now]: for each active task its next
/// [perTask] runs whose reminder is still ahead, then at most [max] of them,
/// soonest first. Runs in [skip] (keys from [scheduledTaskReminderKey]) are
/// left out.
List<ScheduledTaskReminder> planScheduledTaskReminders(
  Iterable<Automation> tasks, {
  required DateTime now,
  Set<String> skip = const <String>{},
  Duration delay = scheduledTaskReminderDelay,
  int perTask = scheduledTaskRemindersPerTask,
  int max = scheduledTaskRemindersMax,
}) {
  final candidates = <({Automation task, int runAtNs, DateTime fireAt})>[];
  final seenTasks = <String>{};
  for (final task in tasks) {
    if (!task.isActive || task.id.isEmpty || !seenTasks.add(task.id)) continue;
    final listed = task.nextRunsNs;
    final runs = <int>{
      if (listed != null && listed.isNotEmpty) ...listed else ?task.nextRunAtNs,
    }.toList()..sort();
    var taken = 0;
    for (final runAtNs in runs) {
      if (taken >= perTask) break;
      final fireAt = DateTime.fromMicrosecondsSinceEpoch(
        runAtNs ~/ 1000,
        isUtc: true,
      ).add(delay);
      if (!fireAt.isAfter(now)) continue;
      if (skip.contains(scheduledTaskReminderKey(task.id, runAtNs))) continue;
      candidates.add((task: task, runAtNs: runAtNs, fireAt: fireAt));
      taken++;
    }
  }
  candidates.sort((a, b) {
    final byTime = a.fireAt.compareTo(b.fireAt);
    if (byTime != 0) return byTime;
    return a.task.id.compareTo(b.task.id);
  });

  final used = <int>{};
  return [
    for (final candidate in candidates.take(max))
      ScheduledTaskReminder(
        id: _unusedId(
          scheduledTaskReminderId(candidate.task.id, candidate.runAtNs),
          used,
        ),
        automationId: candidate.task.id,
        name: candidate.task.name,
        runAtNs: candidate.runAtNs,
        fireAt: candidate.fireAt,
      ),
  ];
}

/// [id], or the next free id in the block when two runs hash alike.
int _unusedId(int id, Set<int> used) {
  var candidate = id;
  while (!used.add(candidate)) {
    candidate = candidate + 1;
    if (!isScheduledTaskReminderId(candidate)) {
      candidate = scheduledTaskReminderIdBase;
    }
  }
  return candidate;
}

/// Whether [run] is the run a reminder for [runAtNs] is about: a run recorded
/// at or after that time. With no time to compare, any recorded run counts.
bool scheduledTaskRunMatches(AutomationRun run, int? runAtNs) {
  if (runAtNs == null) return true;
  final at = run.createdAtNs;
  if (at == null) return false;
  return at >= runAtNs - scheduledTaskRunMatchTolerance.inMicroseconds * 1000;
}

/// A reminder the system holds and has not delivered.
typedef PendingScheduledReminder = ({int id, String? title, String? payload});

/// What the reminders need from the notification layer.
abstract interface class ScheduledReminderNotifications {
  bool get supported;

  Future<List<PendingScheduledReminder>> pending();

  Future<void> schedule(
    ScheduledTaskReminder reminder, {
    required String title,
  });

  Future<void> cancel(int id);
}

/// What a socket notification was about, for the double-alert check.
enum ScheduledTaskAlertSource { chat, channel }

/// Keeps the system's pending reminders equal to the plan for the account's
/// tasks. Only ids in the reminder block whose payload is a reminder are
/// ever cancelled, so message notifications, posted or pending, are never
/// touched. A reminder already delivered is not pending, so a resync leaves
/// it in Notification Center.
class ScheduledTaskReminderSync {
  ScheduledTaskReminderSync({
    required ScheduledReminderNotifications notifications,
    DateTime Function()? clock,
    String Function()? fallbackTitle,
    Duration alertMatchRetry = const Duration(seconds: 5),
    int alertMatchAttempts = 3,
  }) : _notifications = notifications,
       _clock = clock ?? DateTime.now,
       _fallbackTitle = fallbackTitle ?? (() => ''),
       _alertMatchRetry = alertMatchRetry,
       _alertMatchAttempts = alertMatchAttempts;

  final ScheduledReminderNotifications _notifications;
  final DateTime Function() _clock;
  final String Function() _fallbackTitle;
  final Duration _alertMatchRetry;
  final int _alertMatchAttempts;

  List<ScheduledTaskReminder> _scheduled = const [];

  /// Runs whose reply already alerted through the socket, so their reminder
  /// stays cancelled.
  final Set<String> _covered = <String>{};

  /// The reminders this sync last scheduled.
  List<ScheduledTaskReminder> get scheduled => _scheduled;

  /// Serializes changes, so a cancel that follows an apply in progress lands
  /// after it rather than under it.
  Future<void> _tail = Future<void>.value();

  Future<void> _serialized(Future<void> Function() change) {
    final next = _tail.then((_) => change());
    _tail = next.catchError((Object _) {});
    return next;
  }

  /// Schedules the reminders for [tasks] and cancels every other pending
  /// reminder: a paused or deleted task's included.
  Future<void> apply(Iterable<Automation> tasks) =>
      _serialized(() => _apply(tasks));

  Future<void> _apply(Iterable<Automation> tasks) async {
    if (!_notifications.supported) return;
    final plan = planScheduledTaskReminders(
      tasks,
      now: _clock().toUtc(),
      skip: _covered,
    );
    final pending = await _pendingReminders();
    final planned = {for (final reminder in plan) reminder.id: reminder};
    for (final entry in pending) {
      if (!planned.containsKey(entry.id)) {
        await _notifications.cancel(entry.id);
      }
    }
    final held = {for (final entry in pending) entry.id: entry};
    for (final reminder in plan) {
      final title = _title(reminder);
      final existing = held[reminder.id];
      // An identical pending reminder stays as it is.
      if (existing != null &&
          existing.payload == reminder.payload &&
          existing.title == title) {
        continue;
      }
      await _notifications.schedule(reminder, title: title);
    }
    _scheduled = List.unmodifiable(plan);
  }

  /// Cancels every pending reminder, for the toggle turned off, sign-out or
  /// an account or server change.
  Future<void> cancelAll() => _serialized(_cancelAll);

  Future<void> _cancelAll() async {
    _scheduled = const [];
    _covered.clear();
    if (!_notifications.supported) return;
    for (final entry in await _pendingReminders()) {
      await _notifications.cancel(entry.id);
    }
  }

  /// Called when a socket notification alerted the user about [sourceId]. If
  /// a task ran a moment ago and its reminder is still due, and the task's
  /// latest run is that chat or channel, the reminder is cancelled: the user
  /// was already told.
  ///
  /// The run is recorded when the server finishes it, which can land just
  /// after the reply's socket event, so the task is read again a few times
  /// while the reminder is still ahead.
  Future<void> onSocketAlert({
    required ScheduledTaskAlertSource source,
    required String sourceId,
    required Future<Automation?> Function(String automationId) fetchTask,
  }) async {
    if (!_notifications.supported || sourceId.isEmpty) return;
    for (var attempt = 0; attempt < _alertMatchAttempts; attempt++) {
      if (attempt > 0) await Future<void>.delayed(_alertMatchRetry);
      final now = _clock().toUtc();
      final due = [
        for (final reminder in _scheduled)
          if (!reminder.runAt.isAfter(now) && reminder.fireAt.isAfter(now))
            reminder,
      ];
      if (due.isEmpty) return;
      for (final reminder in due) {
        Automation? task;
        try {
          task = await fetchTask(reminder.automationId);
        } catch (error) {
          DebugLogger.warning(
            'reminder-alert-match-read-failed',
            scope: 'notifications/reminders',
            data: {'error': error.toString()},
          );
        }
        final run = task?.lastRun;
        if (run == null || !scheduledTaskRunMatches(run, reminder.runAtNs)) {
          continue;
        }
        final target = switch (source) {
          ScheduledTaskAlertSource.chat => run.resultChatId,
          ScheduledTaskAlertSource.channel => run.resultChannelId,
        };
        if (target != sourceId) continue;
        _covered.add(reminder.key);
        _scheduled = List.unmodifiable([
          for (final other in _scheduled)
            if (other.id != reminder.id) other,
        ]);
        await _notifications.cancel(reminder.id);
        return;
      }
    }
  }

  String _title(ScheduledTaskReminder reminder) =>
      reminder.name.trim().isNotEmpty ? reminder.name : _fallbackTitle();

  Future<List<PendingScheduledReminder>> _pendingReminders() async {
    final pending = await _notifications.pending();
    return [
      for (final entry in pending)
        if (isScheduledTaskReminderId(entry.id) &&
            ScheduledTaskReminderTap.tryDecode(entry.payload) != null)
          entry,
    ];
  }
}

/// Where a reminder tap leads.
sealed class ScheduledTaskReminderDestination {
  const ScheduledTaskReminderDestination();
}

final class ScheduledTaskReminderChat extends ScheduledTaskReminderDestination {
  const ScheduledTaskReminderChat(this.chatId);
  final String chatId;
}

final class ScheduledTaskReminderChannel
    extends ScheduledTaskReminderDestination {
  const ScheduledTaskReminderChannel(this.channelId);
  final String channelId;
}

/// The task itself, when its reply cannot be found: the task could not be
/// read, or its latest run is older than the reminder (still running, or the
/// run failed before it was recorded).
final class ScheduledTaskReminderTask extends ScheduledTaskReminderDestination {
  const ScheduledTaskReminderTask(this.automationId);
  final String automationId;
}

/// Where [tap] should open, given the task as the server holds it now.
ScheduledTaskReminderDestination resolveScheduledTaskReminderTap(
  ScheduledTaskReminderTap tap,
  Automation? task,
) {
  final run = task?.lastRun;
  if (run != null && scheduledTaskRunMatches(run, tap.runAtNs)) {
    final channel = run.resultChannelId;
    if (channel != null) return ScheduledTaskReminderChannel(channel);
    final chat = run.resultChatId;
    if (chat != null) return ScheduledTaskReminderChat(chat);
  }
  return ScheduledTaskReminderTask(tap.automationId);
}

/// Reads the task behind [tap] and opens what it leads to.
Future<void> routeScheduledTaskReminderTap(
  ScheduledTaskReminderTap tap, {
  required Future<Automation?> Function(String automationId) fetchTask,
  required Future<void> Function(String chatId) openChat,
  required void Function(String channelId) openChannel,
  required void Function(String automationId) openTask,
}) async {
  Automation? task;
  try {
    task = await fetchTask(tap.automationId);
  } catch (error) {
    DebugLogger.warning(
      'reminder-tap-read-failed',
      scope: 'notifications/reminders',
      data: {'error': error.toString()},
    );
  }
  switch (resolveScheduledTaskReminderTap(tap, task)) {
    case ScheduledTaskReminderChat(:final chatId):
      await openChat(chatId);
    case ScheduledTaskReminderChannel(:final channelId):
      openChannel(channelId);
    case ScheduledTaskReminderTask(:final automationId):
      openTask(automationId);
  }
}

/// Runs reminder syncs one at a time, a short while after the last request,
/// so a burst of triggers (start, list load, resume) costs one sync.
class ScheduledTaskReminderScheduler {
  ScheduledTaskReminderScheduler({
    required Future<void> Function() run,
    this.debounce = const Duration(milliseconds: 750),
  }) : _run = run;

  final Future<void> Function() _run;
  final Duration debounce;

  Timer? _timer;
  Future<void>? _running;
  bool _again = false;
  bool _disposed = false;

  void request() {
    if (_disposed) return;
    _timer?.cancel();
    _timer = Timer(debounce, _start);
  }

  /// Runs now, or once the sync in progress finishes. Completes when done.
  Future<void> runNow() {
    _timer?.cancel();
    return _start();
  }

  Future<void> _start() {
    if (_disposed) return Future<void>.value();
    final running = _running;
    if (running != null) {
      _again = true;
      return running;
    }
    return _running = _loop();
  }

  Future<void> _loop() async {
    try {
      do {
        _again = false;
        try {
          await _run();
        } catch (error, stackTrace) {
          DebugLogger.error(
            'reminder-sync-failed',
            scope: 'notifications/reminders',
            error: error,
            stackTrace: stackTrace,
          );
        }
      } while (_again && !_disposed);
    } finally {
      _running = null;
    }
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
  }
}
