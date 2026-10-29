import 'dart:async';

import 'package:conduit/features/chat/avatar/persona_appearance_service.dart'
    show switchboardTokenProvider;
import 'package:conduit/features/notifications/providers/notification_socket_listener.dart'
    show openChatById;
import 'package:conduit_core/features/chat/omni/omni_chat.dart';
import 'package:conduit_core/features/chat/omni/routine_reply_marker.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/sync/sync_engine.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'routines_providers.dart';

const String _logScope = 'routines/push';

/// Where this phone stands with Apple push.
@immutable
class PushStatus {
  const PushStatus({
    this.authorization = 'unknown',
    this.registered = false,
    this.env = '',
    this.busy = false,
  });

  /// `notDetermined`, `denied`, `authorized`, `provisional`, `ephemeral`, or
  /// `unknown` before the first answer.
  final String authorization;

  /// Whether the server holds this phone's token (set after the last
  /// successful registration in this run).
  final bool registered;

  /// `sandbox` or `production`.
  final String env;
  final bool busy;

  bool get allowed =>
      authorization == 'authorized' ||
      authorization == 'provisional' ||
      authorization == 'ephemeral';

  PushStatus copyWith({
    String? authorization,
    bool? registered,
    String? env,
    bool? busy,
  }) => PushStatus(
    authorization: authorization ?? this.authorization,
    registered: registered ?? this.registered,
    env: env ?? this.env,
    busy: busy ?? this.busy,
  );

  @override
  bool operator ==(Object other) =>
      other is PushStatus &&
      other.authorization == authorization &&
      other.registered == registered &&
      other.env == env &&
      other.busy == busy;

  @override
  int get hashCode => Object.hash(authorization, registered, env, busy);
}

/// The native side of push: permission, the device token, the key that seals
/// each push, and the taps and replies on a routine notification.
abstract class PushPlatform {
  bool get supported;
  Future<Map<String, Object?>?> status();
  Future<Map<String, Object?>?> requestAuthorization();
  Future<Map<String, Object?>?> registerIfAuthorized();
  Future<Map<String, Object?>?> registration();
  Future<bool> configureRelay({required String url, required String token});
  Future<void> unregister();
  Future<List<Map<String, Object?>>> drainEvents();

  /// Receives events the native side pushes after [drainEvents].
  set onEvent(void Function(Map<String, Object?> event)? handler);
}

class MethodChannelPushPlatform implements PushPlatform {
  MethodChannelPushPlatform();

  static const MethodChannel _channel = MethodChannel('am.tamm.conduit/push');

