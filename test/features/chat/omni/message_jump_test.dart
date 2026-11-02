import 'package:checks/checks.dart';
import 'package:conduit/features/chat/omni/message_jump.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('messageIdFromPushEvent', () {
    test('reads the message id the relay sealed into the push', () {
      check(messageIdFromPushEvent({'kind': 'open', 'message_id': 'abc-1'}))
          .equals('abc-1');
    });

    test('an older push without one gives null', () {
      check(messageIdFromPushEvent({'kind': 'open', 'chat_id': 'c'})).isNull();
      check(messageIdFromPushEvent({'message_id': ''})).isNull();
      check(messageIdFromPushEvent({'message_id': '  '})).isNull();
      check(messageIdFromPushEvent({'message_id': 7})).isNull();
    });
  });

  group('transcriptCountToReveal', () {
    final ids = [for (var i = 0; i < 120; i++) 'm$i'];

    test('0 when the message is already in the shown window', () {
      check(
        transcriptCountToReveal(ids: ids, messageId: 'm100', loadedCount: 50),
      ).equals(0);
      check(
        transcriptCountToReveal(ids: ids, messageId: 'm119', loadedCount: 50),
      ).equals(0);
    });

    test('how many newest messages must be shown for an older one', () {
      check(
        transcriptCountToReveal(ids: ids, messageId: 'm10', loadedCount: 50),
      ).equals(110);
      check(transcriptCountToReveal(ids: ids, messageId: 'm0', loadedCount: 50))
          .equals(120);
    });

    test('null when the transcript does not hold it', () {
      check(
        transcriptCountToReveal(ids: ids, messageId: 'nope', loadedCount: 50),
      ).isNull();
      check(
        transcriptCountToReveal(ids: const [], messageId: 'm1', loadedCount: 0),
      ).isNull();
    });
  });

  group('MessageJumpRequest', () {
    test('expires after the patience window', () {
      final at = DateTime.utc(2026, 11, 2, 12);
      final request = MessageJumpRequest(
        chatId: 'c',
        messageId: 'm',
        requestedAt: at,
      );
      check(request.expired(at.add(const Duration(seconds: 19)))).isFalse();
      check(request.expired(at.add(const Duration(seconds: 21)))).isTrue();
    });

    test('the controller holds one request and clears it', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      check(container.read(messageJumpProvider)).isNull();
      container.read(messageJumpProvider.notifier).request('c1', 'm1');
      check(container.read(messageJumpProvider)!.messageId).equals('m1');
      container.read(messageJumpProvider.notifier).clear();
      check(container.read(messageJumpProvider)).isNull();
    });
  });

  test('a flashed message is highlighted, then not', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.listen(highlightedMessageProvider, (_, _) {});
    container
        .read(highlightedMessageProvider.notifier)
        .flash('m1', duration: const Duration(milliseconds: 30));
    check(container.read(highlightedMessageProvider)).equals('m1');
    await Future<void>.delayed(const Duration(milliseconds: 80));
    check(container.read(highlightedMessageProvider)).isNull();
  });
}
