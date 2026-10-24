/// Whether a take heard during a barge-in is the assistant's own voice
/// coming back through the microphone (or nothing worth answering) rather
/// than the user talking.
///
/// Echo cancellation is not perfect on a phone speaker: on 2026-10-23 the
/// microphone heard the assistant say "Good", stopped it, and sent "Good" as
/// the user's turn. A take counts as echo when it is empty, a single filler
/// sound, or when nearly all of its words are words of [assistantText] (what
/// the assistant is saying or just said). Words that ask it to stop or wait
/// always count as the user.
bool isBargeInEcho(String transcript, String assistantText) {
  final words = _words(transcript);
  if (words.isEmpty) return true;
  if (words.any(_commands.contains)) return false;
  if (words.length == 1 && _fillers.contains(words.single)) return true;
  final spoken = _words(assistantText).toSet();
  if (spoken.isEmpty) return false;
  final heard = words.where(spoken.contains).length;
  return heard / words.length >= _echoShare;
}

/// Share of the take's words that must be the assistant's for it to be echo.
const double _echoShare = 0.8;

const Set<String> _fillers = {
  'um',
  'uh',
  'umm',
  'uhh',
  'hmm',
  'hm',
  'mm',
  'mmm',
  'mhm',
  'ah',
  'er',
  'eh',
  'oh',
  'huh',
};

const Set<String> _commands = {'stop', 'wait', 'pause', 'hold', 'cancel'};

/// Lower-case runs of letters, digits and apostrophes; each Han or kana
/// character is a word of its own.
List<String> _words(String text) => RegExp(
  r"[\p{sc=Han}\p{sc=Hiragana}\p{sc=Katakana}]"
  r"|(?:(?![\p{sc=Han}\p{sc=Hiragana}\p{sc=Katakana}])[\p{L}\p{N}'])+",
  unicode: true,
).allMatches(text.toLowerCase()).map((match) => match[0]!).toList();
