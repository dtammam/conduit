import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit/features/routines/push_registration.dart';
import 'package:conduit/features/routines/routines_providers.dart';
import 'package:conduit/features/routines/routines_service.dart';
import 'package:conduit/features/routines/routines_tab.dart';
import 'package:conduit_core/features/automations/models/automation.dart';
import 'package:conduit_core/ports/secure_key_value_store.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/secure_credential_storage.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _token = 'secret-token-value';
const _base = 'http://relay.test:1236';

typedef _Handler = FutureOr<ResponseBody> Function(RequestOptions options);

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.handler);

  _Handler handler;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(Object body, {int status = 200}) => ResponseBody.fromString(
  jsonEncode(body),
  status,
  headers: {
    Headers.contentTypeHeader: ['application/json'],
  },
);

class _FakePush implements PushPlatform {
  _FakePush();
  String authorization = 'notDetermined';
  String? deviceToken;
  final List<String> calls = [];
  void Function(Map<String, Object?> event)? _handler;
  List<Map<String, Object?>> queued = [];
  ({String url, String token})? relay;

  @override
  bool get supported => true;

  @override
  Future<Map<String, Object?>?> status() async => {
    'authorization': authorization,
    'registered': deviceToken != null,
    'env': 'sandbox',
  };

  @override
  Future<Map<String, Object?>?> requestAuthorization() async {
    calls.add('requestAuthorization');
    authorization = 'authorized';
    deviceToken = 'ab12';
    return status();
  }

  @override
  Future<Map<String, Object?>?> registerIfAuthorized() async {
    calls.add('registerIfAuthorized');
    return status();
  }

  @override
  Future<Map<String, Object?>?> registration() async => {
    'env': 'sandbox',
    'bundle': 'am.tamm.conduit.debug',
    'name': 'Test phone',
    'token': ?deviceToken,
    'key': 'a2V5',
  };

  @override
  Future<bool> configureRelay({
    required String url,
    required String token,
  }) async {
    relay = (url: url, token: token);
    return true;
  }

  @override
  Future<void> unregister() async {
    calls.add('unregister');
    deviceToken = null;
  }

  @override
  Future<List<Map<String, Object?>>> drainEvents() async => queued;

  @override
  set onEvent(void Function(Map<String, Object?> event)? handler) =>
      _handler = handler;

  void emit(Map<String, Object?> event) => _handler?.call(event);
}

