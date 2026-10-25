import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/providers/storage_providers.dart';
import 'package:conduit_core/services/secure_credential_storage.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'assistant_activity.dart';
import 'assistant_avatar_media.dart' show isSafePersonaId;

const String _logScope = 'chat/persona';

final RegExp _validBubbleColor = RegExp(r'^(auto|gray|#[0-9A-Fa-f]{6})$');

/// How long the active-persona request may take before the cached persona
/// stays in force.
const Duration kPersonaRequestTimeout = Duration(seconds: 3);

/// How long one clip download may take.
const Duration kPersonaClipTimeout = Duration(seconds: 30);

/// How often a visible chat asks the server for the active persona.
const Duration kPersonaPollInterval = Duration(seconds: 60);

/// A clip a persona carries for one avatar state: the server's version tag
/// and media type. The bytes live on disk. [url] is the server path the
/// bytes come from; it is not cached and not part of equality.
class PersonaClip {
  const PersonaClip({
    required this.etag,
    required this.contentType,
    this.url = '',
  });

  final String etag;
  final String contentType;
  final String url;

  @override
  bool operator ==(Object other) =>
      other is PersonaClip &&
      other.etag == etag &&
      other.contentType == contentType;

  @override
  int get hashCode => Object.hash(etag, contentType);
}

/// The look of the persona that is active on the server: the clips it sets
/// (a state without an entry has none) and its bubble color (`auto`, `gray`,
/// `#RRGGBB`, or null for "no opinion").
class PersonaAppearance {
  const PersonaAppearance({
    required this.id,
    this.name = '',
    this.bubbleColor,
    this.clips = const {},
  });

  final String id;
  final String name;
  final String? bubbleColor;
  final Map<AssistantActivity, PersonaClip> clips;

  /// Reads the server's `/api/personas/active` answer. Null when it does not
  /// have the expected shape.
  static PersonaAppearance? fromServerJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    if (id is! String || !isSafePersonaId(id)) return null;
    final name = json['name'];
    final appearance = json['appearance'];
    String? bubbleColor;
    final clips = <AssistantActivity, PersonaClip>{};
    if (appearance is Map) {
      final color = appearance['bubble_color'];
      if (color is String && _validBubbleColor.hasMatch(color)) {
        bubbleColor = color;
      }
      final rawClips = appearance['clips'];
      if (rawClips is Map) {
        for (final state in AssistantActivity.values) {
          final raw = rawClips[state.name];
          if (raw is! Map) continue;
          final etag = raw['etag'];
          final type = raw['content_type'];
          final url = raw['url'];
          if (etag is! String || etag.isEmpty) continue;
          if (url is! String || url.isEmpty) continue;
          clips[state] = PersonaClip(
            etag: etag,
            contentType: type is String ? type : '',
            url: url,
          );
        }
      }
    }
    return PersonaAppearance(
      id: id,
      name: name is String ? name : '',
      bubbleColor: bubbleColor,
      clips: clips,
    );
  }

  /// The cached form, kept in preferences.
  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'bubble_color': bubbleColor,
    'clips': {
      for (final entry in clips.entries)
        entry.key.name: {
          'etag': entry.value.etag,
          'content_type': entry.value.contentType,
        },
    },
  };

  static PersonaAppearance? fromCacheJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    if (id is! String || !isSafePersonaId(id)) return null;
    final clips = <AssistantActivity, PersonaClip>{};
    final rawClips = json['clips'];
    if (rawClips is Map) {
      for (final state in AssistantActivity.values) {
        final raw = rawClips[state.name];
        if (raw is! Map) continue;
        final etag = raw['etag'];
        if (etag is! String) continue;
        final type = raw['content_type'];
        clips[state] = PersonaClip(
          etag: etag,
          contentType: type is String ? type : '',
        );
      }
    }
    final color = json['bubble_color'];
    final name = json['name'];
    return PersonaAppearance(
      id: id,
      name: name is String ? name : '',
      bubbleColor: color is String ? color : null,
      clips: clips,
    );
  }

  /// Whether [other] is the same persona with the same clips (the bubble
  /// color and name may differ).
  bool sameClipsAs(PersonaAppearance? other) {
    if (other == null || other.id != id || other.clips.length != clips.length) {
      return false;
    }
    for (final entry in clips.entries) {
      if (other.clips[entry.key] != entry.value) return false;
    }
    return true;
  }

  @override
  bool operator ==(Object other) {
    if (other is! PersonaAppearance) return false;
    if (other.id != id ||
        other.name != name ||
        other.bubbleColor != bubbleColor ||
        other.clips.length != clips.length) {
      return false;
    }
    for (final entry in clips.entries) {
      if (other.clips[entry.key] != entry.value) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
    id,
    name,
    bubbleColor,
    Object.hashAll([
      for (final state in AssistantActivity.values)
        if (clips[state] case final clip?) Object.hash(state, clip),
    ]),
  );
}

