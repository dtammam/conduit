import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit/features/chat/avatar/assistant_activity.dart';
import 'package:conduit/features/chat/avatar/assistant_avatar_accent.dart';
import 'package:conduit/features/chat/avatar/assistant_avatar_media.dart';
import 'package:conduit/features/chat/avatar/persona_appearance_service.dart';
import 'package:conduit/features/chat/widgets/message_bubble_colors.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/ports/secure_key_value_store.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/secure_credential_storage.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const _token = 'secret-token-value';
const _base = 'http://switchboard.test:1243';

typedef _Handler = FutureOr<ResponseBody> Function(RequestOptions options);

/// A Dio adapter that answers from a function and records every request.
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

  int clipRequests() =>
      requests.where((r) => r.path.contains('/clips/')).length;
}

ResponseBody _json(Object body, {int status = 200}) => ResponseBody.fromString(
  jsonEncode(body),
  status,
  headers: {
    Headers.contentTypeHeader: ['application/json'],
  },
);

ResponseBody _bytes(String content, {String type = 'video/mp4'}) =>
    ResponseBody.fromBytes(
      utf8.encode(content),
      200,
      headers: {
        Headers.contentTypeHeader: [type],
        'etag': ['"x"'],
      },
    );

Map<String, Object?> _persona(
  String id, {
  String? bubble,
  Map<String, (String etag, String type)> clips = const {},
}) => {
  'id': id,
  'name': 'Persona $id',
  'appearance': {
    'bubble_color': bubble,
    'clips': {
      for (final entry in clips.entries)
        entry.key: {
          'etag': entry.value.$1,
          'content_type': entry.value.$2,
          'url': '/api/personas/$id/clips/${entry.key}',
        },
    },
  },
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory documents;
  late _FakeAdapter adapter;
  late String? cache;
  late PersonaAppearanceService service;
  late Map<String, Object?> active;
  late Map<String, String> clipBodies;

  setUp(() async {
    documents = await Directory.systemTemp.createTemp('persona_test');
    cache = null;
    active = _persona('ada');
    clipBodies = {};
    adapter = _FakeAdapter((options) {
      if (options.path.endsWith('/api/personas/active')) {
        return _json(active);
      }
      final match = RegExp(r'/api/personas/(.+)/clips/(.+)$')
          .firstMatch(options.path);
      if (match != null) {
        final body = clipBodies['${match.group(1)}/${match.group(2)}'];
        if (body != null) return _bytes(body);
      }
      return ResponseBody.fromString('missing', 404);
    });
    service = PersonaAppearanceService(
      dio: Dio()..httpClientAdapter = adapter,
      documentsDirectory: () async => documents,
      readCache: () => cache,
      writeCache: (value) async => cache = value,
      requestTimeout: const Duration(milliseconds: 200),
      clipTimeout: const Duration(milliseconds: 500),
    );
  });

  tearDown(() => documents.delete(recursive: true));

  File clip(String persona, String name) => File(
    p.join(documents.path, 'assistant_avatar', 'personas', persona, name),
  );

  Future<PersonaSyncOutcome> sync() =>
      service.sync(baseUrl: _base, token: _token);

  group('PersonaAppearanceService', () {
    test('first sync downloads the clips and caches the answer', () async {
      active = _persona(
        'ada',
        bubble: '#E0B030',
        clips: {'idle': ('e1', 'video/mp4'), 'done': ('e2', 'image/png')},
      );
      clipBodies = {'ada/idle': 'IDLE-1', 'ada/done': 'DONE-1'};

      final outcome = await sync();

      check(outcome.status).equals(PersonaSyncStatus.updated);
      check(outcome.appearance!.id).equals('ada');
      check(outcome.appearance!.bubbleColor).equals('#E0B030');
      check(await clip('ada', 'idle.mp4').readAsString()).equals('IDLE-1');
      check(await clip('ada', 'done.png').readAsString()).equals('DONE-1');
      final cached = service.loadCached()!;
      check(cached.id).equals('ada');
      check(cached.clips[AssistantActivity.idle]!.etag).equals('e1');
      check(cached.clips.containsKey(AssistantActivity.working)).isFalse();
    });

    test(
      'every request carries the bearer and the cache never holds it',
      () async {
        active = _persona('ada', clips: {'idle': ('e1', 'video/mp4')});
        clipBodies = {'ada/idle': 'IDLE'};
        await sync();
        check(adapter.requests).isNotEmpty();
        for (final request in adapter.requests) {
          check(request.headers['Authorization']).equals('Bearer $_token');
        }
        check(cache!).not((it) => it.contains(_token));
      },
    );

    test(
      'an unchanged answer downloads nothing and reports unchanged',
      () async {
        active = _persona('ada', clips: {'idle': ('e1', 'video/mp4')});
        clipBodies = {'ada/idle': 'IDLE'};
        await sync();
        final before = adapter.clipRequests();

        final outcome = await sync();

        check(outcome.status).equals(PersonaSyncStatus.unchanged);
        check(adapter.clipRequests()).equals(before);
      },
    );

    test('a changed etag downloads only that clip', () async {
      active = _persona(
        'ada',
        clips: {'idle': ('e1', 'video/mp4'), 'done': ('d1', 'video/mp4')},
      );
      clipBodies = {'ada/idle': 'IDLE-1', 'ada/done': 'DONE-1'};
      await sync();
      adapter.requests.clear();

      active = _persona(
        'ada',
        clips: {'idle': ('e2', 'image/png'), 'done': ('d1', 'video/mp4')},
      );
      clipBodies['ada/idle'] = 'IDLE-2';
      final outcome = await sync();

      check(outcome.status).equals(PersonaSyncStatus.updated);
      check(adapter.clipRequests()).equals(1);
      check(await clip('ada', 'idle.png').readAsString()).equals('IDLE-2');
      // The old extension is gone, so the folder holds one idle file.
      check(clip('ada', 'idle.mp4').existsSync()).isFalse();
      check(await clip('ada', 'done.mp4').readAsString()).equals('DONE-1');
    });

    test('only a bubble color change updates without downloads', () async {
      active = _persona('ada', bubble: 'gray');
      await sync();
      active = _persona('ada', bubble: '#112233');

      final outcome = await sync();

      check(outcome.status).equals(PersonaSyncStatus.updated);
      check(service.loadCached()!.bubbleColor).equals('#112233');
      check(adapter.clipRequests()).equals(0);
    });

    test(
      'a different persona gets its own folder and the old one goes',
      () async {
        active = _persona('ada', clips: {'idle': ('e1', 'video/mp4')});
        clipBodies = {'ada/idle': 'ADA', 'bo/idle': 'BO'};
        await sync();

        active = _persona('bo', clips: {'idle': ('b1', 'video/mp4')});
        final outcome = await sync();

        check(outcome.appearance!.id).equals('bo');
        check(await clip('bo', 'idle.mp4').readAsString()).equals('BO');
        check(clip('ada', 'idle.mp4').existsSync()).isFalse();
      },
    );

    test('a clip the persona no longer sets is removed', () async {
      active = _persona(
        'ada',
        clips: {'idle': ('e1', 'video/mp4'), 'done': ('d1', 'video/mp4')},
      );
      clipBodies = {'ada/idle': 'I', 'ada/done': 'D'};
      await sync();

      active = _persona('ada', clips: {'idle': ('e1', 'video/mp4')});
      await sync();

      check(clip('ada', 'done.mp4').existsSync()).isFalse();
      check(clip('ada', 'idle.mp4').existsSync()).isTrue();
      check(service.loadCached()!.clips.containsKey(AssistantActivity.done))
          .isFalse();
    });

    test(
      'a failed download keeps the older clip of the same persona',
      () async {
        active = _persona('ada', clips: {'idle': ('e1', 'video/mp4')});
        clipBodies = {'ada/idle': 'OLD'};
        await sync();

        active = _persona('ada', clips: {'idle': ('e2', 'video/mp4')});
        clipBodies.remove('ada/idle');
        final outcome = await sync();

        check(await clip('ada', 'idle.mp4').readAsString()).equals('OLD');
        check(outcome.appearance!.clips[AssistantActivity.idle]!.etag)
            .equals('e1');
        // The next sync tries again and succeeds.
        clipBodies['ada/idle'] = 'NEW';
        await sync();
        check(await clip('ada', 'idle.mp4').readAsString()).equals('NEW');
      },
    );

    test('offline keeps the cached persona and its files', () async {
      active = _persona(
        'ada',
        bubble: '#E0B030',
        clips: {'idle': ('e1', 'video/mp4')},
      );
      clipBodies = {'ada/idle': 'IDLE'};
      await sync();
      final cachedBefore = cache;
      adapter.handler = (options) => throw DioException.connectionError(
        requestOptions: options,
        reason: 'offline',
      );

      final outcome = await sync();

      check(outcome.status).equals(PersonaSyncStatus.kept);
      check(outcome.appearance!.id).equals('ada');
      check(cache).equals(cachedBefore);
      check(clip('ada', 'idle.mp4').existsSync()).isTrue();
    });

    test('a 401 keeps the cached persona', () async {
      active = _persona('ada', clips: {'idle': ('e1', 'video/mp4')});
      clipBodies = {'ada/idle': 'IDLE'};
      await sync();
      final cachedBefore = cache;
      adapter.handler = (options) => _json({'detail': 'no'}, status: 401);

      final outcome = await sync();

      check(outcome.status).equals(PersonaSyncStatus.kept);
      check(outcome.appearance!.id).equals('ada');
      check(cache).equals(cachedBefore);
      check(clip('ada', 'idle.mp4').existsSync()).isTrue();
    });

    test('a slow server times out and keeps the cache', () async {
      active = _persona('ada');
      await sync();
      final cachedBefore = cache;
      adapter.handler = (options) async {
        await Future<void>.delayed(const Duration(seconds: 2));
        return _json(_persona('bo'));
      };

      final stopwatch = Stopwatch()..start();
      final outcome = await sync();

      check(outcome.status).equals(PersonaSyncStatus.kept);
      check(stopwatch.elapsed).isLessThan(const Duration(seconds: 1));
      check(cache).equals(cachedBefore);
    });

    test('a nonsense body keeps the cache', () async {
      active = _persona('ada');
      await sync();
      final cachedBefore = cache;
      adapter.handler = (options) => _json({'unexpected': true});
      check((await sync()).status).equals(PersonaSyncStatus.kept);
      check(cache).equals(cachedBefore);
    });

    test('with no cache and no server there is nothing to show', () async {
      adapter.handler = (options) => throw DioException.connectionError(
        requestOptions: options,
        reason: 'x',
      );
      final outcome = await sync();
      check(outcome.status).equals(PersonaSyncStatus.kept);
      check(outcome.appearance).isNull();
    });

    test('a blank address or token does not call the server', () async {
      check((await service.sync(baseUrl: '', token: _token)).status)
          .equals(PersonaSyncStatus.kept);
      check((await service.sync(baseUrl: _base, token: '  ')).status)
          .equals(PersonaSyncStatus.kept);
      check(adapter.requests).isEmpty();
    });

    test('a persona id that is not a safe folder name is refused', () async {
      active = _persona('../escape', clips: {'idle': ('e1', 'video/mp4')});
      clipBodies = {'../escape/idle': 'X'};
      final outcome = await sync();
      check(outcome.status).equals(PersonaSyncStatus.kept);
      check(cache).isNull();
    });

    test('an invalid bubble color from the server is ignored', () {
      final parsed = PersonaAppearance.fromServerJson(
        _persona('ada', bubble: 'chartreuse'),
      );
      check(parsed!.bubbleColor).isNull();
    });
  });

  group('token storage', () {
    test(
      'the token round-trips through secure storage and can be cleared',
      () async {
        final store = InMemorySecureKeyValueStore();
        final storage = SecureCredentialStorage(instance: store);
        check(await storage.readSwitchboardToken()).isNull();
        await storage.writeSwitchboardToken('  abc  ');
        check(await storage.readSwitchboardToken()).equals('abc');
        await storage.writeSwitchboardToken('');
        check(await storage.readSwitchboardToken()).isNull();
      },
    );
  });

  group('helpers', () {
    test('content types map to extensions', () {
      check(personaClipExtension('video/mp4')).equals('mp4');
      check(personaClipExtension('video/quicktime; codecs=x')).equals('mov');
      check(personaClipExtension('image/jpeg')).equals('jpg');
      check(personaClipExtension('image/png')).equals('png');
      check(personaClipExtension('video/odd')).equals('mp4');
      check(personaClipExtension('')).equals('jpg');
    });

    test('addresses are normalized', () {
      check(normalizeSwitchboardUrl(' 10.0.0.2:1243/ '))
          .equals('http://10.0.0.2:1243');
      check(normalizeSwitchboardUrl('https://sb.example/'))
          .equals('https://sb.example');
      check(normalizeSwitchboardUrl('')).isNull();
      check(normalizeSwitchboardUrl('ftp://host')).isNull();
    });
  });

  group('fallback chain', () {
    AssistantAvatarMedia file(String path) =>
        AssistantAvatarMedia.file(path, AssistantAvatarMediaKind.video);

    test('persona clip, then the user clip, then the bundled one', () {
      final set = AssistantAvatarMediaSet(
        personaFiles: {AssistantActivity.idle: file('/persona/idle.mp4')},
        userFiles: {
          AssistantActivity.idle: file('/user/idle.mp4'),
          AssistantActivity.working: file('/user/working.mp4'),
        },
        bundled: {
          AssistantActivity.idle,
          AssistantActivity.working,
          AssistantActivity.done,
        },
      );
      check(set.resolve(AssistantActivity.idle)!.path)
          .equals('/persona/idle.mp4');
      check(set.resolve(AssistantActivity.working)!.path)
          .equals('/user/working.mp4');
      check(set.resolve(AssistantActivity.done)!.isBundled).isTrue();
      // No clip of its own: making borrows the working clip.
      check(set.resolve(AssistantActivity.making)!.path)
          .equals('/user/working.mp4');
    });

    test('without persona files nothing changes', () {
      final set = AssistantAvatarMediaSet(
        userFiles: {AssistantActivity.idle: file('/user/idle.mp4')},
      );
      check(set.resolve(AssistantActivity.idle)!.path).equals('/user/idle.mp4');
      check(set.resolve(AssistantActivity.done)!.path).equals('/user/idle.mp4');
    });

    test('the store reads persona files only when asked', () async {
      final root = Directory(p.join(documents.path, 'assistant_avatar'));
      await Directory(p.join(root.path, 'personas', 'ada'))
          .create(recursive: true);
      await File(p.join(root.path, 'personas', 'ada', 'idle.mp4'))
          .writeAsString('P');
      await File(p.join(root.path, 'idle.png')).writeAsString('U');
      final store = AssistantAvatarMediaStore(
        documentsDirectory: () async => documents,
      );

      final plain = await store.load();
      check(plain.personaFiles).isEmpty();
      check(plain.userFiles.keys).deepEquals([AssistantActivity.idle]);

      final withPersona = await store.load(personaId: 'ada');
      check(withPersona.personaFiles[AssistantActivity.idle]!.path)
          .endsWith(p.join('personas', 'ada', 'idle.mp4'));
      check(withPersona.resolve(AssistantActivity.idle)!.path)
          .endsWith(p.join('personas', 'ada', 'idle.mp4'));

      final unknown = await store.load(personaId: 'nobody');
      check(unknown.resolve(AssistantActivity.idle)!.path).endsWith('idle.png');
    });
  });

  group('model list refresh', () {
    late _CountingModels models;

    Future<ProviderContainer> start() async {
      final store = InMemorySecureKeyValueStore();
      await SecureCredentialStorage(instance: store)
          .writeSwitchboardToken(_token);
      models = _CountingModels();
      final container = ProviderContainer(
        overrides: [
          appSettingsProvider.overrideWithValue(
            const AppSettings(
              personaAppearanceEnabled: true,
              personaAppearanceUrl: _base,
            ),
          ),
          secureStorageProvider.overrideWithValue(store),
          personaAppearanceServiceProvider.overrideWithValue(service),
          modelsProvider.overrideWith(() => models),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('a changed persona refreshes the model list once', () async {
      final container = await start();
      final controller = container.read(personaAppearanceProvider.notifier);
      await controller.refresh();
      check(models.refreshes).equals(1);
      check(container.read(personaAppearanceProvider)!.name)
          .equals('Persona ada');

      active = _persona('bea');
      await controller.refresh();
      check(models.refreshes).equals(2);
    });

    test('an unchanged poll does not refresh it', () async {
      final container = await start();
      final controller = container.read(personaAppearanceProvider.notifier);
      await controller.refresh();
      await controller.refresh();
      await controller.refresh();
      check(models.refreshes).equals(1);
    });

    test('a rename of the same persona refreshes it', () async {
      final container = await start();
      final controller = container.read(personaAppearanceProvider.notifier);
      await controller.refresh();
      active = {..._persona('ada'), 'name': 'Ada Renamed'};
      await controller.refresh();
      check(models.refreshes).equals(2);
    });

    test('a failed poll does not refresh it', () async {
      final container = await start();
      final controller = container.read(personaAppearanceProvider.notifier);
      await controller.refresh();
      adapter.handler = (_) => ResponseBody.fromString('no', 401);
      await controller.refresh();
      check(models.refreshes).equals(1);
    });
  });

  group('bubble color', () {
    const userBlue = '#3E7BD8';
    const persona = PersonaAppearance(id: 'ada', bubbleColor: '#E0B030');
    const autoAccent = Color(0xFF123456);

    Color? accent(AppSettings settings, PersonaAppearance? current) {
      final container = ProviderContainer(
        overrides: [
          appSettingsProvider.overrideWithValue(settings),
          personaAppearanceProvider.overrideWith(() => _FixedPersona(current)),
        ],
      );
      addTearDown(container.dispose);
      return container.read(messageBubbleAccentProvider);
    }

    AppSettings settings({required bool match, String choice = userBlue}) =>
        AppSettings(
          assistantAvatarEnabled: true,
          assistantAvatarBubbleColor: choice,
          personaAppearanceEnabled: match,
        );

    test('the persona color beats the user choice while matching', () {
      check(accent(settings(match: true), persona)!.toARGB32())
          .equals(0xFFE0B030);
    });

    test('turning matching off restores the user choice at once', () {
      check(accent(settings(match: false), persona)!.toARGB32())
          .equals(0xFF3E7BD8);
    });

    test('a persona without a color leaves the user choice alone', () {
      check(
        accent(
          settings(match: true),
          const PersonaAppearance(id: 'ada'),
        )!.toARGB32(),
      ).equals(0xFF3E7BD8);
      check(accent(settings(match: true), null)!.toARGB32()).equals(0xFF3E7BD8);
    });

    test('gray from the persona means the neutral bubbles', () {
      check(
        accent(
          settings(match: true),
          const PersonaAppearance(id: 'ada', bubbleColor: 'gray'),
        ),
      ).isNull();
    });

    test('auto from the persona follows the avatar-derived color', () {
      final container = ProviderContainer(
        overrides: [
          appSettingsProvider.overrideWithValue(
            settings(match: true, choice: assistantAvatarBubbleColorGray),
          ),
          personaAppearanceProvider.overrideWith(
            () => _FixedPersona(
              const PersonaAppearance(id: 'ada', bubbleColor: 'auto'),
            ),
          ),
          assistantAvatarAutoAccentProvider.overrideWith(
            () => _FixedAccent(autoAccent),
          ),
        ],
      );
      addTearDown(container.dispose);
      check(container.read(messageBubbleAccentProvider)).equals(autoAccent);
    });

    test('the stored user choice is never rewritten by the persona', () {
      final container = ProviderContainer(
        overrides: [
          appSettingsProvider.overrideWithValue(settings(match: true)),
          personaAppearanceProvider.overrideWith(() => _FixedPersona(persona)),
        ],
      );
      addTearDown(container.dispose);
      container.read(messageBubbleAccentProvider);
      check(container.read(appSettingsProvider).assistantAvatarBubbleColor)
          .equals(userBlue);
    });

    test('no avatar means no accent, persona or not', () {
      check(accent(const AppSettings(personaAppearanceEnabled: true), persona))
          .isNull();
    });
  });
}

class _FixedPersona extends PersonaAppearanceController {
  _FixedPersona(this.fixed);

  final PersonaAppearance? fixed;

  @override
  PersonaAppearance? build() => fixed;
}

class _FixedAccent extends AssistantAvatarAutoAccent {
  _FixedAccent(this.fixed);

  final Color? fixed;

  @override
  Color? build() => fixed;
}

class _CountingModels extends Models {
  int refreshes = 0;

  @override
  Future<List<Model>> build() async => const [];

  @override
  Future<void> refresh() async {
    refreshes++;
  }
}
