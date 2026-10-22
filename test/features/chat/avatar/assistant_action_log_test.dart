import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit/features/chat/avatar/assistant_action_log.dart';
import 'package:conduit/platform/flutter_key_value_store.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _at = DateTime.now().subtract(const Duration(hours: 1));

const _twoCalls = '''
<details type="tool_calls" done="true" id="call_1" name="web_search" arguments="{&quot;query&quot;: &quot;cafe&quot;}" result="&quot;Found a cafe&quot;">
<summary>Tool Executed</summary>
</details>
<details type="tool_calls" done="true" id="call_2" name="create_event" arguments="{&quot;title&quot;: &quot;Lunch at a cafe&quot;}" result="&quot;Error: calendar offline&quot;">
<summary>Tool Executed</summary>
</details>
Done.
''';

ChatMessage _assistant(
  String id,
  String content, {
  bool streaming = false,
  DateTime? at,
}) => ChatMessage(
  id: id,
  role: 'assistant',
  content: content,
  timestamp: at ?? _at,
  isStreaming: streaming,
);

ChatMessage _user(String id, String content) =>
    ChatMessage(id: id, role: 'user', content: content, timestamp: _at);

AssistantActionRecord _record(
  String id, {
  DateTime? finishedAt,
  bool failed = false,
  String result = 'ok',
}) => AssistantActionRecord(
  id: id,
  chatId: 'chat',
  messageId: 'm',
  toolName: 'web_search',
  arguments: '{}',
  result: result,
  status: failed
      ? AssistantActionStatus.failed
      : AssistantActionStatus.succeeded,
  startedAt: finishedAt ?? _at,
  finishedAt: finishedAt ?? _at,
);