/// What one [PersonaAppearanceService.sync] did.
enum PersonaSyncStatus {
  /// The server answered and nothing differed from the cache.
  unchanged,

  /// The server answered and the cache or the clips on disk changed.
  updated,

  /// The server did not answer usefully (offline, timeout, 401, bad body);
  /// the cached persona stays in force.
  kept,
}

class PersonaSyncOutcome {
  const PersonaSyncOutcome(this.status, this.appearance);

  final PersonaSyncStatus status;

  /// The persona to show now: the cache after the sync, possibly null.
  final PersonaAppearance? appearance;
}

/// Maps a clip's media type to a file extension.
String personaClipExtension(String contentType) {
  final type = contentType.split(';').first.trim().toLowerCase();
  return switch (type) {
    'video/mp4' => 'mp4',
    'video/quicktime' => 'mov',
    'video/webm' => 'webm',
    'video/x-m4v' => 'm4v',
    'video/3gpp' => '3gp',
    'video/x-matroska' => 'mkv',
    'image/png' => 'png',
    'image/jpeg' || 'image/jpg' => 'jpg',
    'image/gif' => 'gif',
    'image/webp' => 'webp',
    'image/heic' => 'heic',
    _ when type.startsWith('video/') => 'mp4',
    _ => 'jpg',
  };
}

/// Normalizes what the user typed as the Switchboard address: trimmed,
/// `http://` added when no scheme is given, no trailing slash. Null when it
/// is empty or not an http(s) URL.
String? normalizeSwitchboardUrl(String raw) {
  var value = raw.trim();
  if (value.isEmpty) return null;
  if (!value.contains('://')) value = 'http://$value';
  final uri = Uri.tryParse(value);
  if (uri == null || !uri.hasAuthority || uri.host.isEmpty) return null;
  if (uri.scheme != 'http' && uri.scheme != 'https') return null;
  while (value.endsWith('/')) {
    value = value.substring(0, value.length - 1);
  }
  return value;
}

/// Asks a Switchboard server which persona is active and keeps its clips on
/// disk under `<documents>/assistant_avatar/personas/<id>/<state>.<ext>`,
/// with the last good answer cached in preferences.
///
/// It never throws and never changes the cache on a failed request: offline,
/// a timeout, a 401 or an unreadable answer all keep the last persona.
class PersonaAppearanceService {
  PersonaAppearanceService({
    Dio? dio,
    Future<Directory> Function()? documentsDirectory,
    String? Function()? readCache,
    Future<void> Function(String? value)? writeCache,
    this.requestTimeout = kPersonaRequestTimeout,
    this.clipTimeout = kPersonaClipTimeout,
  }) : _dio = dio ?? Dio(),
       _documentsDirectory =
           documentsDirectory ?? getApplicationDocumentsDirectory,
       _readCache =
           readCache ??
           (() => PreferencesStore.getString(
             PreferenceKeys.personaAppearanceCache,
           )),
       _writeCache =
           writeCache ??
           ((value) => PreferencesStore.put(
             PreferenceKeys.personaAppearanceCache,
             value,
           ));

