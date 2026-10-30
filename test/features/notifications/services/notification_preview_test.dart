import 'package:checks/checks.dart';
import 'package:conduit/features/notifications/services/notification_router.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a formatted reply reads as one clean line', () {
    check(
      notificationPreview(
        "Here's your update for tomorrow.\n\n**Calendar**\n- 8:00 AM Garbage Pickup\n- 5:00 PM Magic Night",
      ),
    ).equals(
      "Here's your update for tomorrow. Calendar 8:00 AM Garbage Pickup 5:00 PM Magic Night",
    );
  });

  test('links keep their text, code and images go', () {
    check(
      notificationPreview(
        'See [the forecast](https://x.test) ![img](a.png)\n```\ncode\n```\n> quoted',
      ),
    ).equals('See the forecast quoted');
  });

  test('a long reply is cut at a word with an ellipsis', () {
    final out = notificationPreview(List.filled(60, 'word').join(' '));
    check(out.length).isLessOrEqual(161);
    check(out.endsWith('word…')).isTrue();
  });

  test('snake_case survives', () {
    check(notificationPreview('see file_name here'))
        .equals('see file_name here');
  });
}
