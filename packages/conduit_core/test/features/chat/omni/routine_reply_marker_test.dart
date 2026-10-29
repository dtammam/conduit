import 'package:checks/checks.dart';
import 'package:conduit_core/features/chat/omni/omni_session.dart';
import 'package:conduit_core/features/chat/omni/routine_reply_marker.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

final _t0 = DateTime.utc(2026, 10, 29, 8);

void main() {
  group('routineReplyMarker', () {
    test('formats a valid slug', () {
      check(routineReplyMarker('daily-journal-prompt'))
          .equals('[routine-reply:daily-journal-prompt]');
      check(routineReplyMarker('a')).equals('[routine-reply:a]');
    });

    test('rejects what is not a routine id', () {
      for (final bad in [
        null,
        '',
        '-lead',
        'Upper',
        'has space',
        'new\nline',
        'a]b',
        'x' * 49,
      ]) {
        check(routineReplyMarker(bad)).isNull();
      }
      check(routineReplyMarker('x' * 48)).isNotNull();
    });
  });

  group('pending routine reply', () {
    late ProviderContainer container;
    late RoutineReplyMarkerNotifier notifier;

    setUp(() {
      container = ProviderContainer();
      notifier = container.read(routineReplyMarkerProvider.notifier);
    });
    tearDown(() => container.dispose());

    test('is used up by the next send in that chat', () {
      notifier.arm('chat-1', 'journal', now: _t0);
      check(notifier.take('chat-1', now: _t0.add(const Duration(minutes: 5))))
          .equals('journal');
      check(notifier.take('chat-1', now: _t0)).isNull();
      check(container.read(routineReplyMarkerProvider)).isNull();
    });

    test('expires after 30 minutes', () {
      notifier.arm('chat-1', 'journal', now: _t0);
      check(notifier.take('chat-1', now: _t0.add(const Duration(minutes: 31))))
          .isNull();
      notifier.arm('chat-1', 'journal', now: _t0);
      check(notifier.take('chat-1', now: _t0.add(const Duration(minutes: 30))))
          .equals('journal');
    });

    test('is dropped by a send in another chat', () {
      notifier.arm('chat-1', 'journal', now: _t0);
      check(notifier.take('chat-2', now: _t0)).isNull();
      check(notifier.take('chat-1', now: _t0)).isNull();
    });

    test('is cleared when the chat is switched', () {
      notifier.arm('chat-1', 'journal', now: _t0);
      notifier.keepOnlyFor('chat-1');
      check(container.read(routineReplyMarkerProvider)).isNotNull();
      notifier.keepOnlyFor('chat-2');
      check(container.read(routineReplyMarkerProvider)).isNull();
    });

    test('a missing or invalid slug arms nothing', () {
      notifier.arm('chat-1', 'journal', now: _t0);
      notifier.arm('chat-1', null, now: _t0);
      check(container.read(routineReplyMarkerProvider)).isNull();
      notifier.arm('chat-1', 'Bad Slug', now: _t0);
      check(container.read(routineReplyMarkerProvider)).isNull();
    });

    test('the request of a notification reply carries the marker', () {
      notifier.arm('chat-1', 'journal', now: _t0);
      final slug = notifier.take('chat-1', now: _t0);
      final out = withSystemMarker([
        {'role': 'system', 'content': 'Be brief.'},
        {'role': 'user', 'content': 'Thanks'},
      ], routineReplyMarker(slug)!);
      check(out.first['content']).equals('Be brief.\n[routine-reply:journal]');
      check(out.last['content']).equals('Thanks');
    });
  });
}