void main() {
  group('extractToolCallRecords', () {
    test('reads both calls of a reply and marks the failed one', () {
      final records = extractToolCallRecords(
        chatId: 'chat',
        messageId: 'm1',
        content: _twoCalls,
        messageTime: _at,
      );

      check(records.map((r) => r.id).toList()).deepEquals(['call_1', 'call_2']);
      check(records.map((r) => r.toolName).toList())
          .deepEquals(['web_search', 'create_event']);
      check(records[0].status).equals(AssistantActionStatus.succeeded);
      check(records[1].status).equals(AssistantActionStatus.failed);
      check(records[0].arguments).contains('cafe');
      check(records[1].result).contains('calendar offline');
      check(records[0].startedAt).equals(_at);
      check(records[0].finishedAt).equals(_at);
    });

    test('uses the time the call was seen running as its start', () {
      final started = _at.subtract(const Duration(seconds: 5));
      final records = extractToolCallRecords(
        chatId: 'chat',
        messageId: 'm1',
        content: _twoCalls,
        messageTime: _at,
        startedAtByCall: {'m1|call_1': started},
      );

      check(records[0].startedAt).equals(started);
      check(records[1].startedAt).equals(_at);
    });

    test('leaves out a call that is still running', () {
      const running = '''
<details type="tool_calls" done="false" id="call_9" name="web_search">
<summary>Executing...</summary>
</details>
''';
      check(
        extractToolCallRecords(
          chatId: 'chat',
          messageId: 'm1',
          content: running,
          messageTime: _at,
        ),
      ).isEmpty();
    });

    test('gives a call without an id the same fallback id every time', () {
      const noId = '''
<details type="tool_calls" done="true" name="web_search" result="&quot;ok&quot;">
<summary>Tool Executed</summary>
</details>
''';
      String idOf() => extractToolCallRecords(
        chatId: 'chat',
        messageId: 'm1',
        content: noId,
        messageTime: _at,
      ).single.id;

      check(idOf()).isNotEmpty();
      check(idOf()).equals(idOf());
    });

    test('a reply with no tool calls has no records', () {
      check(
        extractToolCallRecords(
          chatId: 'chat',
          messageId: 'm1',
          content: 'Just text',
          messageTime: _at,
        ),
      ).isEmpty();
    });
  });

  group('toolResultPreview', () {
    String preview(String result) =>
        toolResultPreview(_record('p', result: result));

    test('previews the first part of a content array', () {
      final parts = jsonEncode([
        {'type': 'input_text', 'text': 'Created the event\nsecond line'},
        {'type': 'input_text', 'text': 'ignored'},
      ]);
      check(preview(parts)).equals('Created the event');
    });

    test('previews a map with a content list', () {
      final result = jsonEncode({
        'content': [
          {'type': 'text', 'text': '  Found 3 results  '},
        ],
      });
      check(preview(result)).equals('Found 3 results');
    });

    test('prefers message, then error, then status in an object', () {
      check(preview('{"status": "ok", "message": "Done"}')).equals('Done');
      check(preview('{"status": "failed", "error": "No access"}'))
          .equals('No access');
      check(preview('{"status": "queued"}')).equals('queued');
    });

    test('keeps the first line of plain text and of unknown JSON', () {
      check(preview('Found a cafe\nmore')).equals('Found a cafe');
      check(preview('{"count": 2}')).equals('{"count": 2}');
      check(preview('[1, 2]')).equals('[1, 2]');
    });

    test('trims a long preview with an ellipsis', () {
      final text = 'x' * 200;
      check(toolResultPreview(_record('p', result: text), maxLength: 20))
          .equals('${'x' * 19}…');
    });
  });

  group('capAssistantActionRecords', () {
    test('keeps the newest 500 and drops what is over 30 days old', () {
      final now = DateTime(2024, 3, 1);
      final records = [
        for (var i = 0; i < 520; i++)
          _record('r$i', finishedAt: now.subtract(Duration(minutes: i))),
        _record('old', finishedAt: now.subtract(const Duration(days: 31))),
      ];

      final capped = capAssistantActionRecords(records, now: now);

      check(capped.length).equals(kAssistantActionLogMaxRecords);
      check(capped.first.id).equals('r0');
      check(capped.map((r) => r.id)).not((it) => it.contains('old'));
      check(capped.map((r) => r.id)).not((it) => it.contains('r519'));
    });
  });

  group('turnMessageIds', () {
    test('a read-back, a quick reply and a receipt are one turn', () {
      final messages = [
        _user('u0', 'Earlier question'),
        _assistant('a0', 'Earlier answer'),
        _user('u1', 'Add lunch tomorrow'),
        _assistant('a1', 'Add "Lunch at a cafe" tomorrow?'),
        _user('q1', 'Yes, do it.'),
        _assistant('a2', 'Added.'),
      ];

      check(turnMessageIds(messages, 'a2')).deepEquals({'a2', 'a1'});
      check(turnMessageIds(messages, 'a1')).deepEquals({'a1'});
      check(turnMessageIds(messages, 'a0')).deepEquals({'a0'});
    });

    test('several assistant messages in a row stay together', () {
      final messages = [
        _user('u1', 'Compare'),
        _assistant('a1', 'One'),
        _assistant('a2', 'Two'),
      ];

      check(turnMessageIds(messages, 'a2')).deepEquals({'a1', 'a2'});
    });
  });

  group('AssistantActionLog', () {
    late ProviderContainer container;

    Future<ProviderContainer> open() async {
      final created = ProviderContainer();
      addTearDown(created.dispose);
      return created;
    }

    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      PreferencesStore.debugOverride(await FlutterKeyValueStore.load());
      container = await open();
    });

    tearDown(PreferencesStore.debugReset);

    AssistantActionLog log() =>
        container.read(assistantActionLogProvider.notifier);
    AssistantActionLogState state() =>
        container.read(assistantActionLogProvider);

    test('records a reply once and finds it again after a reload', () async {
      final messages = [_user('u', 'hi'), _assistant('m1', _twoCalls)];

      await log().scanMessages('chat', messages);
      await log().scanMessages('chat', messages);
      check(state().records.length).equals(2);

      // A new session reads the stored log, then the same chat loads again.
      final reopened = ProviderContainer();
      addTearDown(reopened.dispose);
      check(reopened.read(assistantActionLogProvider).records.length).equals(2);
      await reopened
          .read(assistantActionLogProvider.notifier)
          .scanMessages('chat', messages);
      check(reopened.read(assistantActionLogProvider).records.length).equals(2);
    });

    test('does not read a reply that is still streaming', () async {
      await log().scanMessages('chat', [
        _assistant('m1', _twoCalls, streaming: true),
      ]);

      check(state().records).isEmpty();
    });

    test('counts failures recorded after the last look as unseen', () async {
      // Loaded history is older than the first look, so it is not news.
      await log().scanMessages('chat', [
        _assistant(
          'old',
          _twoCalls,
          at: DateTime.now().subtract(const Duration(days: 2)),
        ),
      ]);
      check(state().unseenFailures).equals(0);

      await log().scanMessages('chat', [
        _assistant('m2', _twoCalls.replaceAll('call_', 'next_')),
      ], finishedAt: DateTime.now());
      check(state().unseenFailures).equals(1);

      await Future<void>.delayed(const Duration(milliseconds: 5));
      await log().markFailuresSeen();
      check(state().unseenFailures).equals(0);
    });

    test('clear empties the log', () async {
      await log().scanMessages('chat', [_assistant('m1', _twoCalls)]);
      check(state().records).isNotEmpty();

      await log().clear();
      check(state().records).isEmpty();
      check(container.read(assistantActionLogProvider).unseenFailures)
          .equals(0);
    });

    test('forMessages limits records to a chat and its messages', () async {
      await log().scanMessages('chat', [
        _assistant('m1', _twoCalls),
        _assistant('m2', _twoCalls.replaceAll('call_', 'other_')),
      ]);

      check(state().forMessages('chat', {'m1'}).length).equals(2);
      check(state().forMessages('elsewhere', {'m1'})).isEmpty();
    });
  });
}
