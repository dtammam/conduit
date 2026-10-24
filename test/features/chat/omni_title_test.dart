import 'package:checks/checks.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/ports/key_value_store.dart';
import 'package:flutter_test/flutter_test.dart';

ChatMessage _message(String id, String role) =>
    ChatMessage(id: id, role: role, content: role, timestamp: DateTime(2026));

void main() {
  setUp(() async {
    PreferencesStore.installLoader(() async => InMemoryKeyValueStore());
    await PreferencesStore.ensureInitialized();
  });
  tearDown(PreferencesStore.debugReset);

  final firstTurn = [_message('u1', 'user'), _message('a1', 'assistant')];

  bool generates(String? id) => shouldGenerateQueuedTitleForTest(
    firstTurn,
    assistantMessageId: 'a1',
    isTemporary: false,
    conversationId: id,
  );

  test('an ordinary first turn is auto-titled', () {
    check(generates('chat-1')).isTrue();
  });

  test('the Omni chat is never auto-titled', () async {
    await PreferencesStore.put(PreferenceKeys.omniChatEnabled, true);
    await PreferencesStore.put(PreferenceKeys.omniChatId, 'omni-1');
    check(generates('omni-1')).isFalse();
    check(generates('chat-1')).isTrue();
  });

  test('with the setting off the stored chat is an ordinary chat', () async {
    await PreferencesStore.put(PreferenceKeys.omniChatEnabled, false);
    await PreferencesStore.put(PreferenceKeys.omniChatId, 'omni-1');
    check(generates('omni-1')).isTrue();
  });
}
