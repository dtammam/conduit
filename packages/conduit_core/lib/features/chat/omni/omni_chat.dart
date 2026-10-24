/// The Omni chat: one ongoing conversation that is pinned at the top of the
/// drawer and opened at launch.
///
/// Open WebUI has no notion of it, so the app designates a chat. The chat id
/// is stored per account. A chat that carries the Open WebUI tag [omniChatTag]
/// is the recovery path when the stored id is missing or the chat was deleted
/// (a reinstall, a second device); only when there is none is a new chat
/// created, titled [omniChatTitle] and tagged.
library;

import 'package:dio/dio.dart';
import 'package:riverpod/riverpod.dart';

import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/persistence/account_scoped_preferences.dart';
import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/utils/debug_logger.dart';

/// The Open WebUI tag that marks the Omni chat on the server.
const String omniChatTag = 'omni';

/// The title of the Omni chat. It is never auto-titled over.
const String omniChatTitle = 'Omni';

/// What [resolveOmniChat] needs from the server.
abstract interface class OmniChatGateway {
  /// The chat [id], or null when the server says it is gone. Any other
  /// failure (offline, a server error) throws: a chat that cannot be reached
  /// is not a chat that was deleted.
  Future<Conversation?> fetchChat(String id);

  /// A chat carrying [omniChatTag], newest first, or null when none does.
  Future<Conversation?> findTaggedChat();

  /// Creates an empty chat titled [omniChatTitle] with [model] and tags it
  /// [omniChatTag].
  Future<Conversation> createTaggedChat({String? model});
}

/// Finds or creates the Omni chat.
///
/// 1. The stored id, when that chat still exists.
/// 2. Otherwise a chat tagged [omniChatTag], which becomes the stored id.
/// 3. Otherwise a new tagged chat, which becomes the stored id.
///
/// [storeId] runs whenever the designation changes.
Future<Conversation> resolveOmniChat({
  required OmniChatGateway gateway,
  required String? storedId,
  required Future<void> Function(String id) storeId,
  String? model,
}) async {
  if (storedId != null && storedId.isNotEmpty) {
    final stored = await gateway.fetchChat(storedId);
    if (stored != null) return stored;
  }
  final tagged = await gateway.findTaggedChat();
  if (tagged != null) {
    await storeId(tagged.id);
    return tagged;
  }
  final created = await gateway.createTaggedChat(model: model);
  await storeId(created.id);
  return created;
}

/// Whether a cold start should open the Omni chat now.
///
/// Every explicit target wins: a shared payload, a notification or link that
/// already opened a chat, or something already typed.
bool shouldOpenOmniAtLaunch({
  required bool enabled,
  required bool hasPendingShare,
  required bool hasActiveConversation,
  required bool hasMessages,
}) => enabled && !hasPendingShare && !hasActiveConversation && !hasMessages;

/// Whether auto-titling must leave chat [conversationId] alone.
bool isOmniChatId(String? conversationId) {
  if (conversationId == null || conversationId.isEmpty) return false;
  if (!PreferencesStore.isReady) return false;
  final enabled =
      PreferencesStore.getBool(PreferenceKeys.omniChatEnabled) ??
      const AppSettings().omniChatEnabled;
  if (!enabled) return false;
  return storedOmniChatId() == conversationId;
}

/// The stored Omni chat id of the active account.
String? storedOmniChatId() {
  if (!PreferencesStore.isReady) return null;
  final id = PreferencesStore.getString(
    scopedPreferenceReadKey(PreferenceKeys.omniChatId),
  );
  return id == null || id.isEmpty ? null : id;
}

Future<void> storeOmniChatId(String id) => PreferencesStore.put(
  scopedPreferenceWriteKey(PreferenceKeys.omniChatId),
  id,
);

/// [OmniChatGateway] over the Open WebUI API.
class ApiOmniChatGateway implements OmniChatGateway {
  const ApiOmniChatGateway(this._api);

  final ApiService _api;

  @override
  Future<Conversation?> fetchChat(String id) async {
    try {
      return await _api.getConversation(id);
    } on DioException catch (error) {
      // Open WebUI answers a missing or foreign chat with 404, and with 401
      // on older servers. A dead session fails the tag lookup the same way,
      // so nothing is created on a mere sign-out.
      final status = error.response?.statusCode;
      if (status == 404 || status == 401 || status == 403) return null;
      rethrow;
    }
  }

  @override
  Future<Conversation?> findTaggedChat() async {
    final chats = await _api.getChatsByTag(omniChatTag, limit: 1);
    for (final chat in chats) {
      final id = chat['id']?.toString();
      if (id == null || id.isEmpty) continue;
      return Conversation(
        id: id,
        title: omniChatTitle,
        createdAt: _fromSeconds(chat['created_at']),
        updatedAt: _fromSeconds(chat['updated_at']),
        tags: const [omniChatTag],
      );
    }
    return null;
  }

  @override
  Future<Conversation> createTaggedChat({String? model}) async {
    final created = await _api.createConversation(
      title: omniChatTitle,
      messages: const [],
      model: model,
    );
    try {
      await _api.addChatTag(created.id, omniChatTag);
    } catch (error) {
      // The chat exists and is stored by id; the tag only helps recovery.
      DebugLogger.warning(
        'omni-tag-failed',
        scope: 'chat/omni',
        data: {'error': error.runtimeType.toString()},
      );
    }
    return created;
  }

  static DateTime _fromSeconds(Object? value) {
    final seconds = value is num ? value.toInt() : int.tryParse('$value');
    return DateTime.fromMillisecondsSinceEpoch(
      (seconds ?? 0) * 1000,
      isUtc: false,
    );
  }
}

/// The Omni chat of the active account, null while the setting is off or no
/// session exists. Errors (offline) surface as an [AsyncError]; callers fall
/// back to today's behaviour.
final omniChatProvider = FutureProvider<Conversation?>((ref) async {
  final enabled = ref.watch(
    appSettingsProvider.select((settings) => settings.omniChatEnabled),
  );
  ref.watch(settledActiveAccountIdProvider);
  ref.keepAlive();
  final api = ref.watch(apiServiceProvider);
  if (!enabled || api == null) return null;
  final model = await ref.read(defaultModelProvider.future);
  return resolveOmniChat(
    gateway: ApiOmniChatGateway(api),
    storedId: storedOmniChatId(),
    storeId: storeOmniChatId,
    model: model?.id,
  );
});

/// Opens the Omni chat for a cold start, last in line behind every explicit
/// target.
///
/// [shouldOpen] is asked twice: once after [grace], which lets a shared
/// payload or a tapped notification claim the launch, and again once the chat
/// is resolved, since resolving talks to the server. Anything that goes wrong
/// (no connection, a server error) leaves today's behaviour: an empty new
/// chat. Returns whether the chat was opened.
Future<bool> openOmniAtLaunch({
  required bool Function() shouldOpen,
  required Future<Conversation?> Function() resolve,
  required Future<bool> Function(Conversation omni) open,
  Duration grace = const Duration(milliseconds: 400),
}) async {
  try {
    if (grace > Duration.zero) await Future<void>.delayed(grace);
    if (!shouldOpen()) return false;
    final omni = await resolve();
    if (omni == null || !shouldOpen()) return false;
    return await open(omni);
  } catch (error) {
    DebugLogger.warning(
      'omni-launch-skipped',
      scope: 'chat/omni',
      data: {'error': error.runtimeType.toString()},
    );
    return false;
  }
}
