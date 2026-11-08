import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit/features/chat/musey/musey_feed_api.dart';
import 'package:conduit/features/notifications/services/notification_summary.dart';
import 'package:flutter_test/flutter_test.dart';

class _SummaryApi implements MuseyFeedApi {
  _SummaryApi(this.answer);
  final Future<NotificationSummary?> Function() answer;
  final List<Map<String, String?>> calls = [];

  @override
  Future<NotificationSummary?> summarize({
    required String text,
    String? ask,
    String kind = 'chat',
  }) {
    calls.add({'text': text, 'ask': ask, 'kind': kind});
    return answer();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

void main() {
  group('localNotificationFallback', () {
    test('first sentence of a markdown reply, marks removed', () {
      check(
        localNotificationFallback(
          "**Sure.** Your meeting moved to 3 PM.\n\n- one\n- two",
        ),
      ).equals('Sure. Your meeting moved to 3 PM.');
    });

    test('skips a very short opening and keeps the next sentence', () {
      check(localNotificationFallback('Ok. Your meeting moved to 3 PM today.'))
          .equals('Ok. Your meeting moved to 3 PM today.');
    });

    test('long text is cut at a word within 90 characters', () {
      final out = localNotificationFallback(List.filled(60, 'word').join(' '));
      check(out.length).isLessOrEqual(90);
      check(out.endsWith('…')).isTrue();
      check(out).not((it) => it.contains('wor…'));
    });

    test('links, code fences and bullets are cleaned', () {
      check(
        localNotificationFallback(
          '```\ncode\n```\n[Open the budget](https://x.test) is over by \$40',
        ),
      ).equals('Open the budget is over by \$40');
    });

    test('empty reply gives empty text', () {
      check(localNotificationFallback('  \n ')).equals('');
    });
  });

  group('chooseNotificationTitle', () {
    test('a real chat title wins', () {
      check(
        chooseNotificationTitle(chatTitle: 'Trip plan', assistantName: 'BMO'),
      ).equals('Trip plan');
    });

    test('a default title falls to the assistant name', () {
      check(
        chooseNotificationTitle(chatTitle: 'New Chat', assistantName: 'BMO'),
      ).equals('BMO');
      check(chooseNotificationTitle(chatTitle: ' ', assistantName: 'BMO'))
          .equals('BMO');
    });

    test('nothing known gives empty so the service shows Musey', () {
      check(chooseNotificationTitle(chatTitle: 'New Chat')).equals('');
      check(chooseNotificationTitle()).equals('');
    });
  });

  group('parseNotificationSummary', () {
    test('success reads summary and fallback', () {
      final r = parseNotificationSummary(200, {
        'summary': ' Meeting moved to 3 ',
        'fallback': 'x',
        'ms': 400,
      });
      check(r!.summary).equals('Meeting moved to 3');
      check(r.fallback).equals('x');
    });

    test('null summary keeps the fallback', () {
      final r = parseNotificationSummary(200, {
        'summary': null,
        'fallback': 'Meeting moved',
      });
      check(r!.summary).isNull();
      check(r.fallback).equals('Meeting moved');
    });

    test('404, 500 and odd bodies give null', () {
      check(parseNotificationSummary(404, {'summary': 'a'})).isNull();
      check(parseNotificationSummary(500, null)).isNull();
      check(parseNotificationSummary(null, null)).isNull();
      check(parseNotificationSummary(200, 'text')).isNull();
    });
  });

  group('notificationBody', () {
    const reply = 'Your meeting moved to 3 PM. Bring the notes.';

    test('uses the summary and sends text, ask and kind', () async {
      final api = _SummaryApi(
        () async => const NotificationSummary(summary: 'Meeting moved to 3'),
      );
      final body = await notificationBody(api, reply: reply, ask: 'when?');
      check(body).equals('Meeting moved to 3');
      check(api.calls.single)
          .deepEquals({'text': reply, 'ask': 'when?', 'kind': 'chat'});
    });

    test('summary null uses the relay fallback', () async {
      final api = _SummaryApi(
        () async => const NotificationSummary(fallback: 'Relay fallback'),
      );
      check(await notificationBody(api, reply: reply)).equals('Relay fallback');
    });

    test('404 (null answer) uses the local fallback', () async {
      final api = _SummaryApi(() async => null);
      check(await notificationBody(api, reply: reply))
          .equals('Your meeting moved to 3 PM.');
    });

    test('an error uses the local fallback', () async {
      final api = _SummaryApi(() async => throw StateError('boom'));
      check(await notificationBody(api, reply: reply))
          .equals('Your meeting moved to 3 PM.');
    });

    test('a timeout uses the local fallback without waiting', () async {
      final api = _SummaryApi(() => Completer<NotificationSummary?>().future);
      final watch = Stopwatch()..start();
      final body = await notificationBody(
        api,
        reply: reply,
        timeout: const Duration(milliseconds: 50),
      );
      check(body).equals('Your meeting moved to 3 PM.');
      check(watch.elapsedMilliseconds).isLessThan(1000);
    });

    test('no client uses the local fallback', () async {
      check(await notificationBody(null, reply: reply))
          .equals('Your meeting moved to 3 PM.');
    });
  });
}
