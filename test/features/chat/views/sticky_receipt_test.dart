import 'package:checks/checks.dart';
import 'package:conduit/features/chat/views/chat_page.dart';
import 'package:conduit/features/chat/widgets/user_message_bubble.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:flutter_test/flutter_test.dart';

ChatMessage _user(String id) => ChatMessage(
  id: id,
  role: 'user',
  content: 'Hello',
  timestamp: DateTime.utc(2024, 1, 1),
);

ChatMessage _assistant(
  String id, {
  String content = 'Done.',
  bool isStreaming = false,
  ChatMessageError? error,
}) => ChatMessage(
  id: id,
  role: 'assistant',
  content: content,
  timestamp: DateTime.utc(2024, 1, 1),
  isStreaming: isStreaming,
  error: error,
);

MessageReceipt _of(List<ChatMessage> messages, String id, {String? failed}) =>
    deriveStickyReceipt(
      messages: messages,
      messageId: id,
      failedSendMessageId: failed,
    );

void main() {
  group('deriveStickyReceipt', () {
    test('an older turn keeps its mark after newer messages arrive', () {
      final one = [_user('u1'), _assistant('a1')];
      check(_of(one, 'u1')).equals(MessageReceipt.delivered);

      final three = [
        ...one,
        _user('u2'),
        _assistant('a2'),
        _user('u3'),
        _assistant('a3', content: '', isStreaming: true),
      ];
      check(_of(three, 'u1')).equals(MessageReceipt.delivered);
      check(_of(three, 'u2')).equals(MessageReceipt.delivered);
      // The newest turn waits for its reply to start, as before.
      check(_of(three, 'u3')).equals(MessageReceipt.none);
    });

    test('is the same for a chat loaded cold: nothing is stored for it', () {
      // The mark reads only the messages, so a reload or a restart that
      // brings the same history back brings the same marks back.
      final history = [
        _user('u1'),
        _assistant('a1'),
        _user('u2'),
        _assistant('a2'),
      ];
      final reloaded = [for (final m in history) m.copyWith()];
      for (final id in ['u1', 'u2']) {
        check(_of(reloaded, id)).equals(_of(history, id));
        check(_of(reloaded, id)).equals(MessageReceipt.delivered);
      }
    });

    test('a failed reply or send keeps its red mark on that turn only', () {
      final messages = [
        _user('u1'),
        _assistant('a1', error: const ChatMessageError(content: '503')),
        _user('u2'),
        _assistant('a2'),
        _user('u3'),
      ];
      check(_of(messages, 'u1')).equals(MessageReceipt.failed);
      check(_of(messages, 'u2')).equals(MessageReceipt.delivered);
      check(_of(messages, 'u3', failed: 'u3')).equals(MessageReceipt.failed);
      check(_of(messages, 'u2', failed: 'u3')).equals(MessageReceipt.delivered);
    });

    test('assistant messages and unknown ids show nothing', () {
      final messages = [_user('u1'), _assistant('a1')];
      check(_of(messages, 'a1')).equals(MessageReceipt.none);
      check(_of(messages, 'missing')).equals(MessageReceipt.none);
    });
  });
}
