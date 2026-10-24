import 'package:checks/checks.dart';
import 'package:conduit_core/features/chat/server_speech/transcription_confidence.dart';
import 'package:conduit_core/voice/barge_in_echo.dart';
import 'package:test/test.dart';

void main() {
  const assistant =
      "Good morning, Sam! I'm doing great. Your day has two meetings.";

  test('the assistant\'s own words are echo', () {
    check(isBargeInEcho('Good', assistant)).isTrue();
    check(isBargeInEcho('Good morning Sam.', assistant)).isTrue();
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

  group('with Whisper confidence', () {
    const sure = TranscriptionConfidence(avgLogprob: -0.2, noSpeechProb: 0.01);

    test('two confident words are the user', () {
      check(isBargeInEcho('hold on', assistant, confidence: sure)).isFalse();
      check(isBargeInEcho('next question', assistant, confidence: sure))
          .isFalse();
      check(isBargeInEcho('Tinha', assistant, confidence: sure)).isTrue();
    });

    test('a doubtful take is echo however many words', () {
      const lowLogprob = TranscriptionConfidence(
        avgLogprob: -1.4,
        noSpeechProb: 0.1,
      );
      const silence = TranscriptionConfidence(
        avgLogprob: -0.3,
        noSpeechProb: 0.7,
      );
      const take = 'what about the weather tomorrow';
      check(isBargeInEcho(take, assistant, confidence: lowLogprob)).isTrue();
      check(isBargeInEcho(take, assistant, confidence: silence)).isTrue();
      check(isBargeInEcho(take, assistant, confidence: sure)).isFalse();
    });

    test('commands still count', () {
      const silence = TranscriptionConfidence(
        avgLogprob: -2,
        noSpeechProb: 0.9,
      );
      check(isBargeInEcho('stop', assistant, confidence: silence)).isFalse();
    });
  });

  group('TranscriptionConfidence', () {
    test('reads Whisper verbose segments', () {
      final confidence = TranscriptionConfidence.fromVerboseJson({
        'text': 'hi',
        'segments': [
          {'avg_logprob': -0.2, 'no_speech_prob': 0.1},
          {'avg_logprob': -0.6, 'no_speech_prob': 0.3},
        ],
      })!;
      check(confidence.avgLogprob).isCloseTo(-0.4, 1e-9);
      check(confidence.noSpeechProb).equals(0.3);
      check(TranscriptionConfidence.fromVerboseJson({'text': 'hi'})).isNull();
    });

    test('the log finds a recent take by its text', () {
      final log = TranscriptionConfidenceLog.instance..clear();
      final at = DateTime(2026, 10, 24, 12);
      const value = TranscriptionConfidence(avgLogprob: -0.1, noSpeechProb: 0);
      log.record('  Hold On ', value, at: at);
      check(log.lookup('hold on', now: at.add(const Duration(seconds: 5))))
          .equals(value);
      check(log.lookup('hold on', now: at.add(const Duration(minutes: 1))))
          .isNull();
      log.clear();
    });
  });

  test('Whisper noise inventions are echo, even when confident', () {
    const sure = TranscriptionConfidence(avgLogprob: -0.1, noSpeechProb: 0.0);
    for (final take in [
      'Thank you.',
      'Thanks for watching!',
      'thank you so much',
      'Bye.',
      'Okay.',
      'Um, uh.',
      '.',
      'Please subscribe and see you next time',
    ]) {
      check(isBargeInEcho(take, assistant, confidence: sure)).isTrue();
    }
    // Commands still count; real words still count.
    check(isBargeInEcho('okay stop', assistant, confidence: sure)).isFalse();
    check(
      isBargeInEcho('thank you, next question', assistant, confidence: sure),
    ).isFalse();
  });
}
