import 'package:checks/checks.dart';
import 'package:conduit/features/chat/views/chat_page.dart';
import 'package:conduit/features/chat/widgets/user_message_bubble.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:flutter_test/flutter_test.dart';

ChatMessage _user(String id) => ChatMessage(
  id: id,
  role: 'user',
  content: 'Send the report?',
  timestamp: DateTime.utc(2024, 1, 1),
);

ChatMessage _assistant(
  String id, {
  String content = '',
  bool isStreaming = false,
  ChatMessageError? error,
  List<ChatStatusUpdate> statusHistory = const <ChatStatusUpdate>[],
}) => ChatMessage(
  id: id,
  role: 'assistant',
  content: content,
  timestamp: DateTime.utc(2024, 1, 1),
  isStreaming: isStreaming,
  error: error,
  statusHistory: statusHistory,
);

void main() {
  group('deriveMessageReceipt', () {
    test('is none before the reply has started', () {
      final waiting = [_user('u1')];
      final placeholder = [_user('u1'), _assistant('a1', isStreaming: true)];

      check(deriveMessageReceipt(messages: waiting, messageId: 'u1'))
          .equals(MessageReceipt.none);
      check(deriveMessageReceipt(messages: placeholder, messageId: 'u1'))
          .equals(MessageReceipt.none);
    });

    test('is delivered once the reply streams, reports status, or ends', () {
      final streaming = [
        _user('u1'),
        _assistant('a1', isStreaming: true, content: 'Sure'),
      ];
      final status = [
        _user('u1'),
        _assistant(
          'a1',
          isStreaming: true,
          statusHistory: const [ChatStatusUpdate(description: 'Searching')],
        ),
      ];
      final done = [_user('u1'), _assistant('a1', content: 'Saved.')];

      for (final messages in [streaming, status, done]) {
        check(deriveMessageReceipt(messages: messages, messageId: 'u1'))
            .equals(MessageReceipt.delivered);
      }
    });

    test('is failed when the reply carries an error', () {
      final messages = [
        _user('u1'),
        _assistant(
          'a1',
          error: const ChatMessageError(content: '503 profile_switching'),
        ),
      ];

      check(deriveMessageReceipt(messages: messages, messageId: 'u1'))
          .equals(MessageReceipt.failed);
    });

    test('is failed when the send did not dispatch the message', () {
      final messages = [_user('u1')];

      check(
        deriveMessageReceipt(
          messages: messages,
          messageId: 'u1',
          failedSendMessageId: 'u1',
        ),
      ).equals(MessageReceipt.failed);
    });

    test('a successful retry after a failed send is delivered', () {
      // The page clears its failed-send id when the user regenerates, so the
      // retried reply alone decides the mark.
      final failed = [_user('u1')];
      check(
        deriveMessageReceipt(
          messages: failed,
          messageId: 'u1',
          failedSendMessageId: 'u1',
        ),
      ).equals(MessageReceipt.failed);

      final retried = [_user('u1'), _assistant('a1', content: 'Saved.')];
      check(
        deriveMessageReceipt(messages: retried, messageId: 'u1'),
      ).equals(MessageReceipt.delivered);
    });

    test('is none on every user message but the latest', () {
      final messages = [
        _user('u1'),
        _assistant('a1', content: 'First answer'),
        _user('u2'),
        _assistant('a2', content: 'Second answer'),
      ];

      check(
        deriveMessageReceipt(
          messages: messages,
          messageId: 'u1',
          failedSendMessageId: 'u1',
        ),
      ).equals(MessageReceipt.none);
      check(deriveMessageReceipt(messages: messages, messageId: 'u2'))
          .equals(MessageReceipt.delivered);
    });
  });
}