  @override
  bool get supported => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  Future<Map<String, Object?>?> _map(String method, [Object? args]) async {
    if (!supported) return null;
    try {
      final raw = await _channel.invokeMethod<Object>(method, args);
      return raw is Map ? raw.cast<String, Object?>() : null;
    } on PlatformException catch (error) {
      DebugLogger.log(
        'channel-error',
        scope: _logScope,
        data: {'method': method, 'code': error.code},
      );
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<Map<String, Object?>?> status() => _map('status');

  @override
  Future<Map<String, Object?>?> requestAuthorization() =>
      _map('requestAuthorization');

  @override
  Future<Map<String, Object?>?> registerIfAuthorized() =>
      _map('registerIfAuthorized');

  @override
  Future<Map<String, Object?>?> registration() => _map('registration');

  @override
  Future<bool> configureRelay({
    required String url,
    required String token,
  }) async {
    if (!supported) return false;
    try {
      return await _channel.invokeMethod<bool>('configureRelay', {
            'url': url,
            'token': token,
          }) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<void> unregister() async {
    if (!supported) return;
    try {
      await _channel.invokeMethod<void>('unregister');
    } on PlatformException {
      // Nothing to undo.
    } on MissingPluginException {
      // Nothing to undo.
    }
  }

  @override
  Future<List<Map<String, Object?>>> drainEvents() async {
    if (!supported) return const [];
    try {
      final raw = await _channel.invokeMethod<List<Object?>>('drainEvents');
      return [
        for (final item in raw ?? const <Object?>[])
          if (item is Map) item.cast<String, Object?>(),
      ];
    } on PlatformException {
      return const [];
    } on MissingPluginException {
      return const [];
    }
  }

  @override
  set onEvent(void Function(Map<String, Object?> event)? handler) {
    if (!supported) return;
    _channel.setMethodCallHandler(
      handler == null
          ? null
          : (call) async {
              if (call.method == 'event' && call.arguments is Map) {
                handler((call.arguments as Map).cast<String, Object?>());
              }
              return null;
            },
    );
  }
}

final pushPlatformProvider = Provider<PushPlatform>(
  (ref) => MethodChannelPushPlatform(),
);

/// A typed reply to a routine notification, waiting for the chat to take it.
@immutable
class RoutineReplyRequest {
  const RoutineReplyRequest({required this.chatId, required this.text});

  final String chatId;
  final String text;
}

final routineReplyProvider =
    NotifierProvider<RoutineReplyController, RoutineReplyRequest?>(
      RoutineReplyController.new,
    );

class RoutineReplyController extends Notifier<RoutineReplyRequest?> {
  @override
  RoutineReplyRequest? build() => null;

  void request(RoutineReplyRequest request) => state = request;

  void clear() => state = null;
}

/// Registers this phone for the routines server's push and opens what its
/// notifications point at.
///
/// Nothing asks for permission by itself: [enable] is called when the person
/// turns notifications on. Registration repeats at every start and whenever
/// Apple hands out a new token; the server treats it as an upsert.
final pushRegistrationProvider = NotifierProvider<PushRegistration, PushStatus>(
  PushRegistration.new,
);

class PushRegistration extends Notifier<PushStatus> {
  bool _started = false;
  Future<void>? _syncing;

  PushPlatform get _platform => ref.read(pushPlatformProvider);

  @override
  PushStatus build() {
    // A new address or token, or turning push on, registers this phone.
    ref.listen(
      appSettingsProvider.select(
        (s) => (s.routinesServerUrl, s.routinesPushEnabled),
      ),
      (_, _) {
        if (_started) unawaited(sync());
      },
    );
    ref.listen(switchboardTokenProvider, (_, _) {
      if (_started) unawaited(sync());
    });
    return const PushStatus();
  }

  /// Hooks up the native events and registers again when push is on. Called
  /// once the app has started.
  Future<void> start() async {
    if (_started || !_platform.supported) return;
    _started = true;
    final platform = _platform;
    platform.onEvent = (event) => unawaited(_onEvent(event));
    ref.onDispose(() => platform.onEvent = null);
    await refresh();
    unawaited(sync());
    for (final event in await _platform.drainEvents()) {
      await _onEvent(event);
    }
  }

  /// Asks the phone for the permission and the registration state.
  Future<void> refresh() async {
    final raw = await _platform.status();
    if (raw == null || !ref.mounted) return;
    state = state.copyWith(
      authorization: raw['authorization'] as String? ?? state.authorization,
      env: raw['env'] as String? ?? state.env,
    );
  }

  /// Turns notifications on: asks for permission if needed, then registers.
  /// Returns whether notifications are allowed and registration was tried.
  Future<bool> enable() async {
    if (!_platform.supported) return false;
    state = state.copyWith(busy: true);
    final raw = await _platform.requestAuthorization();
    if (!ref.mounted) return false;
    final granted = _allowed(raw?['authorization']);
    state = state.copyWith(
      authorization: raw?['authorization'] as String? ?? state.authorization,
      env: raw?['env'] as String? ?? state.env,
      busy: false,
    );
    if (!granted) return false;
    await ref.read(appSettingsProvider.notifier).setRoutinesPushEnabled(true);
    await sync();
    return true;
  }

  /// Turns notifications off: the server forgets this phone.
  Future<void> disable() async {
    await ref.read(appSettingsProvider.notifier).setRoutinesPushEnabled(false);
    final registration = await _platform.registration();
    final deviceToken = registration?['token'] as String?;
    final server = await readRoutinesServer(ref);
    if (server != null && deviceToken != null) {
      await ref
          .read(routinesServiceProvider)
          .removeDevice(
            base: server.base,
            token: server.token,
            deviceToken: deviceToken,
          );
    }
    await _platform.unregister();
    if (ref.mounted) state = state.copyWith(registered: false);
  }

  /// Tells the server about this phone: token, sealing key, environment and
  /// bundle. Does nothing while push is off or the server is not set up.
  Future<void> sync() {
    final running = _syncing;
    if (running != null) return running;
    return _syncing = _sync().whenComplete(() => _syncing = null);
  }

  Future<void> _sync() async {
    if (!_platform.supported ||
        !ref.read(appSettingsProvider).routinesPushEnabled) {
      return;
    }
    final server = await readRoutinesServer(ref);
    if (server == null || !ref.mounted) return;
    // The native side needs the address and token to snooze from a
    // notification without opening the app.
    await _platform.configureRelay(url: server.base, token: server.token);
    var status = await _platform.registerIfAuthorized();
    if (!ref.mounted) return;
    if (status != null) {
      state = state.copyWith(
        authorization: status['authorization'] as String?,
        env: status['env'] as String?,
      );
    }
    final registration = await _platform.registration();
    final deviceToken = registration?['token'] as String?;
    final key = registration?['key'] as String?;
    if (deviceToken == null || key == null || !ref.mounted) {
      // Apple answers asynchronously; the token event runs this again.
      return;
    }
    final ok = await ref
        .read(routinesServiceProvider)
        .registerDevice(
          base: server.base,
          token: server.token,
          deviceToken: deviceToken,
          key: key,
          env: registration?['env'] as String? ?? 'production',
          bundle: registration?['bundle'] as String? ?? '',
          name: registration?['name'] as String? ?? '',
        );
    if (ref.mounted) state = state.copyWith(registered: ok);
  }

  bool _allowed(Object? value) =>
      value == 'authorized' || value == 'provisional' || value == 'ephemeral';

  Future<void> _onEvent(Map<String, Object?> event) async {
    try {
      switch (event['kind']) {
        case 'token':
          await sync();
        case 'open':
          await _openChat(event);
        case 'reply':
          await _reply(event);
      }
    } catch (error, stackTrace) {
      DebugLogger.error(
        'event-failed',
        scope: _logScope,
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// The chat a notification points at: its own `chat_id`, else the Omni
  /// chat.
  Future<String?> _chatIdOf(Map<String, Object?> event) async {
    final id = event['chat_id'];
    if (id is String && id.isNotEmpty) return id;
    final stored = storedOmniChatId();
    if (stored != null && stored.isNotEmpty) return stored;
    try {
      return (await ref.read(omniChatProvider.future))?.id;
    } catch (_) {
      return null;
    }
  }

  /// The next message sent in [chatId] names the routine the notification
  /// came from (nothing is armed without a valid `slug`).
  void _armReplyMarker(String chatId, Map<String, Object?> event) {
    final slug = event['slug'];
    ref
        .read(routineReplyMarkerProvider.notifier)
        .arm(chatId, slug is String ? slug : null);
  }

  Future<void> _openChat(Map<String, Object?> event) async {
    final chatId = await _chatIdOf(event);
    if (chatId == null || !ref.mounted) return;
    _armReplyMarker(chatId, event);
    // Opens the chat and pulls it from the server, so the message the
    // routine posted is there.
    await openChatById(ref, chatId);
  }

  Future<void> _reply(Map<String, Object?> event) async {
    final text = event['text'];
    final chatId = await _chatIdOf(event);
    if (text is! String || text.isEmpty || chatId == null || !ref.mounted) {
      return;
    }
    _armReplyMarker(chatId, event);
    await openChatById(ref, chatId);
    if (!ref.mounted) return;
    // The reply must hang off the routine's post, so the chat is brought up
    // to date before the chat page sends it.
    try {
      await ref.read(syncEngineProvider.notifier).pullChatNow(chatId);
    } catch (_) {
      // The chat page still sends it; the server decides the branch.
    }
    if (!ref.mounted) return;
    ref
        .read(routineReplyProvider.notifier)
        .request(RoutineReplyRequest(chatId: chatId, text: text));
  }
}
