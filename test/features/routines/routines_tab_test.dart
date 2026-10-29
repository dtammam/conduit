import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit/features/routines/push_registration.dart';
import 'package:conduit/features/routines/routines_providers.dart';
import 'package:conduit/features/routines/routines_service.dart';
import 'package:conduit/features/routines/routines_tab.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit_core/features/automations/models/automation.dart';
import 'package:conduit_core/features/automations/providers/automation_providers.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _base = 'http://relay.test:1236';

class _Tasks extends Automations {
  _Tasks(this.items);

  final List<Automation> items;

  @override
  Future<AutomationsData> build() async =>
      AutomationsData(items: items, total: items.length, exhausted: true);

  @override
  AutomationsOwner? captureOwner() => null;
}

class _Settings extends AppSettingsNotifier {
  _Settings(this.initial);

  final AppSettings initial;

  @override
  AppSettings build() => initial;
}

class _Platform implements PushPlatform {
  _Platform(this.authorization);

  final String authorization;

  @override
  bool get supported => true;

  @override
  Future<Map<String, Object?>?> status() async => {
    'authorization': authorization,
    'registered': false,
    'env': 'sandbox',
  };

  @override
  Future<Map<String, Object?>?> requestAuthorization() => status();

  @override
  Future<Map<String, Object?>?> registerIfAuthorized() => status();

  @override
  Future<Map<String, Object?>?> registration() async => null;

  @override
  Future<bool> configureRelay({
    required String url,
    required String token,
  }) async => true;

  @override
  Future<void> unregister() async {}

  @override
  Future<List<Map<String, Object?>>> drainEvents() async => const [];

  @override
  set onEvent(void Function(Map<String, Object?> event)? handler) {}
}

