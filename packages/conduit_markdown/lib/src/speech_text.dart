/// Turning a model's answer into the pieces a voice speaks.
///
/// Mirrors Open WebUI's `getMessageContentParts` family, so an answer is split
/// the same way whether a phone or a desktop reads it aloud, and the cursor
/// logic that lets a streaming answer be spoken while it is still arriving.
library;

import 'markdown_preprocessor.dart';
import 'semantic_details.dart';

/// Open WebUI's `TTS_SPLIT_ON` values.
const String speechSplitOnPunctuation = 'punctuation';
const String speechSplitOnParagraphs = 'paragraphs';
const String speechSplitOnNone = 'none';

const int _speechMergeMinWords = 4;
const int _speechMergeMinChars = 50;

/// Mirrors OpenWebUI's `extractSentences`.
List<String> extractSentences(String text) {
  final codeBlocks = <String>[];
  var processed = text;
  var codeBlockIndex = 0;

  final codeBlockRegex = RegExp(r'```[\s\S]*?```', multiLine: true);
  processed = processed.replaceAllMapped(codeBlockRegex, (match) {
    final placeholder = '\u0000$codeBlockIndex\u0000';
    codeBlocks.add(match.group(0)!);
    codeBlockIndex++;
    return placeholder;
  });

  final sentences = processed.split(RegExp(r'(?<=[.!?])\s+|\n+')).toList();

  return sentences
      .map((sentence) {
        return sentence.replaceAllMapped(RegExp(r'\u0000(\d+)\u0000'), (m) {
          final idx = int.parse(m.group(1)!);
          return idx < codeBlocks.length ? codeBlocks[idx] : '';
        });
      })
      .map(ConduitMarkdownPreprocessor.cleanText)
      .where((s) => s.isNotEmpty)
      .toList();
}

/// Mirrors OpenWebUI's `extractParagraphsForAudio`.
List<String> extractParagraphsForAudio(String text) {
  final codeBlocks = <String>[];
  var processed = text;
  var codeBlockIndex = 0;

  final codeBlockRegex = RegExp(r'```[\s\S]*?```', multiLine: true);
  processed = processed.replaceAllMapped(codeBlockRegex, (match) {
    final placeholder = '\u0000$codeBlockIndex\u0000';
    codeBlocks.add(match.group(0)!);
    codeBlockIndex++;
    return placeholder;
  });

  final paragraphs = processed
      .split(RegExp(r'\n+'))
      .map((paragraph) {
        return paragraph.replaceAllMapped(RegExp(r'\u0000(\d+)\u0000'), (m) {
          final idx = int.parse(m.group(1)!);
          return idx < codeBlocks.length ? codeBlocks[idx] : '';
        });
      })
      .map(ConduitMarkdownPreprocessor.cleanText)
      .where((s) => s.isNotEmpty)
      .toList();

  return paragraphs;
}

/// Mirrors OpenWebUI's `extractSentencesForAudio`.
List<String> extractSentencesForAudio(String text) {
  final sentences = extractSentences(text);

  final mergedChunks = <String>[];
  for (final sentence in sentences) {
    if (mergedChunks.isEmpty) {
      mergedChunks.add(sentence);
    } else {
      final lastIndex = mergedChunks.length - 1;
      final previousText = mergedChunks[lastIndex];
      final wordCount = previousText.split(RegExp(r'\s+')).length;
      final charCount = previousText.length;

      if (wordCount < _speechMergeMinWords ||
          charCount < _speechMergeMinChars) {
        mergedChunks[lastIndex] = '$previousText $sentence';
      } else {
        mergedChunks.add(sentence);
      }
    }
  }

  return mergedChunks;
}

