import 'package:checks/checks.dart';
import 'package:conduit_core/voice/barge_in_echo.dart';
import 'package:test/test.dart';

void main() {
  const assistant =
      "Good morning, Dean! I'm doing great. Your day has two meetings.";

  test('the assistant\'s own words are echo', () {
    check(isBargeInEcho('Good', assistant)).isTrue();
    check(isBargeInEcho('Good morning Dean.', assistant)).isTrue();
    check(isBargeInEcho('two meetings', assistant)).isTrue();
  });

  test('empty takes and single filler sounds are echo', () {
    check(isBargeInEcho('', assistant)).isTrue();
    check(isBargeInEcho('  ...  ', assistant)).isTrue();
    check(isBargeInEcho('Um.', assistant)).isTrue();
    check(isBargeInEcho('hmm', '')).isTrue();
  });

  test('different words are the user', () {
    check(isBargeInEcho('What about tomorrow?', assistant)).isFalse();
    check(isBargeInEcho('Good, now add lunch at noon', assistant)).isFalse();
  });

  test('takes under three words are echo, however foreign', () {
    check(isBargeInEcho('Tinha', assistant)).isTrue();
    check(isBargeInEcho('yes please', assistant)).isTrue();
    check(isBargeInEcho('Good', '')).isTrue();
  });

  test('asking it to stop or wait is always the user', () {
    check(isBargeInEcho('wait', 'Wait for it.')).isFalse();
    check(isBargeInEcho('Stop.', 'Stop and think.')).isFalse();
  });
}
