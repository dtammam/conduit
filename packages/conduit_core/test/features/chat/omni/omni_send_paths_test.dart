import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/chat/omni/omni_session.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:test/test.dart';

final _t0 = DateTime.utc(2026, 10, 28, 8);

ChatMessage _m(String id, String role, int minute) => ChatMessage(
  id: id,
  role: role,
  content: id,
  timestamp: _t0.add(Duration(minutes: minute)),
);

/// The files whose completion requests carry the Omni session marker.
const _requestFiles = <String>[
  'lib/features/chat/providers/chat_send_message.dart',
  'lib/features/chat/providers/chat_regeneration.dart',
  'lib/features/chat/providers/chat_headless_completion.dart',
  'lib/features/chat/providers/chat_comparison_controller.dart',
];

int _count(String source, Pattern pattern) => pattern.allMatches(source).length;

void main() {
  group('a reply to a routine post', () {
    test('after a long gap starts a session of one turn', () {
      final messages = [
        _m('u1', 'user', 0),
        _m('a1', 'assistant', 1),
        // The routine's reply, posted by the server hours later.
        _m('post', 'assistant', 240),
        _m('u2', 'user', 245),
      ];
      final state = const OmniSessionState(chatId: 'omni', boundaries: ['u1']);
      final turn = planOmniSessionTurn(
        state: state,
        chatId: 'omni',
        messages: messages,
        idleGap: const Duration(minutes: 30),
        mayStartSession: true,
      );
      check(turn.turns).equals(1);
      check(turn.state.boundaries).deepEquals(['u1', 'u2']);
    });

    test('inside the idle gap stays in the running session', () {
      final messages = [
        _m('u1', 'user', 0),
        _m('a1', 'assistant', 1),
        _m('post', 'assistant', 10),
        _m('u2', 'user', 12),
      ];
      final turn = planOmniSessionTurn(
        state: const OmniSessionState(chatId: 'omni', boundaries: ['u1']),
        chatId: 'omni',
        messages: messages,
        idleGap: const Duration(minutes: 30),
        mayStartSession: true,
      );
      check(turn.turns).equals(2);
    });
  });

  group('send paths', () {
    // Every request the app itself makes for a chat goes through
    // `_withOmniSession`. One resume is not the app's request: answering an
    // ask-user card calls the server's resolve route, and the server then
    // continues the paused turn itself, so the app has no request to mark.
    // This guards the paths the app does own: a new request site added
    // without the marker fails here.
    for (final path in _requestFiles) {
      test('$path marks every completion request', () {
        final source = File(path).readAsStringSync();
        final requests = _count(source, RegExp(r'\.sendMessageSession\('));
        final marked = _count(source, RegExp(r'(?<![\w])_withOmniSession\('));
        check(requests).isGreaterThan(0);
        check(marked).isGreaterOrEqual(requests);
      });
    }
  });
}
