import 'dart:math' as math;

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
      expect(getMessageContentParts('One.\nTwo.', splitOn: speechSplitOnNone), [
        'One.\nTwo.',
      ]);
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
    const first = "That's awesome, Sam!";
    const long =
        'Chocolate is made from roasted cocoa beans, ground into a paste, '
        'then mixed with sugar and milk; the bar is tempered and set.';

    const longParts = [
      'Chocolate is made from roasted cocoa beans, ground into a paste, '
          'then mixed with sugar and milk;',
      'the bar is tempered and set.',
    ];

    test('a first sentence over 22 words is split at its best boundary', () {
      expect(splitIntoVoiceUnits([long]), longParts);
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
        ...longParts,
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
      expect(getVoiceContentParts("That's awesome, Sam! It's good."), [
        "That's awesome, Sam!",
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

  group('short first clause', () {
    List<String> split(List<String> sentences) =>
        splitIntoVoiceUnits(sentences, shortFirstClause: true);

    test('off by default: the first sentence stays whole', () {
      const s = 'Yes, that works fine for the three of us on Tuesday morning.';
      expect(splitIntoVoiceUnits([s]), [s]);
      expect(getVoiceContentParts(s), [s]);
    });

    test('a clause under four words is not split off', () {
      const s = 'Sure, I can move that to Tuesday at three for you.';
      expect(split([s]), [s]);
    });

    test('a long first sentence ends its first unit at the first comma', () {
      expect(
        split([
          'Your meeting with the design team is moved to Tuesday, and I '
              'also told everyone on the invite about the change.',
        ]),
        [
          'Your meeting with the design team is moved to Tuesday,',
          'and I also told everyone on the invite about the change.',
        ],
      );
    });

    test('a sentence of eight words or fewer stays whole', () {
      const s = 'I moved your meeting to Tuesday, as asked.';
      expect(split([s]), [s]);
    });

    test('semicolon, colon and spaced dash are boundaries too', () {
      expect(
        split(['The report is ready for you to read; I put it in your notes.']),
        ['The report is ready for you to read;', 'I put it in your notes.'],
      );
      expect(
        split([
          'Here is what I found about the trip: flights are cheaper now.',
        ]),
        ['Here is what I found about the trip:', 'flights are cheaper now.'],
      );
      expect(
        split([
          'The new schedule starts on Monday — I will remind you then ok.',
        ]),
        ['The new schedule starts on Monday', '— I will remind you then ok.'],
      );
    });

    test('a one-word opener merges forward with the next clause', () {
      expect(
        split([
          'Well, the plan we talked about on Monday is still on, so go ahead.',
        ]),
        [
          'Well, the plan we talked about on Monday is still on,',
          'so go ahead.',
        ],
      );
    });

    test('a short opener is not merged past about ten words', () {
      const s =
          'Dude, the platypus has a bill and webbed feet and lays eggs, so '
          'it is a strange animal.';
      final units = split([s]);
      expect(units.join(' '), s);
      expect(units.first, startsWith('Dude, the platypus'));
    });

    test('the rest of the reply is split as before and text is kept', () {
      const first =
          'Your meeting with the design team is moved to Tuesday, and I '
          'also told everyone on the invite about the change.';
      final units = split([first, 'It is at three.', 'Bring the deck.']);
      expect(units, [
        'Your meeting with the design team is moved to Tuesday,',
        'and I also told everyone on the invite about the change.',
        'It is at three.',
        'Bring the deck.',
      ]);
      expect(
        units.join(' '),
        [first, 'It is at three.', 'Bring the deck.'].join(' '),
      );
    });

    test('getVoiceContentParts passes the option through', () {
      expect(
        getVoiceContentParts(
          'Your meeting with the design team is moved to Tuesday, and I '
          'also told everyone on the invite. Bring the deck.',
          shortFirstClause: true,
        ),
        [
          'Your meeting with the design team is moved to Tuesday,',
          'and I also told everyone on the invite.',
          'Bring the deck.',
        ],
      );
    });
  });

  group('splitLongUnit', () {
    int words(String t) => t.trim().split(RegExp(r'\s+')).length;

    test(
      'a real 55-word platypus sentence becomes pieces of 6 to 22 words',
      () {
        const s =
            'Dude, the platypus has a bill like a duck, a tail like a beaver, '
            'webbed feet like an otter, and it lays eggs even though it is a '
            'mammal, which is why scientists were so confused when the first '
            'specimens reached Europe, and some of them thought it was a hoax '
            'put together by sailors.';
        final units = getVoiceContentParts(s, shortFirstClause: true);
        expect(units.length, greaterThan(2));
        for (final u in units) {
          expect(words(u), inInclusiveRange(6, 22), reason: u);
        }
        expect(units.join(' '), s);
        expect(units.first, startsWith('Dude, the platypus'));
      },
    );

    test('lists split at commas into pieces of at least six words', () {
      const s =
          'You need flour, sugar, eggs, butter, milk, salt, vanilla, baking '
          'powder, cinnamon, nutmeg, cocoa, walnuts, raisins, oats, honey '
          'and a pinch of love.';
      final units = splitLongUnit(s);
      expect(units.length, greaterThan(1));
      for (final u in units) {
        expect(words(u), inInclusiveRange(6, 22), reason: u);
      }
      expect(units.join(' '), s);
    });

    test('numbers, times and money are never cut', () {
      const s =
          'The invoice of \$1,234.56 is due at 3:30 and the second one of '
          '\$2,000.00 is due at 4:45 and the third one of \$99.99 is due at '
          '10:15 so please pay them all today.';
      final units = splitLongUnit(s);
      expect(units.join(' '), s);
      for (final token in ['\$1,234.56', '3:30', '\$2,000.00', '4:45']) {
        expect(units.where((u) => u.contains(token)).length, 1);
      }
      for (final u in units) {
        expect(u, isNot(endsWith('\$')));
        expect(u, isNot(matches(RegExp(r'\d[,:]$'))));
      }
    });

    test('quoted names stay in one piece', () {
      const s =
          'I added the song "Rock, Paper, Scissors, Lizard, Spock and Friends '
          'Forever" to the playlist you made last week for the long drive up '
          'north on Friday.';
      final units = splitLongUnit(s);
      expect(units.join(' '), s);
      expect(
        units.where((u) => u.contains('"Rock') && u.contains('Forever"')),
        hasLength(1),
      );
    });

    test('no boundary at all cuts near eighteen words', () {
      final s = List.generate(40, (i) => 'w$i').join(' ');
      final units = splitLongUnit(s);
      expect(words(units.first), 18);
      expect(units.join(' '), s);
    });

    test('short replies and units up to 22 words are unchanged', () {
      const a = 'Sure, I can do that.';
      final b = List.generate(22, (i) => 'w$i,').join(' ');
      expect(splitLongUnit(a), [a]);
      expect(splitLongUnit(b), [b]);
      expect(getVoiceContentParts('Sure. Done.'), ['Sure.', 'Done.']);
    });

    test('joining the units reproduces 200 generated sentences', () {
      final rnd = math.Random(7);
      const vocab = [
        'the',
        'a',
        'and',
        'but',
        'so',
        'which',
        'cat',
        'dog',
        '3:30',
        '\$1,234.56',
        'e.g.',
        'Dr.',
        '"Big Name"',
        '—',
        'plan',
        'moves',
      ];
      for (var n = 0; n < 200; n++) {
        final count = 1 + rnd.nextInt(80);
        final buf = <String>[];
        for (var i = 0; i < count; i++) {
          var w = vocab[rnd.nextInt(vocab.length)];
          if (rnd.nextInt(6) == 0 && w != '—') {
            w += [',', ';', ':'][rnd.nextInt(3)];
          }
          buf.add(w);
        }
        final s = '${buf.join(' ')}.';
        final units = splitLongUnit(s);
        expect(units.join(' '), s, reason: s);
        if (count > 22) {
          for (final u in units) {
            expect(words(u), lessThanOrEqualTo(22), reason: s);
          }
        }
      }
    });
  });
}