Automation _task(
  String id, {
  String name = 'Task',
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
  group('routine prompts', () {
    test('the marker line gives the slug and is stripped', () {
      const prompt = '[check-in:morning-brief quiet keep=3]\nGood morning.';
      check(routineSlugOf(prompt)).equals('morning-brief');
      check(stripRoutineMarker(prompt)).equals('Good morning.');
    });

    test('a prompt without a marker is not a routine', () {
      check(routineSlugOf('Remind me about the bins')).isNull();
      check(stripRoutineMarker('Remind me')).equals('Remind me');
    });

    test('the server address is normalised', () {
      check(normalizeRoutinesUrl(' host:1236/ ')).equals('http://host:1236');
      check(normalizeRoutinesUrl('https://a.test')).equals('https://a.test');
      check(normalizeRoutinesUrl('')).isNull();
      check(normalizeRoutinesUrl('ftp://a.test')).isNull();
    });
  });

  group('RoutinesService', () {
    late _FakeAdapter adapter;
    late RoutinesService service;

    setUp(() {
      adapter = _FakeAdapter((_) => _json({}));
      service = RoutinesService(dio: Dio()..httpClientAdapter = adapter);
    });

    test('last results parse by slug, with the quiet time', () async {
      adapter.handler = (_) => _json({
        'Morning': {
          'at': '2026-10-28T12:00:00Z',
          'text': 'Rain at 3',
          'quiet_at': null,
        },
        'evening': {'at': null, 'text': '', 'quiet_at': '2026-10-28T23:00:00Z'},
      });
      final last = await service.last(base: _base, token: _token);
      check(last).isNotNull();
      check(last!['morning']!.text).equals('Rain at 3');
      check(last['evening']!.quietAt).isNotNull();
      final request = adapter.requests.single;
      check(request.headers['Authorization']).equals('Bearer $_token');
      check(request.uri.toString()).equals('$_base/routines/last');
    });

    test('an unreachable or refusing server answers null', () async {
      adapter.handler = (_) => _json({'error': 'no'}, status: 401);
      check(await service.last(base: _base, token: _token)).isNull();
      check(await service.settings(base: _base, token: _token)).isNull();
      check(
        await service.sendTest(
          base: _base,
          token: _token,
          title: 't',
          body: 'b',
        ),
      ).isFalse();
    });

    test('settings change sends only the given fields', () async {
      adapter.handler = (_) => _json({
        'quiet': true,
        'quiet_start': '21:00',
        'quiet_end': '07:30',
        'quiet_now': false,
        'devices': 1,
        'held': 0,
      });
      final updated = await service.updateSettings(
        base: _base,
        token: _token,
        quietStart: '21:00',
      );
      check(updated!.quietStart).equals('21:00');
      final request = adapter.requests.single;
      check(request.method).equals('PUT');
      check(jsonDecode(request.data as String) as Map<String, dynamic>)
          .deepEquals({'quiet_start': '21:00'});
    });

    test('registering sends the body the server documents', () async {
      final ok = await service.registerDevice(
        base: _base,
        token: _token,
        deviceToken: 'ab12',
        key: 'a2V5',
        env: 'sandbox',
        bundle: 'am.tamm.conduit.debug',
        name: 'Test phone',
      );
      check(ok).isTrue();
      final request = adapter.requests.single;
      check(request.uri.path).equals('/push/devices');
      check(jsonDecode(request.data as String) as Map<String, dynamic>)
          .deepEquals({
            'token': 'ab12',
            'key': 'a2V5',
            'env': 'sandbox',
            'bundle': 'am.tamm.conduit.debug',
            'name': 'Test phone',
          });
    });
  });

  group('routines list', () {
    test('sorted by next run, paused after, by name', () {
      final sorted = sortRoutines([
        _task('p', name: 'b paused', active: false),
        _task('late', name: 'late', next: 200),
        _task('a', name: 'a paused', active: false),
        _task('soon', name: 'soon', next: 100),
      ]);
      check([for (final t in sorted) t.id])
          .deepEquals(['soon', 'late', 'a', 'p']);
    });

    test('the result line prefers the newer of reply and quiet run', () {
      final reply = DateTime(2026, 10, 28, 8);
      final quiet = DateTime(2026, 10, 28, 12);
      check(
        routineResultLine(RoutineLast(at: reply, text: 'Rain', quietAt: quiet)),
      ).isNotNull().has((r) => r.quietAt, 'quietAt').equals(quiet);
      check(
        routineResultLine(RoutineLast(at: quiet, text: 'Rain', quietAt: reply)),
      ).isNotNull().has((r) => r.text, 'text').equals('Rain');
      check(routineResultLine(const RoutineLast())).isNull();
      check(routineResultLine(null)).isNull();
    });
  });

  group('push registration', () {
    late _FakeAdapter adapter;
    late _FakePush push;
    late ProviderContainer container;

    Future<void> start({AppSettings? settings, bool withToken = true}) async {
      adapter = _FakeAdapter((_) => _json({}));
      push = _FakePush();
      final store = InMemorySecureKeyValueStore();
      if (withToken) {
        await SecureCredentialStorage(instance: store)
            .writeSwitchboardToken(_token);
      }
      container = ProviderContainer(
        overrides: [
          appSettingsProvider.overrideWith(
            () => _Settings(
              settings ?? const AppSettings(routinesServerUrl: _base),
            ),
          ),
          secureStorageProvider.overrideWithValue(store),
          pushPlatformProvider.overrideWithValue(push),
          routinesServiceProvider.overrideWithValue(
            RoutinesService(dio: Dio()..httpClientAdapter = adapter),
          ),
        ],
      );
      addTearDown(container.dispose);
    }

    test(
      'nothing is asked or registered before the person turns it on',
      () async {
        await start();
        await container.read(pushRegistrationProvider.notifier).start();
        check(push.calls).not((c) => c.contains('requestAuthorization'));
        check(adapter.requests).isEmpty();
      },
    );

    test('turning on asks, then registers with the stored token', () async {
      await start();
      final registration = container.read(pushRegistrationProvider.notifier);
      final ok = await registration.enable();
      check(ok).isTrue();
      check(container.read(appSettingsProvider).routinesPushEnabled).isTrue();
      check(container.read(pushRegistrationProvider).registered).isTrue();
      final request = adapter.requests.single;
      check(request.uri.toString()).equals('$_base/push/devices');
      check(request.headers['Authorization']).equals('Bearer $_token');
      final body = jsonDecode(request.data as String) as Map<String, dynamic>;
      check(body['token']).equals('ab12');
      check(body['env']).equals('sandbox');
      check(body['bundle']).equals('am.tamm.conduit.debug');
      check(push.relay).isNotNull().has((r) => r.url, 'url').equals(_base);
    });

    test('a refused permission registers nothing', () async {
      await start();
      push.authorization = 'denied';
      // The platform answers denied for the request as well.
      final denied = _DeniedPush();
      container.dispose();
      container = ProviderContainer(
        overrides: [
          appSettingsProvider.overrideWith(
            () => _Settings(const AppSettings(routinesServerUrl: _base)),
          ),
          pushPlatformProvider.overrideWithValue(denied),
        ],
      );
      addTearDown(container.dispose);
      final ok = await container
          .read(pushRegistrationProvider.notifier)
          .enable();
      check(ok).isFalse();
      check(container.read(appSettingsProvider).routinesPushEnabled).isFalse();
    });

    test('a new device token registers again', () async {
      await start(
        settings: const AppSettings(
          routinesServerUrl: _base,
          routinesPushEnabled: true,
        ),
      );
      push
        ..authorization = 'authorized'
        ..deviceToken = 'cd34';
      await container.read(pushRegistrationProvider.notifier).start();
      adapter.requests.clear();
      push.deviceToken = 'ef56';
      push.emit({'kind': 'token', 'token': 'ef56'});
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final body = jsonDecode(
        adapter.requests.single.data as String,
      ) as Map<String, dynamic>;
      check(body['token']).equals('ef56');
    });

    test('turning off tells the server to forget the phone', () async {
      await start(
        settings: const AppSettings(
          routinesServerUrl: _base,
          routinesPushEnabled: true,
        ),
      );
      push.deviceToken = 'ab12';
      await container.read(pushRegistrationProvider.notifier).disable();
      check(container.read(appSettingsProvider).routinesPushEnabled).isFalse();
      check(adapter.requests.single.uri.path).equals('/push/devices/remove');
      check(push.calls).contains('unregister');
    });

    test('a reply event waits for the chat page as a request', () async {
      await start();
      container
          .read(routineReplyProvider.notifier)
          .request(const RoutineReplyRequest(chatId: 'omni', text: 'Thanks'));
      check(container.read(routineReplyProvider)!.text).equals('Thanks');
      container.read(routineReplyProvider.notifier).clear();
      check(container.read(routineReplyProvider)).isNull();
    });
  });
}

class _DeniedPush extends _FakePush {
  @override
  Future<Map<String, Object?>?> requestAuthorization() async => {
    'authorization': 'denied',
    'registered': false,
    'env': 'sandbox',
  };
}

class _Settings extends AppSettingsNotifier {
  _Settings(this.initial);

  final AppSettings initial;

  @override
  AppSettings build() => initial;

  @override
  Future<void> setRoutinesPushEnabled(bool value) async =>
      state = state.copyWith(routinesPushEnabled: value);
}
