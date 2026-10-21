import 'package:conduit/features/notifications/providers/scheduled_task_reminders_provider.dart';
import 'package:conduit/features/notifications/services/local_notification_service.dart';
import 'package:conduit/features/notifications/views/notification_settings_page.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart'
    show AdaptiveSwitch;
import 'package:conduit/shared/widgets/utility_components.dart';
import 'package:conduit_core/features/automations/models/automation.dart';
import 'package:conduit_core/features/automations/providers/automation_providers.dart';
import 'package:conduit_core/features/notifications/models/app_notification.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';

const _title = 'Scheduled task reminders';

class _MockLocal extends Mock implements LocalNotificationService {}

final class _Settings extends AppSettingsNotifier {
  _Settings(this._initial);

  final AppSettings _initial;
  final saved = <bool>[];

  @override
  AppSettings build() => _initial;

  @override
  Future<void> setNotificationScheduledTaskReminders(bool value) async {
    saved.add(value);
    state = state.copyWith(notificationScheduledTaskReminders: value);
  }
}

final class _FakeReminders implements ScheduledTaskReminders {
  int syncs = 0;

  @override
  bool get enabled => true;

  @override
  Future<void> syncNow() async => syncs++;

  @override
  void request() {}

  @override
  Future<void> onSocketAlert(
    AppNotification notification, {
    required Future<Automation?> Function(String automationId) fetchTask,
  }) async {}

  @override
  void dispose() {}
}

class _Harness {
  _Harness(this.settings, this.local, this.reminders);

  final _Settings settings;
  final _MockLocal local;
  final _FakeReminders reminders;
}

Future<_Harness> _pump(
  WidgetTester tester, {
  AppSettings settings = const AppSettings(notificationsEnabled: true),
  bool supported = true,
  bool granted = true,
}) async {
  tester.view
    ..physicalSize = const Size(800, 2600)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final local = _MockLocal();
  when(() => local.requestPermissions()).thenAnswer((_) async => granted);
  final notifier = _Settings(settings);
  final reminders = _FakeReminders();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appSettingsProvider.overrideWith(() => notifier),
        localNotificationServiceProvider.overrideWithValue(local),
        scheduledTaskRemindersSupportedProvider.overrideWithValue(supported),
        automationsAvailableProvider.overrideWithValue(true),
        scheduledTaskRemindersProvider.overrideWithValue(reminders),
      ],
      child: const MaterialApp(
        localizationsDelegates: conduitLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: NotificationSettingsPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _Harness(notifier, local, reminders);
}

AdaptiveSwitch _switch(WidgetTester tester) => tester.widget<AdaptiveSwitch>(
  find.descendant(
    of: find.ancestor(of: find.text(_title), matching: find.byType(UtilityRow)),
    matching: find.byType(AdaptiveSwitch),
  ),
);

void main() {
  testWidgets('is not offered where reminders cannot be scheduled', (
    tester,
  ) async {
    await _pump(tester, supported: false);
    expect(find.text(_title), findsNothing);
  });

  testWidgets('is off by default', (tester) async {
    await _pump(tester);
    expect(find.text(_title), findsOneWidget);
    expect(_switch(tester).value, isFalse);
  });

  testWidgets('turning it on asks for permission, then schedules', (
    tester,
  ) async {
    final harness = await _pump(tester);

    await tester.tap(find.text(_title));
    await tester.pumpAndSettle();

    expect(harness.settings.saved, [true]);
    verify(() => harness.local.requestPermissions()).called(1);
    expect(harness.reminders.syncs, 1);
    expect(_switch(tester).value, isTrue);
  });

  testWidgets('a refused permission schedules nothing and says so', (
    tester,
  ) async {
    final harness = await _pump(tester, granted: false);

    await tester.tap(find.text(_title));
    await tester.pumpAndSettle();

    expect(harness.reminders.syncs, 0);
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    expect(find.text(l10n.notificationsPermissionDenied), findsOneWidget);
  });

  testWidgets('turning it off cancels without asking for permission', (
    tester,
  ) async {
    final harness = await _pump(
      tester,
      settings: const AppSettings(
        notificationsEnabled: true,
        notificationScheduledTaskReminders: true,
      ),
    );

    await tester.tap(find.text(_title));
    await tester.pumpAndSettle();

    expect(harness.settings.saved, [false]);
    verifyNever(() => harness.local.requestPermissions());
    expect(harness.reminders.syncs, 1);
  });

  testWidgets('follows the master toggle like the other rows', (tester) async {
    await _pump(tester, settings: const AppSettings());
    expect(_switch(tester).onChanged, isNull);
  });
}