/// Mirrors OpenWebUI's `getMessageContentParts`.
List<String> getMessageContentParts(
  String content, {
  String splitOn = speechSplitOnPunctuation,
}) {
  final sanitizedContent = stripDetailsForSpeech(content);

  switch (splitOn) {
    case speechSplitOnParagraphs:
      return extractParagraphsForAudio(sanitizedContent);
    case speechSplitOnNone:
      final cleaned = ConduitMarkdownPreprocessor.cleanText(sanitizedContent);
      return cleaned.isEmpty ? const [] : [cleaned];
    case speechSplitOnPunctuation:
    default:
      return extractSentencesForAudio(sanitizedContent);
  }
}

/// The chunks a streaming feed made speakable, plus the cursor to resume from.
class StreamingChunkAdvance {
  const StreamingChunkAdvance({
    required this.chunks,
    required this.fedChunkCount,
    required this.spokenText,
  });

  /// Newly speakable chunks, trimmed, in playback order.
  final List<String> chunks;

  /// How many chunks of the current split have been consumed.
  final int fedChunkCount;

  /// Everything handed to playback so far, concatenated. The cursor is
  /// re-derived from this after a re-split.
  final String spokenText;
}

/// Advances a streaming read-aloud by one feed of the whole answer so far.
///
/// [chunks] is the fresh split of the accumulated text; the result is what is
/// newly speakable and the cursor for the next feed. The last chunk is held
/// back until [finalized], since it is still growing.
StreamingChunkAdvance advanceStreamingChunks({
  required List<String> chunks,
  required int fedChunkCount,
  required String spokenText,
  required bool finalized,
}) {
  // Hold the trailing chunk back until finalization: it is still growing.
  final speakableCount = finalized
      ? chunks.length
      : (chunks.length <= 1 ? 0 : chunks.length - 1);

  final resolved = _resolveStreamingCursor(
    chunks: chunks,
    fedChunkCount: fedChunkCount,
    spokenText: spokenText,
  );
  var cursor = resolved.cursor;
  final spoken = StringBuffer(resolved.spokenText);
  final pending = <String>[];

  // The part of the old response that playback heard past the point the two
  // versions stop agreeing. A rewrite usually touches one sentence and leaves
  // the rest alone, so the sentences after it are still in here and must not be
  // spoken twice.
  final alreadyHeard = spokenText.substring(resolved.spokenText.length);
  var heardCursor = 0;

  while (cursor < speakableCount) {
    final chunk = chunks[cursor];
    cursor++;
    final trimmed = chunk.trim();
    if (trimmed.isEmpty) {
      continue;
    }
    spoken.write(trimmed);
    if (heardCursor < alreadyHeard.length) {
      // Scan forward only, so a sentence that repeats later in the answer is
      // still spoken once for each time the old version was heard.
      final at = alreadyHeard.indexOf(trimmed, heardCursor);
      if (at >= 0) {
        heardCursor = at + trimmed.length;
        continue;
      }
    }
    pending.add(trimmed);
  }

  // Whatever is left of the old response playback heard stays on the end. Mid
  // stream the trailing chunk is held back, so a sentence beyond it is heard
  // history the next feed still has to match against; dropping it here would
  // let finalization queue that sentence a second time.
  spoken.write(alreadyHeard.substring(heardCursor));

  return StreamingChunkAdvance(
    chunks: pending,
    fedChunkCount: cursor,
    spokenText: spoken.toString(),
  );
}

/// Where the feed cursor sits in a freshly derived split, and the text behind
/// it.
class _StreamingCursor {
  const _StreamingCursor(this.cursor, this.spokenText);

  final int cursor;
  final String spokenText;
}

/// Re-derives the feed cursor by matching the split against the text already
/// handed to playback.
///
/// The split is re-derived from the whole accumulated response on every feed,
/// so a `</details>` arriving late removes that block from the sanitized body
/// and shifts every later chunk left. A bare index would then point past
/// sentences nobody has spoken, typically the answer itself, which is what
/// makes a response go silent after a tool call. Matching on running text
/// instead of on a single chunk keeps the cursor exact even when the same
/// sentence appears more than once, and a server rewrite mid-answer resumes at
/// the point the two versions stop agreeing.
_StreamingCursor _resolveStreamingCursor({
  required List<String> chunks,
  required int fedChunkCount,
  required String spokenText,
}) {
  if (spokenText.isEmpty || fedChunkCount <= 0) {
    return const _StreamingCursor(0, '');
  }

  final replayed = StringBuffer();
  var cursor = 0;
  var matched = '';
  for (final chunk in chunks) {
    replayed.write(chunk.trim());
    final candidate = replayed.toString();
    if (!spokenText.startsWith(candidate)) {
      break;
    }
    cursor++;
    matched = candidate;
    if (candidate.length == spokenText.length) {
      break;
    }
  }
  return _StreamingCursor(cursor, matched);
}

