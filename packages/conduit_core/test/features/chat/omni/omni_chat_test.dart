import 'package:checks/checks.dart';
import 'package:conduit_core/features/chat/omni/omni_chat.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/ports/key_value_store.dart';
import 'package:test/test.dart';

Conversation _chat(String id, {String title = 'Omni'}) => Conversation(
  id: id,
  title: title,
  createdAt: DateTime.utc(2026, 1, 1),
  updatedAt: DateTime.utc(2026, 1, 1),
);

final class _FakeGateway implements OmniChatGateway {
  _FakeGateway({this.existing = const {}, this.tagged, this.fetchError});

  final Set<String> existing;
  final Conversation? tagged;
  final Object? fetchError;
  final calls = <String>[];

  @override
  Future<Conversation?> fetchChat(String id) async {
    calls.add('fetch:$id');
    if (fetchError != null) throw fetchError!;
    return existing.contains(id) ? _chat(id) : null;
  }

  @override
  Future<Conversation?> findTaggedChat() async {
    calls.add('find-tagged');
    return tagged;
  }

  @override
  Future<Conversation> createTaggedChat({String? model}) async {
    calls.add('create:${model ?? '-'}');
    return _chat('created');
  }
}

void main() {
  group('resolveOmniChat', () {
    late List<String> stored;
    Future<void> storeId(String id) async => stored.add(id);

    setUp(() => stored = []);

    test('keeps a stored id whose chat still exists', () async {
      final gateway = _FakeGateway(existing: {'kept'});
      final chat = await resolveOmniChat(
        gateway: gateway,
        storedId: 'kept',
        storeId: storeId,
      );
      check(chat.id).equals('kept');
      check(gateway.calls).deepEquals(['fetch:kept']);
      check(stored).isEmpty();
    });

    test('a deleted stored chat falls back to the tagged one', () async {
      final gateway = _FakeGateway(tagged: _chat('tagged'));
      final chat = await resolveOmniChat(
        gateway: gateway,
        storedId: 'gone',
        storeId: storeId,
      );
      check(chat.id).equals('tagged');
      check(gateway.calls).deepEquals(['fetch:gone', 'find-tagged']);
      check(stored).deepEquals(['tagged']);
    });

    test('with no stored id the tagged chat is found first', () async {
      final gateway = _FakeGateway(tagged: _chat('tagged'));
      final chat = await resolveOmniChat(
        gateway: gateway,
        storedId: null,
        storeId: storeId,
      );
      check(chat.id).equals('tagged');
      check(gateway.calls).deepEquals(['find-tagged']);
      check(stored).deepEquals(['tagged']);
    });

    test('creates a tagged chat only when nothing carries the tag', () async {
      final gateway = _FakeGateway();
      final chat = await resolveOmniChat(
        gateway: gateway,
        storedId: 'gone',
        storeId: storeId,
        model: 'm1',
      );
      check(chat.id).equals('created');
      check(gateway.calls)
          .deepEquals(['fetch:gone', 'find-tagged', 'create:m1']);
      check(stored).deepEquals(['created']);
    });

    test('an unreachable server creates nothing', () async {
      final gateway = _FakeGateway(fetchError: StateError('offline'));
      await check(
        resolveOmniChat(gateway: gateway, storedId: 'x', storeId: storeId),
      ).throws<StateError>();
      check(gateway.calls).deepEquals(['fetch:x']);
      check(stored).isEmpty();
    });
  });

  group('shouldOpenOmniAtLaunch', () {
    bool decide({
      bool enabled = true,
      bool share = false,
      bool active = false,
      bool messages = false,
    }) => shouldOpenOmniAtLaunch(
      enabled: enabled,
      hasPendingShare: share,
      hasActiveConversation: active,
      hasMessages: messages,
    );

    test('opens on a plain cold start when the setting is on', () {
      check(decide()).isTrue();
    });

    test('stays out of the way when the setting is off', () {
      check(decide(enabled: false)).isFalse();
    });

    test('a shared payload keeps its own destination', () {
      check(decide(share: true)).isFalse();
    });

    test('a chat already opened by a link or notification wins', () {
      check(decide(active: true)).isFalse();
      check(decide(messages: true)).isFalse();
    });
  });

  group('openOmniAtLaunch', () {
    test('opens the resolved chat', () async {
      Conversation? opened;
      final result = await openOmniAtLaunch(
        grace: Duration.zero,
        shouldOpen: () => true,
        resolve: () async => _chat('omni'),
        open: (chat) async {
          opened = chat;
          return true;
        },
      );
      check(result).isTrue();
      check(opened?.id).equals('omni');
    });

    test('does nothing when the launch decision is no', () async {
      var resolved = false;
      final result = await openOmniAtLaunch(
        grace: Duration.zero,
        shouldOpen: () => false,
        resolve: () async {
          resolved = true;
          return _chat('omni');
        },
        open: (_) async => true,
      );
      check(result).isFalse();
      check(resolved).isFalse();
    });

    test('a share that lands while resolving wins', () async {
      var allowed = true;
      var opened = false;
      final result = await openOmniAtLaunch(
        grace: Duration.zero,
        shouldOpen: () => allowed,
        resolve: () async {
          allowed = false;
          return _chat('omni');
        },
        open: (_) async => opened = true,
      );
      check(result).isFalse();
      check(opened).isFalse();
    });

    test('an unreachable server falls back without an error', () async {
      final result = await openOmniAtLaunch(
        grace: Duration.zero,
        shouldOpen: () => true,
        resolve: () async => throw StateError('offline'),
        open: (_) async => true,
      );
      check(result).isFalse();
    });
  });

  group('isOmniChatId', () {
    setUp(() async {
      PreferencesStore.installLoader(() async => InMemoryKeyValueStore());
      await PreferencesStore.ensureInitialized();
    });
    tearDown(PreferencesStore.debugReset);

    test('only the stored chat, and only while the setting is on', () async {
      await storeOmniChatId('omni-id');
      await PreferencesStore.put(PreferenceKeys.omniChatEnabled, false);
      check(isOmniChatId('omni-id')).isFalse();
      await PreferencesStore.put(PreferenceKeys.omniChatEnabled, true);
      check(isOmniChatId('omni-id')).isTrue();
      check(isOmniChatId('other')).isFalse();
      check(isOmniChatId(null)).isFalse();
    });

    test('the id is stored per account', () async {
      await PreferencesStore.put(PreferenceKeys.omniChatEnabled, true);
      await PreferencesStore.put(PreferenceKeys.activeServerId, 'a');
      await PreferencesStore.put(
        PreferenceKeys.accountScopedSettingsMigrated,
        true,
      );
      await storeOmniChatId('chat-a');
      await PreferencesStore.put(PreferenceKeys.activeServerId, 'b');
      check(storedOmniChatId()).isNull();
      await storeOmniChatId('chat-b');
      check(isOmniChatId('chat-b')).isTrue();
      await PreferencesStore.put(PreferenceKeys.activeServerId, 'a');
      check(storedOmniChatId()).equals('chat-a');
    });
  });
}