  final Dio _dio;
  final Future<Directory> Function() _documentsDirectory;
  final String? Function() _readCache;
  final Future<void> Function(String? value) _writeCache;
  final Duration requestTimeout;
  final Duration clipTimeout;

  /// The folder holding every persona's clips.
  Future<Directory> personasFolder() async {
    final documents = await _documentsDirectory();
    return Directory(p.join(documents.path, 'assistant_avatar', 'personas'));
  }

  /// The last good answer, or null when there is none.
  PersonaAppearance? loadCached() {
    try {
      final raw = _readCache();
      if (raw == null || raw.isEmpty) return null;
      return PersonaAppearance.fromCacheJson(jsonDecode(raw));
    } catch (error) {
      DebugLogger.warning(
        'cache-unreadable',
        scope: _logScope,
        data: {'error': error.runtimeType.toString()},
      );
      return null;
    }
  }

  /// Fetches the active persona from [baseUrl] with [token] and brings the
  /// clips on disk and the cache up to date.
  Future<PersonaSyncOutcome> sync({
    required String baseUrl,
    required String token,
  }) async {
    final cached = loadCached();
    try {
      final base = normalizeSwitchboardUrl(baseUrl);
      if (base == null || token.trim().isEmpty) {
        return PersonaSyncOutcome(PersonaSyncStatus.kept, cached);
      }
      final fetched = await _fetchActive(base, token.trim());
      if (fetched == null) {
        return PersonaSyncOutcome(PersonaSyncStatus.kept, cached);
      }
      final result = await _apply(base, token.trim(), fetched, cached);
      final changed = result != cached;
      if (changed) await _writeCache(jsonEncode(result.toJson()));
      return PersonaSyncOutcome(
        changed ? PersonaSyncStatus.updated : PersonaSyncStatus.unchanged,
        result,
      );
    } catch (error, stackTrace) {
      DebugLogger.error(
        'sync-failed',
        scope: _logScope,
        error: error,
        stackTrace: stackTrace,
      );
      return PersonaSyncOutcome(PersonaSyncStatus.kept, cached);
    }
  }

  Future<Response<T>> _get<T>(
    String url,
    String token,
    ResponseType responseType,
    Duration timeout,
  ) {
    final cancel = CancelToken();
    final timer = Timer(timeout, () => cancel.cancel('timeout'));
    return _dio
        .get<T>(
          url,
          cancelToken: cancel,
          options: Options(
            headers: {'Authorization': 'Bearer $token'},
            responseType: responseType,
            sendTimeout: timeout,
            receiveTimeout: timeout,
            validateStatus: (_) => true,
          ),
        )
        .whenComplete(timer.cancel);
  }

  /// The server's active persona, or null for any failure (logged quietly).
  Future<PersonaAppearance?> _fetchActive(String base, String token) async {
    try {
      final response = await _get<Object>(
        '$base/api/personas/active',
        token,
        ResponseType.plain,
        requestTimeout,
      );
      final status = response.statusCode ?? 0;
      if (status != 200) {
        DebugLogger.log(
          status == 401 || status == 403 ? 'unauthorized' : 'bad-status',
          scope: _logScope,
          data: {'status': status},
        );
        return null;
      }
      final data = response.data;
      final decoded = data is String ? jsonDecode(data) : data;
      final parsed = PersonaAppearance.fromServerJson(decoded);
      if (parsed == null) {
        DebugLogger.log('bad-body', scope: _logScope);
      }
      return parsed;
    } on DioException catch (error) {
      DebugLogger.log(
        'unreachable',
        scope: _logScope,
        data: {'type': error.type.name},
      );
      return null;
    } catch (error) {
      DebugLogger.log(
        'fetch-failed',
        scope: _logScope,
        data: {'error': error.runtimeType.toString()},
      );
      return null;
    }
  }

