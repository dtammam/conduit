/// How sure the recognizer was of a transcript, when it says.
///
/// Whisper's verbose answer carries, per segment, the mean log probability of
/// its tokens and the probability that the audio held no speech. A take of
/// the assistant's own voice through the phone speaker can come back as an
/// invented word ("Tinha", 2026-10-24 15:47); those come with low token
/// probability or a high no-speech probability.
class TranscriptionConfidence {
  const TranscriptionConfidence({
    required this.avgLogprob,
    required this.noSpeechProb,
  });

  /// Mean of the segments' `avg_logprob`.
  final double avgLogprob;

  /// Highest of the segments' `no_speech_prob`.
  final double noSpeechProb;

  /// Whether the recognizer itself doubts there was speech: no-speech above
  /// 0.5 or mean log probability below -1.0.
  bool get doubtful => noSpeechProb > 0.5 || avgLogprob < -1.0;

  /// From a verbose transcription answer; null without usable segments.
  static TranscriptionConfidence? fromVerboseJson(Map<String, dynamic> json) {
    final segments = json['segments'];
    if (segments is! List || segments.isEmpty) return null;
    final logprobs = <double>[];
    var noSpeech = 0.0;
    for (final segment in segments) {
      if (segment is! Map) continue;
      final logprob = segment['avg_logprob'];
      final silence = segment['no_speech_prob'];
      if (logprob is num) logprobs.add(logprob.toDouble());
      if (silence is num && silence.toDouble() > noSpeech) {
        noSpeech = silence.toDouble();
      }
    }
    if (logprobs.isEmpty) return null;
    return TranscriptionConfidence(
      avgLogprob: logprobs.reduce((a, b) => a + b) / logprobs.length,
      noSpeechProb: noSpeech,
    );
  }
}

/// The confidence of recent transcripts, by their text.
///
/// Transcripts reach voice mode as plain text through several layers; the
/// speech provider records each one's confidence here and the barge-in check
/// looks it up for the same take. Entries older than [maxAge] are ignored.
class TranscriptionConfidenceLog {
  TranscriptionConfidenceLog._();

  static final instance = TranscriptionConfidenceLog._();

  static const Duration maxAge = Duration(seconds: 30);
  static const int _capacity = 16;

  final _entries =
      <({String text, TranscriptionConfidence value, DateTime at})>[];

  void record(String text, TranscriptionConfidence confidence, {DateTime? at}) {
    final key = _normalize(text);
    if (key.isEmpty) return;
    _entries
      ..removeWhere((entry) => entry.text == key)
      ..add((text: key, value: confidence, at: at ?? DateTime.now()));
    if (_entries.length > _capacity) _entries.removeAt(0);
  }

  TranscriptionConfidence? lookup(String text, {DateTime? now}) {
    final key = _normalize(text);
    final time = now ?? DateTime.now();
    for (final entry in _entries.reversed) {
      if (entry.text == key && time.difference(entry.at) <= maxAge) {
        return entry.value;
      }
    }
    return null;
  }

  void clear() => _entries.clear();

  static String _normalize(String text) =>
      text.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
}
