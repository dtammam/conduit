import 'package:conduit/platform/ask_musey.dart';
import 'package:conduit_core/models/openwebui_chat_prompt.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakePorts implements AskMuseyPorts {
  _FakePorts({this.problem, List<AskMuseyTurn?>? turns, this.sendHangs = false})
    : _turns = turns ?? [];

  final String? problem;
  final bool sendHangs;
  final List<AskMuseyTurn?> _turns;
  final List<String> sent = [];
  int snapshots = 0;

  @override
  Future<String?> prepare() async => problem;

  @override
  Future<void> send(String question) async {
    if (sendHangs) await Future<void>.delayed(const Duration(hours: 1));
    sent.add(question);
  }

  @override
  AskMuseyTurn? snapshot() {
    final i = snapshots++;
    if (_turns.isEmpty) return null;
    return _turns[i < _turns.length ? i : _turns.length - 1];
  }
}

/// A clock that moves only when the runner waits.
class _Clock {
  DateTime t = DateTime(2026, 11, 7, 12);
  DateTime now() => t;
  Future<void> delay(Duration d) async => t = t.add(d);
}

Future<AskMuseyOutcome> _run(
  _FakePorts ports, {
  String q = 'what is on today',
  Duration deadline = const Duration(seconds: 20),
}) {
  final clock = _Clock();
  return runAskMuseyTurn(
    ports: ports,
    question: q,
    deadline: deadline,
    now: clock.now,
    delay: clock.delay,
  );
}

void main() {
  group('runAskMuseyTurn', () {
    test('speaks the finished reply and sent the question once', () async {
      final ports = _FakePorts(
        turns: const [
          null,
          AskMuseyTurn(content: 'Two thi', streaming: true),
          AskMuseyTurn(content: 'Two things today.', streaming: false),
        ],
      );
      final out = await _run(ports);
      expect(
        out,
        const AskMuseyOutcome(AskMuseyStatus.reply, 'Two things today.'),
      );
      expect(ports.sent, ['what is on today']);
    });

    test(
      'a card is spoken, never confirmed, and ends the wait at once',
      () async {
        final ports = _FakePorts(
          turns: const [
            AskMuseyTurn(streaming: true),
            AskMuseyTurn(
              streaming: true,
              cardLine: 'Log 12 dollars for lunch?',
            ),
          ],
        );
        final out = await _run(ports);
        expect(out.status, AskMuseyStatus.card);
        expect(out.spoken, 'Log 12 dollars for lunch?');
        expect(ports.snapshots, 2);
      },
    );

    test('still streaming at the deadline says it is in Musey', () async {
      final ports = _FakePorts(
        turns: const [AskMuseyTurn(content: 'Well', streaming: true)],
      );
      final out = await _run(ports, deadline: const Duration(seconds: 5));
      expect(
        out,
        const AskMuseyOutcome(AskMuseyStatus.slow, kAskMuseySlowLine),
      );
      expect(kAskMuseySlowLine, "Bobby is still thinking, it's in Musey.");
      expect(ports.sent, hasLength(1));
    });

    test('a failed reply is an error that points at Musey', () async {
      final out = await _run(
        _FakePorts(turns: const [AskMuseyTurn(streaming: false, failed: true)]),
      );
      expect(out.status, AskMuseyStatus.error);
      expect(out.spoken, contains('Musey'));
    });

    test('prepare problem is spoken and nothing is sent', () async {
      final ports = _FakePorts(problem: 'Musey is signed out.');
      final out = await _run(ports);
      expect(
        out,
        const AskMuseyOutcome(AskMuseyStatus.error, 'Musey is signed out.'),
      );
      expect(ports.sent, isEmpty);
    });

    test('an empty question is not sent', () async {
      final ports = _FakePorts();
      final out = await _run(ports, q: '   ');
      expect(out.status, AskMuseyStatus.error);
      expect(ports.sent, isEmpty);
    });

    test(
      'a send that never lands before the deadline is not "in Musey"',
      () async {
        final out = await runAskMuseyTurn(
          ports: _FakePorts(sendHangs: true),
          question: 'hi',
          deadline: const Duration(milliseconds: 20),
        );
        expect(out.status, AskMuseyStatus.error);
        expect(out.spoken, isNot(contains("it's in Musey")));
      },
    );
  });

  group('museySpeakable', () {
    test('drops markdown, links, code and urls', () {
      const md =
          '## Today\n- **Dentist** at [3pm](https://x.example/a)\n'
          '```\ncode\n```\nSee https://x.example/b now.';
      expect(museySpeakable(md), 'Today Dentist at 3pm See now.');
    });

    test('short text is untouched', () {
      expect(museySpeakable('Done.'), 'Done.');
    });

    test('long text is cut at a sentence end with a pointer to Musey', () {
      final text = List.filled(40, 'This is a sentence.').join(' ');
      final out = museySpeakable(text, limit: 100);
      expect(out, endsWith(' The rest is in Musey.'));
      expect(out.length, lessThan(140));
      expect(out, contains('This is a sentence. This'));
    });
  });

  group('museyCardLine', () {
    test('uses the first question, then the message, then a fallback', () {
      const withQuestion = OpenWebUiComposerPrompt(
        identity: 'a',
        kind: OpenWebUiComposerPromptKind.askUser,
        questions: [
          OpenWebUiPromptQuestion(
            id: 'q',
            header: 'h',
            question: 'Add **milk** to the list?',
            options: [],
            allowOther: false,
          ),
        ],
      );
      expect(museyCardLine(withQuestion), 'Add milk to the list?');
      const withMessage = OpenWebUiComposerPrompt(
        identity: 'b',
        kind: OpenWebUiComposerPromptKind.confirmation,
        message: 'Create the event?',
      );
      expect(museyCardLine(withMessage), 'Create the event?');
      const empty = OpenWebUiComposerPrompt(
        identity: 'c',
        kind: OpenWebUiComposerPromptKind.confirmation,
      );
      expect(museyCardLine(empty), 'Bobby has a card for you.');
    });
  });
}