  /// Makes the disk match [fetched] as far as downloads succeed and returns
  /// the appearance that is really available.
  Future<PersonaAppearance> _apply(
    String base,
    String token,
    PersonaAppearance fetched,
    PersonaAppearance? cached,
  ) async {
    final folder = await personasFolder();
    final dir = Directory(p.join(folder.path, fetched.id));
    final samePersona = cached?.id == fetched.id;
    final have = <AssistantActivity, PersonaClip>{};
    for (final entry in fetched.clips.entries) {
      final state = entry.key;
      final clip = entry.value;
      final existing = await _fileFor(dir, state);
      final old = samePersona ? cached!.clips[state] : null;
      if (old != null && old.etag == clip.etag && existing != null) {
        have[state] = clip;
        continue;
      }
      final stored =
          clip.url.isNotEmpty &&
          await _download(base, token, clip.url, dir, state, clip);
      if (stored) {
        have[state] = clip;
      } else if (old != null && existing != null) {
        // Keep the older clip rather than show nothing.
        have[state] = old;
      }
    }
    await _removeStaleStates(dir, have.keys.toSet());
    await _removeOtherPersonas(folder, fetched.id);
    return PersonaAppearance(
      id: fetched.id,
      name: fetched.name,
      bubbleColor: fetched.bubbleColor,
      clips: have,
    );
  }

  Future<File?> _fileFor(Directory dir, AssistantActivity state) async {
    try {
      if (!await dir.exists()) return null;
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is File &&
            p.basenameWithoutExtension(entity.path) == state.name) {
          return entity;
        }
      }
    } catch (_) {}
    return null;
  }

  Future<bool> _download(
    String base,
    String token,
    String url,
    Directory dir,
    AssistantActivity state,
    PersonaClip clip,
  ) async {
    try {
      final target = url.startsWith('/') ? '$base$url' : '$base/$url';
      final response = await _get<List<int>>(
        target,
        token,
        ResponseType.bytes,
        clipTimeout,
      );
      final bytes = response.data;
      if (response.statusCode != 200 || bytes == null || bytes.isEmpty) {
        DebugLogger.log(
          'clip-failed',
          scope: _logScope,
          data: {'state': state.name, 'status': response.statusCode},
        );
        return false;
      }
      await dir.create(recursive: true);
      final extension = personaClipExtension(clip.contentType);
      final finalPath = p.join(dir.path, '${state.name}.$extension');
      final part = File('$finalPath.part');
      await part.writeAsBytes(bytes, flush: true);
      await _deleteState(dir, state);
      await part.rename(finalPath);
      DebugLogger.log(
        'clip-stored',
        scope: _logScope,
        data: {'state': state.name, 'bytes': bytes.length},
      );
      return true;
    } catch (error) {
      DebugLogger.log(
        'clip-error',
        scope: _logScope,
        data: {'state': state.name, 'error': error.runtimeType.toString()},
      );
      return false;
    }
  }

  Future<void> _deleteState(Directory dir, AssistantActivity state) async {
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is File &&
          p.basenameWithoutExtension(entity.path) == state.name) {
        await entity.delete();
      }
    }
  }

  Future<void> _removeStaleStates(
    Directory dir,
    Set<AssistantActivity> keep,
  ) async {
    try {
      if (!await dir.exists()) return;
      final names = {for (final state in keep) state.name};
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File) continue;
        final name = p.basenameWithoutExtension(entity.path);
        final isState = AssistantActivity.values.any((s) => s.name == name);
        if (isState && !names.contains(name)) await entity.delete();
      }
    } catch (_) {}
  }

  Future<void> _removeOtherPersonas(Directory folder, String keepId) async {
    try {
      if (!await folder.exists()) return;
      await for (final entity in folder.list(followLinks: false)) {
        if (entity is Directory && p.basename(entity.path) != keepId) {
          await entity.delete(recursive: true);
        }
      }
    } catch (_) {}
  }
}

