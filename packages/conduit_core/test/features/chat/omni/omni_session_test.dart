import 'package:checks/checks.dart';
import 'package:conduit_core/features/chat/omni/omni_session.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:test/test.dart';

final _t0 = DateTime.utc(2026, 10, 24, 7);

ChatMessage _m(String id, String role, int minute) => ChatMessage(
  id: id,
  role: role,
  content: id,
  timestamp: _t0.add(Duration(minutes: minute)),
);

const _gap = Duration(minutes: 15);

OmniSessionTurn _plan(
  OmniSessionState state,
  List<ChatMessage> messages, {
  bool mayStart = true,
  String chatId = 'omni',
}) => planOmniSessionTurn(
  state: state,
  chatId: chatId,
  messages: messages,
  idleGap: _gap,
  mayStartSession: mayStart,
);

void main() {
  group('planOmniSessionTurn', () {
    test('the first message ever starts a session', () {
      final turn = _plan(const OmniSessionState(), [_m('u1', 'user', 0)]);
      check(turn.turns).equals(1);
      check(turn.state.boundaries).deepEquals(['u1']);
      check(turn.state.chatId).equals('omni');
    });

    test('a quick follow-up stays in the session and counts its turns', () {
      final state = const OmniSessionState(chatId: 'omni', boundaries: ['u1']);
      final turn = _plan(state, [
        _m('u1', 'user', 0),
        _m('a1', 'assistant', 0),
        _m('u2', 'user', 3),
        _m('a2', 'assistant', 3),
        _m('u3', 'user', 5),
      ]);
      check(turn.turns).equals(3);
      check(turn.state).equals(state);
    });

    test('a gap of the idle time starts a session', () {
      final turn = _plan(
        const OmniSessionState(chatId: 'omni', boundaries: ['u1']),
        [_m('u1', 'user', 0), _m('a1', 'assistant', 1), _m('u2', 'user', 16)],
      );
      check(turn.turns).equals(1);
      check(turn.state.boundaries).deepEquals(['u1', 'u2']);
    });

    test('a pending fresh start makes the next message a session start', () {
      final turn = _plan(
        const OmniSessionState(
          chatId: 'omni',
          boundaries: ['u1'],
          pending: true,
        ),
        [_m('u1', 'user', 0), _m('a1', 'assistant', 0), _m('u2', 'user', 1)],
      );
      check(turn.turns).equals(1);
      check(turn.state.pending).isFalse();
      check(turn.state.boundaries).deepEquals(['u1', 'u2']);
    });

    test('an assistant placeholder after the message does not matter', () {
      final turn = _plan(
        const OmniSessionState(chatId: 'omni', boundaries: ['u1']),
        [
          _m('u1', 'user', 0),
          _m('a1', 'assistant', 0),
          _m('u2', 'user', 2),
          _m('a2', 'assistant', 2),
        ],
      );
      check(turn.turns).equals(2);
    });

    test('a regeneration never starts a session', () {
      final state = const OmniSessionState(
        chatId: 'omni',
        boundaries: ['u1'],
        pending: true,
      );
      final turn = _plan(state, [
        _m('u1', 'user', 0),
        _m('a1', 'assistant', 0),
        _m('u2', 'user', 40),
      ], mayStart: false);
      check(turn.turns).equals(2);
      check(turn.state).equals(state);
    });

    test('without a known session start no marker is sent', () {
      final turn = _plan(
        const OmniSessionState(chatId: 'omni', boundaries: ['gone']),
        [_m('u1', 'user', 0), _m('a1', 'assistant', 0), _m('u2', 'user', 1)],
        mayStart: false,
      );
      check(turn.turns).isNull();
    });

    test('boundaries of another chat do not apply', () {
      final turn = _plan(
        const OmniSessionState(chatId: 'old', boundaries: ['u1']),
        [_m('u1', 'user', 0), _m('a1', 'assistant', 0), _m('u2', 'user', 1)],
      );
      check(turn.state.chatId).equals('omni');
      check(turn.state.boundaries).deepEquals(['u2']);
      check(turn.turns).equals(1);
    });

    test('sending the same message again keeps one boundary', () {
      final first = _plan(const OmniSessionState(pending: true), [
        _m('u1', 'user', 0),
      ]);
      final again = _plan(first.state.copyWith(pending: true), [
        _m('u1', 'user', 0),
      ]);
      check(again.state.boundaries).deepEquals(['u1']);
      check(again.turns).equals(1);
    });

    test('state round-trips through JSON', () {
      const state = OmniSessionState(
        chatId: 'omni',
        boundaries: ['u1', 'u9'],
        pending: true,
      );
      check(OmniSessionState.fromJson(state.toJson())).equals(state);
      check(OmniSessionState.fromJson('nonsense'))
          .equals(const OmniSessionState());
    });
  });

  group('withOmniSessionMarker', () {
    test('adds its own system message when there is none', () {
      final out = withOmniSessionMarker(const [], 2);
      check(out).deepEquals([
        {'role': 'system', 'content': '[omni-session turns=2]'},
      ]);
    });

    test('appends on a new line to the first system message', () {
      final input = [
        {'role': 'system', 'content': 'Be brief.'},
      ];
      final out = withOmniSessionMarker(input, 3);
      check(out.single['content']).equals('Be brief.\n[omni-session turns=3]');
      check(input.single['content']).equals('Be brief.');
    });

    test('adds a text part to list content', () {
      final out = withOmniSessionMarker([
        {
          'role': 'system',
          'content': [
            {'type': 'text', 'text': 'Be brief.'},
          ],
        },
      ], 1);
      check(out.single['content'] as List).length.equals(2);
      check(((out.single['content'] as List).last as Map)['text'])
          .equals('\n[omni-session turns=1]');
    });
  });
}
