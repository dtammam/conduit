/// Whether a take heard during a barge-in is the assistant's own voice
/// coming back through the microphone (or nothing worth answering) rather
/// than the user talking.
///
/// Echo cancellation is not perfect on a phone speaker: on 2026-10-23 the
/// microphone heard the assistant say "Good", stopped it, and sent "Good" as
/// the user's turn. A take counts as echo when it is empty, a single filler
/// sound or any take under three words, or when nearly all of its words are
/// words of [assistantText] (what the assistant is saying or just said).
/// Words that ask it to stop or wait always count as the user.
bool isBargeInEcho(String transcript, String assistantText) {
  final words = _words(transcript);
  if (words.isEmpty) return true;
  if (words.any(_commands.contains)) return false;
  // Whisper turns the assistant's own audio into short invented words
  // ("Tinha", 2026-10-24 15:47) that no overlap check can match; while the
  // assistant speaks, the user has to say at least three words to cut in.
  if (words.length < _minUserWords) return true;
  final spoken = _words(assistantText).toSet();
  if (spoken.isEmpty) return false;
  final heard = words.where(spoken.contains).length;
  return heard / words.length >= _echoShare;
}

/// Fewest words a take needs to count as the user (commands excepted).
const int _minUserWords = 3;

/// Share of the take's words that must be the assistant's for it to be echo.
const double _echoShare = 0.8;

const Set<String> _commands = {'stop', 'wait', 'pause', 'hold', 'cancel'};

/// Lower-case runs of letters, digits and apostrophes; each Han or kana
/// character is a word of its own.
List<String> _words(String text) => RegExp(
  r"[\p{sc=Han}\p{sc=Hiragana}\p{sc=Katakana}]"
  r"|(?:(?![\p{sc=Han}\p{sc=Hiragana}\p{sc=Katakana}])[\p{L}\p{N}'])+",
  unicode: true,
).allMatches(text.toLowerCase()).map((match) => match[0]!).toList();