final personaAppearanceServiceProvider = Provider<PersonaAppearanceService>(
  (ref) => PersonaAppearanceService(),
);

/// Whether a Switchboard token is stored, and the way to set it. The value
/// itself stays in secure storage.
final switchboardTokenProvider =
    NotifierProvider<SwitchboardTokenController, bool>(
      SwitchboardTokenController.new,
    );

class SwitchboardTokenController extends Notifier<bool> {
  SecureCredentialStorage get _storage =>
      SecureCredentialStorage(instance: ref.read(secureStorageProvider));

  @override
  bool build() {
    unawaited(_load());
    return false;
  }

  Future<void> _load() async {
    try {
      final token = await _storage.readSwitchboardToken();
      if (ref.mounted) state = token != null && token.isNotEmpty;
    } catch (_) {}
  }

  Future<String?> read() async {
    try {
      return await _storage.readSwitchboardToken();
    } catch (_) {
      return null;
    }
  }

  /// Stores [token] (blank removes it) and asks for a fresh persona.
  Future<void> set(String? token) async {
    await _storage.writeSwitchboardToken(token);
    if (!ref.mounted) return;
    state = (token?.trim().isNotEmpty ?? false);
    unawaited(ref.read(personaAppearanceProvider.notifier).refresh());
  }
}

/// The cached persona appearance, refreshed from the server at start, on
/// resume, when a chat opens (see [refresh]) and when the setting, address
/// or token change. Null until a persona has been fetched once.
final personaAppearanceProvider =
    NotifierProvider<PersonaAppearanceController, PersonaAppearance?>(
      PersonaAppearanceController.new,
    );

class PersonaAppearanceController extends Notifier<PersonaAppearance?>
    with WidgetsBindingObserver {
  Future<void>? _inFlight;

  @override
  PersonaAppearance? build() {
    final service = ref.read(personaAppearanceServiceProvider);
    final cached = service.loadCached();
    WidgetsBinding.instance.addObserver(this);
    ref.onDispose(() => WidgetsBinding.instance.removeObserver(this));
    ref.listen(
      appSettingsProvider.select(
        (s) => (s.personaAppearanceEnabled, s.personaAppearanceUrl),
      ),
      (_, next) {
        if (next.$1) unawaited(refresh());
      },
    );
    if (ref.read(appSettingsProvider).personaAppearanceEnabled) {
      Future<void>.microtask(refresh);
    }
    return cached;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(refresh());
  }

  /// Asks the server now. Does nothing while the setting is off, when no
  /// address or token is set, or while an earlier ask is still running.
  Future<void> refresh() {
    final running = _inFlight;
    if (running != null) return running;
    final settings = ref.read(appSettingsProvider);
    if (!settings.personaAppearanceEnabled ||
        settings.personaAppearanceUrl.trim().isEmpty) {
      return Future<void>.value();
    }
    return _inFlight = _run(settings.personaAppearanceUrl).whenComplete(() {
      _inFlight = null;
    });
  }

  Future<void> _run(String url) async {
    final token = await ref.read(switchboardTokenProvider.notifier).read();
    if (token == null || token.isEmpty || !ref.mounted) return;
    final outcome = await ref
        .read(personaAppearanceServiceProvider)
        .sync(baseUrl: url, token: token);
    if (!ref.mounted) return;
    if (outcome.status == PersonaSyncStatus.updated) {
      state = outcome.appearance;
    }
  }
}

/// The persona appearance to apply right now: null while "Match persona
/// from Switchboard" is off, so every consumer falls back to the user's own
/// clips and bubble color at once.
final activePersonaAppearanceProvider = Provider<PersonaAppearance?>((ref) {
  final on = ref.watch(
    appSettingsProvider.select((s) => s.personaAppearanceEnabled),
  );
  if (!on) return null;
  return ref.watch(personaAppearanceProvider);
});
