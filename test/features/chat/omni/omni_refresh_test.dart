import 'package:checks/checks.dart';
import 'package:conduit/features/chat/omni/omni_refresh.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _event(String chatId, String type) => {
  'chat_id': chatId,
  'message_id': 'm1',
  'data': {'type': type, 'data': <String, dynamic>{}},
};

void main() {
  group('isOmniPostEvent', () {
    test('a message posted into the Omni chat counts', () {
      check(isOmniPostEvent(_event('omni', 'chat:message'), 'omni')).isTrue();
    });

    test('streaming frames of the app\'s own reply do not', () {
      check(isOmniPostEvent(_event('omni', 'chat:completion'), 'omni'))
          .isFalse();
    });

    test('another chat does not', () {
      check(isOmniPostEvent(_event('other', 'chat:message'), 'omni')).isFalse();
    });

    test('without a known Omni chat nothing counts', () {
      check(isOmniPostEvent(_event('omni', 'chat:message'), null)).isFalse();
      check(isOmniPostEvent(_event('omni', 'chat:message'), '')).isFalse();
    });

    test('a malformed envelope does not throw', () {
      check(isOmniPostEvent({'chat_id': 'omni'}, 'omni')).isFalse();
      check(isOmniPostEvent({'chat_id': 'omni', 'data': 'text'}, 'omni'))
          .isFalse();
    });
  });
}
