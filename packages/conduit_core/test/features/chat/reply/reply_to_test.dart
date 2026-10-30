import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/chat/omni/omni_session.dart';
import 'package:conduit_core/features/chat/omni/routine_reply_marker.dart';
import 'package:conduit_core/features/chat/reply/reply_to.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

void main() {
  group('replyToMarker', () {
    test('formats a valid message id', () {
      check(replyToMarker('3f2a9c1e-77b0-4d1e-9a55-0c1d2e3f4a5b'))
          .equals('[reply-to:3f2a9c1e-77b0-4d1e-9a55-0c1d2e3f4a5b]');
      check(replyToMarker('a')).equals('[reply-to:a]');
      check(replyToMarker('x' * 64)).isNotNull();
    });

    test('rejects what is not a message id', () {
      for (final bad in [
        null,
        '',
        'has space',
        'new\nline',
        'a]b',
        'a_b',
        'x' * 65,
      ]) {
        check(replyToMarker(bad)).isNull();
      }
    });
  });

  group('quoteForReply', () {
    test('prefixes every line', () {
      check(quoteForReply('one\ntwo')).equals('> one\n> two');
    });

    test('keeps a leading bold title as it is', () {
      check(quoteForReply('**Title**\nBody')).equals('> **Title**\n> Body');
    });

    test('cuts at 200 characters and adds an ellipsis', () {
      final quote = quoteForReply('a' * 250);
      check(quote).equals('> ${'a' * 200}…');
      check(quoteForReply('a' * 200)).equals('> ${'a' * 200}');
    });

    test('is empty for empty text', () {
      check(quoteForReply('  \n ')).equals('');
    });
  });

  group('composeReplyText', () {
    test('quote, blank line, then the typed text', () {
      check(composeReplyText('Is it done?', 'Yes'))
          .equals('> Is it done?\n\nYes');
    });

    test('is the typed text alone when there is nothing to quote', () {
      check(composeReplyText('', 'Yes')).equals('Yes');
    });
  });

  group('splitLeadingQuote', () {
    test('splits what composeReplyText made', () {
      final split = splitLeadingQuote(composeReplyText('a\nb', 'Answer'))!;
      check(split.quote).equals('a\nb');
      check(split.rest).equals('Answer');
    });

    test('is null without a leading quote', () {
      check(splitLeadingQuote('Answer > not a quote')).isNull();
      check(splitLeadingQuote('hello\n> later')).isNull();
    });
  });

  test('replyPreview is the first non-empty line', () {
    check(replyPreview('\n\n  First line  \nsecond')).equals('First line');
  });

  group('reply target', () {
    late ProviderContainer container;
    setUp(() => container = ProviderContainer());
    tearDown(() => container.dispose());

    test('is set, replaced and cancelled', () {
      final notifier = container.read(replyTargetProvider.notifier);
      notifier.set('m1', 'First');
      check(container.read(replyTargetProvider)!.messageId).equals('m1');
      notifier.set('m2', 'Second');
      check(container.read(replyTargetProvider)!.messageId).equals('m2');
      notifier.clear();
      check(container.read(replyTargetProvider)).isNull();
    });

    test('ignores a message with no text or no id', () {
      final notifier = container.read(replyTargetProvider.notifier);
      notifier.set('m1', '   ');
      notifier.set('', 'Text');
      check(container.read(replyTargetProvider)).isNull();
    });
  });

  group('pending reply', () {
    late ProviderContainer container;
    late PendingReplyToNotifier notifier;
    setUp(() {
      container = ProviderContainer();
      notifier = container.read(pendingReplyToProvider.notifier);
    });
    tearDown(() => container.dispose());

    test('is used up by the request in that chat', () {
      notifier.arm('chat-1', 'm1');
      check(notifier.take('chat-1')).equals('m1');
      check(notifier.take('chat-1')).isNull();
    });

    test('is dropped by a request in another chat', () {
      notifier.arm('chat-1', 'm1');
      check(notifier.take('chat-2')).isNull();
      check(container.read(pendingReplyToProvider)).isNull();
    });

    test('an invalid id arms nothing', () {
      notifier.arm('chat-1', 'bad id');
      check(container.read(pendingReplyToProvider)).isNull();
    });

    test('the request carries the marker, after the routine marker', () {
      notifier.arm('chat-1', 'm1');
      var out = withSystemMarker([
        {'role': 'system', 'content': 'Be brief.'},
        {'role': 'user', 'content': '> Q\n\nA'},
      ], routineReplyMarker('journal')!);
      out = withSystemMarker(out, replyToMarker(notifier.take('chat-1'))!);
      check(out.first['content'])
          .equals('Be brief.\n[routine-reply:journal]\n[reply-to:m1]');
      check(out.last['content']).equals('> Q\n\nA');
    });
  });

  test('the request builder attaches the reply marker to a new message', () {
    final source = File(
      'lib/features/chat/providers/chat_openwebui_requests.dart',
    ).readAsStringSync();
    check(source).contains('pendingReplyToProvider.notifier');
    check(source).contains('replyToMarker(replyToId)');
  });
}