/// Sentences after the first that are split into clauses.
const int _voiceClauseSentences = 2;

/// A sentence longer than this many words is split into clauses.
const int _voiceClauseMaxWords = 12;

/// A clause shorter than this joins the next one.
const int _voiceClauseMinWords = 4;

/// The units a streamed reply is spoken in by voice mode: the first sentence
/// on its own however short, the next two split at commas, semicolons, colons
/// and dashes when longer than twelve words, and the rest merged the way
/// [extractSentencesForAudio] merges them.
///
/// A speech server synthesizes one request at a time, so a long second
/// sentence is still being made when a short first one has finished playing.
/// A first unit that is only the first sentence starts sooner, and shorter
/// units right after it keep the queue ahead; once it is ahead, whole
/// sentences sound more natural.
List<String> getVoiceContentParts(String content) =>
    splitIntoVoiceUnits(extractSentences(stripDetailsForSpeech(content)));

/// [sentences] (unmerged) as voice units; see [getVoiceContentParts].
List<String> splitIntoVoiceUnits(List<String> sentences) {
  final out = <String>[];
  final rest = <String>[];
  for (var i = 0; i < sentences.length; i++) {
    final sentence = sentences[i].trim();
    if (sentence.isEmpty) continue;
    if (out.isEmpty) {
      out.add(sentence);
    } else if (i <= _voiceClauseSentences) {
      out.addAll(splitSentenceIntoClauses(sentence));
    } else {
      rest.add(sentence);
    }
  }
  final merged = <String>[];
  for (final sentence in rest) {
    if (merged.isNotEmpty &&
        (_wordCount(merged.last) < _speechMergeMinWords ||
            merged.last.length < _speechMergeMinChars)) {
      merged[merged.length - 1] = '${merged.last} $sentence';
    } else {
      merged.add(sentence);
    }
  }
  out.addAll(merged);
  return out;
}

int _wordCount(String text) =>
    text.trim().isEmpty ? 0 : text.trim().split(RegExp(r'\s+')).length;

/// [sentence] cut after a comma, semicolon or colon, or before a spaced dash,
/// when it has more than twelve words; otherwise the sentence itself. Cuts
/// fall between words and keep their punctuation, and a clause of fewer than
/// four words joins the next.
List<String> splitSentenceIntoClauses(String sentence) {
  final text = sentence.trim();
  if (_wordCount(text) <= _voiceClauseMaxWords) return [text];
  final parts = <String>[];
  var start = 0;
  final cut = RegExp(r'(?<=[,;:])\s+|\s+(?=[—–-]\s)');
  for (final match in cut.allMatches(text)) {
    final part = text.substring(start, match.start).trim();
    if (part.isNotEmpty) parts.add(part);
    start = match.end;
  }
  final last = text.substring(start).trim();
  if (last.isNotEmpty) parts.add(last);
  if (parts.length < 2) return [text];

  final merged = <String>[];
  var pending = '';
  for (final part in parts) {
    pending = pending.isEmpty ? part : '$pending $part';
    if (_wordCount(pending) >= _voiceClauseMinWords) {
      merged.add(pending);
      pending = '';
    }
  }
  if (pending.isNotEmpty) {
    if (merged.isEmpty) {
      merged.add(pending);
    } else {
      merged[merged.length - 1] = '${merged.last} $pending';
    }
  }
  return merged;
}