class _Adapter implements HttpClientAdapter {
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      jsonEncode({'ok': true}),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Automation _task(
  String id,
  String name, {
  bool active = true,
  int? next,
  String prompt = '',
}) => Automation.fromJson({
  'id': id,
  'user_id': 'u',
  'name': name,
  'is_active': active,
  'next_run_at': next,
  'data': {'prompt': prompt, 'model_id': 'bobby', 'rrule': 'FREQ=DAILY'},
});

void main() {
  late _Adapter adapter;

  Future<void> mount(
    WidgetTester tester, {
    required List<Automation> tasks,
    Map<String, RoutineLast>? last = const {},
    bool serverSet = true,
    PushSettings? push = const PushSettings(
      quiet: true,
      quietStart: '22:00',
      quietEnd: '07:30',
    ),
    String authorization = 'authorized',
    bool pushEnabled = true,
  }) async {
    adapter = _Adapter();
    final overrides = <Override>[
      automationsProvider.overrideWith(() => _Tasks(tasks)),
      appSettingsProvider.overrideWith(
        () => _Settings(
          AppSettings(
            routinesServerUrl: serverSet ? _base : '',
            routinesPushEnabled: pushEnabled,
          ),
        ),
      ),
      routinesServerProvider.overrideWith(
        (ref) async => serverSet ? (base: _base, token: 't') : null,
      ),
      routinesLastProvider.overrideWith((ref) async => last),
      pushSettingsProvider.overrideWith(() => _PushSettings(push)),
      pushPlatformProvider.overrideWithValue(_Platform(authorization)),
      routinesServiceProvider.overrideWithValue(
        RoutinesService(dio: Dio()..httpClientAdapter = adapter),
      ),
    ];
    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides,
        child: MaterialApp(
          theme: AppTheme.light(TweakcnThemes.t3Chat),
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(body: RoutinesTab()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('lists every routine, paused ones too, soonest first', (
    tester,
  ) async {
    await mount(
      tester,
      tasks: [
        _task('p', 'Paused one', active: false),
        _task('b', 'Evening', next: 2000000000000000000),
        _task('a', 'Morning', next: 1900000000000000000),
      ],
    );

    final names = ['Morning', 'Evening', 'Paused one'];
    final tops = [
      for (final name in names) tester.getTopLeft(find.text(name)).dy,
    ];
    check(tops[0]).isLessThan(tops[1]);
    check(tops[1]).isLessThan(tops[2]);
    check(find.textContaining('Paused').evaluate()).isNotEmpty();
    check(find.byKey(const ValueKey('routine-switch-p')).evaluate()).length
        .equals(1);
  });

  testWidgets('shows the last reply, or Nothing new with its time', (
    tester,
  ) async {
    await mount(
      tester,
      tasks: [
        _task('a', 'Morning', prompt: '[check-in:morning]\nBrief me'),
        _task('b', 'Evening', prompt: '[check-in:evening quiet]\nWrap up'),
      ],
      last: {
        'morning': RoutineLast(
          at: DateTime(2026, 10, 28, 8),
          text: 'Rain at three.\nBring a coat.',
        ),
        'evening': RoutineLast(
          at: DateTime(2026, 10, 27, 20),
          text: 'Old',
          quietAt: DateTime(2026, 10, 28, 20),
        ),
      },
    );

    check(find.textContaining('Rain at three.').evaluate()).isNotEmpty();
    check(find.textContaining('Nothing new').evaluate()).isNotEmpty();
    check(find.text('Old').evaluate()).isEmpty();
  });

  testWidgets('with the server away the list stays and says so', (
    tester,
  ) async {
    await mount(
      tester,
      tasks: [_task('a', 'Morning', prompt: '[check-in:morning]\nx')],
      last: null,
      push: null,
    );

    check(find.text('Morning').evaluate()).length.equals(1);
    check(find.byKey(const ValueKey('routines-last-unavailable')).evaluate())
        .length
        .equals(1);
    check(find.byKey(const ValueKey('routines-quiet-unavailable')).evaluate())
        .length
        .equals(1);
  });

  testWidgets('quiet hours show the server settings', (tester) async {
    await mount(tester, tasks: const []);

    check(find.byKey(const ValueKey('routines-quiet-switch')).evaluate()).length
        .equals(1);
    check(find.text('10:00 PM').evaluate()).isNotEmpty();
    check(find.text('7:30 AM').evaluate()).isNotEmpty();
  });

  testWidgets(
    'without a routines server the server parts say how to set it up',
    (tester) async {
      await mount(tester, tasks: const [], serverSet: false, last: null);

      check(find.byKey(const ValueKey('routines-quiet-unset')).evaluate())
          .length
          .equals(1);
      check(find.byKey(const ValueKey('routines-push-unset')).evaluate()).length
          .equals(1);
    },
  );

  testWidgets('notifications: status and a test push', (tester) async {
    await mount(tester, tasks: const []);

    check(find.byKey(const ValueKey('routines-push-permission')).evaluate())
        .length
        .equals(1);
    check(find.text('Notifications are allowed').evaluate()).length.equals(1);
    await tester.tap(find.byKey(const ValueKey('routines-push-test')));
    await tester.pumpAndSettle();

    final request = adapter.requests.single;
    check(request.uri.toString()).equals('$_base/push/test');
    final body = jsonDecode(request.data as String) as Map<String, dynamic>;
    check(body['title']).equals('Test');
  });

  testWidgets('notifications off: offers to turn them on, no test button', (
    tester,
  ) async {
    await mount(
      tester,
      tasks: const [],
      authorization: 'notDetermined',
      pushEnabled: false,
    );

    check(find.byKey(const ValueKey('routines-push-turn-on')).evaluate()).length
        .equals(1);
    check(find.byKey(const ValueKey('routines-push-test')).evaluate())
        .isEmpty();
  });
}

class _PushSettings extends PushSettingsController {
  _PushSettings(this.value);

  final PushSettings? value;

  @override
  Future<PushSettings?> build() async => value;
}
