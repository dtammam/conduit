import 'package:conduit_markdown/conduit_markdown.dart';
import 'package:test/test.dart';

void main() {
  group('getMessageContentParts', () {
    test('merges short sentences the way Open WebUI does', () {
      expect(
        getMessageContentParts('Hi. There. This sentence is long enough.'),
        ['Hi. There. This sentence is long enough.'],
      );
      expect(
        getMessageContentParts(
          'Curious engineers optimize audio boundaries for smoother '
          'conversations. Another sentence follows to verify chunk merging.',
        ),
        hasLength(2),
      );
    });

    test('splits on paragraphs or not at all', () {
      expect(
        getMessageContentParts(
          'First paragraph\n\nSecond paragraph',
          splitOn: speechSplitOnParagraphs,
        ),
        ['First paragraph', 'Second paragraph'],
      );
      expect(
        getMessageContentParts('One.\nTwo.', splitOn: speechSplitOnNone),
        ['One.\nTwo.'],
      );
    });

    test('never speaks a reasoning block, even an open one', () {
      expect(
        getMessageContentParts(
          'Checking. <details type="reasoning" done="false">'
          '<summary>Thinking</summary>secret plans',
        ),
        ['Checking.'],
      );
    });
  });

  group('advanceStreamingChunks', () {
    test('holds the growing chunk back until the answer is done', () {
      final first = advanceStreamingChunks(
        chunks: const ['One sentence here.', 'Two is still'],
        fedChunkCount: 0,
        spokenText: '',
        finalized: false,
      );
      expect(first.chunks, ['One sentence here.']);
      final last = advanceStreamingChunks(
        chunks: const ['One sentence here.', 'Two is still going.'],
        fedChunkCount: first.fedChunkCount,
        spokenText: first.spokenText,
        finalized: true,
      );
      expect(last.chunks, ['Two is still going.']);
    });

    test('does not repeat what was heard when a block disappears', () {
      final heard = advanceStreamingChunks(
        chunks: const ['Tool output.', 'The answer.', 'More'],
        fedChunkCount: 0,
        spokenText: '',
        finalized: false,
      );
      final next = advanceStreamingChunks(
        chunks: const ['The answer.', 'More text.'],
        fedChunkCount: heard.fedChunkCount,
        spokenText: heard.spokenText,
        finalized: true,
      );
      expect(next.chunks, ['More text.']);
    });
  });

  group('splitIntoVoiceUnits', () {
    const first = "That's awesome, Dean!";
    const long =
        'Chocolate is made from roasted cocoa beans, ground into a paste, '
        'then mixed with sugar and milk; the bar is tempered and set.';

    test('the first sentence stays whole, however long', () {
      expect(splitIntoVoiceUnits([long]), [long]);
    });

    test('a long second sentence becomes clauses with their punctuation', () {
      expect(splitIntoVoiceUnits([first, long]), [
        first,
        'Chocolate is made from roasted cocoa beans,',
        'ground into a paste,',
        'then mixed with sugar and milk;',
        'the bar is tempered and set.',
      ]);
    });

    test('short sentences and later sentences stay whole', () {
      const short = 'It has cocoa, sugar and milk.';
      expect(splitIntoVoiceUnits([first, short, short, long]), [
        first,
        short,
        short,
        long,
      ]);
    });

    test('later short sentences merge as for read aloud', () {
      expect(splitIntoVoiceUnits([first, 'Two.', 'Three.', 'Ok.', 'Fine.']), [
        first,
        'Two.',
        'Three.',
        'Ok. Fine.',
      ]);
    });

    test('a short first sentence stands alone in a reply', () {
      expect(getVoiceContentParts("That's awesome, Dean! It's good."), [
        "That's awesome, Dean!",
        "It's good.",
      ]);
    });

    test('splits before a spaced dash, never inside a word', () {
      const dashed =
          'There are two kinds of fillers in a bar of chocolate — the ones '
          'that add texture and the well-known cheap ones.';
      final units = splitIntoVoiceUnits([first, dashed]);
      expect(units.sublist(1), [
        'There are two kinds of fillers in a bar of chocolate',
        '— the ones that add texture and the well-known cheap ones.',
      ]);
      expect(units.sublist(1).join(' '), dashed);
    });

    test('a long sentence without clause marks stays whole', () {
      const plain =
          'This sentence has many words but not a single comma in it at all '
          'from start to end.';
      expect(splitIntoVoiceUnits([first, plain]), [first, plain]);
    });

    test('rejoining the units gives the text back', () {
      final units = splitIntoVoiceUnits([first, long, long, long]);
      expect(units.join(' '), [first, long, long, long].join(' '));
    });
  });
}
