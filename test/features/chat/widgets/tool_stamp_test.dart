import 'package:conduit/features/chat/widgets/tool_stamp.dart';
import 'package:conduit/features/chat/avatar/assistant_action_log.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

String _call(String name, String result, {String id = 'c'}) =>
    '<details type="tool_calls" done="true" id="$id" name="$name" '
    'arguments="{}" result="$result">\n<summary>Tool Executed</summary>\n'
    '</details>\n';

List<String> _labels(String content) => toolStampFromContent(
  messageId: 'm1',
  content: content,
).map((e) => e.label).toList();

void main() {
  group('toolStampName', () {
    test('drops the mcp server prefix and underscores', () {
      expect(toolStampName('calendar-mcp_event_create'), 'event create');
      expect(
        toolStampName('actual-mcp_actual_transactions_create'),
        'transactions create',
      );
      expect(toolStampName('actual_accounts_list'), 'accounts list');
      expect(toolStampName('search_notes'), 'search notes');
    });
  });

  group('toolStampFromContent', () {
    test('lists calls with check marks and marks failures', () {
      final content =
          '${_call('calendar-mcp_event_list', '&quot;ok&quot;', id: 'a')}'
          '${_call('calendar-mcp_event_create', '&quot;Error: offline&quot;', id: 'b')}'
          'Done.';
      expect(_labels(content), ['event list ✓', 'event create ✗']);
    });

    test('json error, isError and success false count as failed', () {
      final content =
          '${_call('t_one', '{&quot;error&quot;: &quot;boom&quot;}', id: 'a')}'
          '${_call('t_two', '{&quot;isError&quot;: true}', id: 'b')}'
          '${_call('t_three', '{&quot;success&quot;: false}', id: 'c')}';
      expect(_labels(content), ['t one ✗', 't two ✗', 't three ✗']);
    });

    test('hides plumbing calls and merges repeats', () {
      final content =
          '${_call('ask_user', '&quot;x&quot;', id: 'a')}'
          '${_call('get_current_timestamp', '&quot;x&quot;', id: 'b')}'
          '${_call('calculate_timestamp', '&quot;x&quot;', id: 'c')}'
          '${_call('calendar-mcp_event_list', '&quot;x&quot;', id: 'd')}'
          '${_call('calendar-mcp_event_list', '&quot;x&quot;', id: 'e')}';
      expect(_labels(content), ['event list ✓ ×2']);
    });

    test('empty when nothing qualifies or text only', () {
      expect(_labels('Just words about tool_calls.'), isEmpty);
      expect(_labels(_call('ask_user', '&quot;x&quot;')), isEmpty);
    });

    test('a call still running is not stamped', () {
      const running =
          '<details type="tool_calls" done="false" id="r" name="web_search">\n'
          '<summary>Executing...</summary>\n</details>\n';
      expect(_labels(running), isEmpty);
    });
  });
  outputTests();
  summaryTests();
}

Map<String, dynamic> _fc(
  String id,
  String name, {
  String status = 'completed',
}) => {
  'type': 'function_call',
  'id': id,
  'call_id': id,
  'name': name,
  'arguments': '{}',
  'status': status,
};

Map<String, dynamic> _fco(String id, Object output) => {
  'type': 'function_call_output',
  'id': 'fco_$id',
  'call_id': id,
  'output': output,
};

void outputTests() {
  group('toolStampFromOutput', () {
    List<String> labels(List<Map<String, dynamic>> o) =>
        toolStampFromOutput(o).map((e) => e.label).toList();

    test('pairs calls with outputs by call_id and joins text parts', () {
      expect(
        labels([
          {'type': 'message', 'content': []},
          _fc('1', 'notes-mcp_search_notes'),
          _fc('2', 'actual-mcp_actual_transactions_create'),
          _fco('2', [
            {'type': 'input_text', 'text': '{"ok": true}'},
          ]),
          _fco('1', '{"results": []}'),
        ]),
        ['search notes ✓', 'transactions create ✓'],
      );
    });

    test('error results give a cross', () {
      expect(
        labels([
          _fc('1', 'a_b'),
          _fco('1', [
            {'type': 'input_text', 'text': 'Error: nope'},
          ]),
          _fc('2', 'c_d'),
          _fco('2', '{"error": "bad"}'),
          _fc('3', 'e_f'),
          _fco('3', '{"success": false}'),
        ]),
        ['a b ✗', 'c d ✗', 'e f ✗'],
      );
    });

    test('a call with no output or not completed is left out', () {
      expect(
        labels([
          _fc('1', 'a_b'),
          _fc('2', 'c_d', status: 'in_progress'),
          _fco('2', 'x'),
          _fc('3', 'ask_user'),
          _fco('3', 'x'),
        ]),
        isEmpty,
      );
    });

    test('repeats merge and null output is empty', () {
      expect(
        labels([
          _fc('1', 'a_b'),
          _fco('1', 'x'),
          _fc('2', 'a_b'),
          _fco('2', 'y'),
        ]),
        ['a b ✓ ×2'],
      );
      expect(toolStampFromOutput(null), isEmpty);
    });
  });
}

AssistantActionRecord _rec(String name, {bool failed = false}) =>
    AssistantActionRecord(
      id: name,
      chatId: '',
      messageId: '',
      toolName: name,
      arguments: '',
      result: '',
      status: failed
          ? AssistantActionStatus.failed
          : AssistantActionStatus.succeeded,
      startedAt: DateTime.fromMillisecondsSinceEpoch(0),
      finishedAt: DateTime.fromMillisecondsSinceEpoch(0),
    );

List<String> _sum(List<AssistantActionRecord> r) =>
    buildToolSummary(r).map((s) => s.text).toList();

void summaryTests() {
  group('toolSystem', () {
    test('maps prefixes and named tools', () {
      expect(toolSystem('actual-mcp_actual_accounts_list'), 'budget');
      expect(toolSystem('calendar-mcp_event_list'), 'calendar');
      expect(toolSystem('notes-mcp_search_notes'), 'notes');
      expect(toolSystem('schedule-mcp_schedule_list'), 'routines');
      expect(toolSystem('search_web'), 'web');
      expect(toolSystem('fetch_url'), 'web');
      expect(toolSystem('weather_forecast'), 'weather');
      expect(toolSystem('generate_image'), 'image');
      expect(toolSystem('some_other_tool'), 'some other tool');
    });
  });

  group('buildToolSummary', () {
    test('reads are deduped per system and joined', () {
      expect(
        _sum([
          _rec('calendar-mcp_event_list'),
          _rec('calendar-mcp_event_get'),
          _rec('actual-mcp_actual_accounts_list'),
        ]),
        ['Checked calendar, budget'],
      );
    });

    test('write rule decides write vs read', () {
      expect(
        kToolWriteRule.hasMatch('actual-mcp_actual_transactions_create'),
        isTrue,
      );
      expect(kToolWriteRule.hasMatch('calendar-mcp_event_delete'), isTrue);
      expect(kToolWriteRule.hasMatch('notes-mcp_update_note'), isTrue);
      expect(kToolWriteRule.hasMatch('notes-mcp_manage_tags'), isTrue);
      expect(kToolWriteRule.hasMatch('schedule-mcp_schedule_update'), isTrue);
      expect(kToolWriteRule.hasMatch('notes-mcp_search_notes'), isFalse);
      expect(kToolWriteRule.hasMatch('calendar-mcp_event_list'), isFalse);
    });

    test('a booking reads then saves, writes count with x N', () {
      expect(
        _sum([
          _rec('calendar-mcp_event_list'),
          _rec('calendar-mcp_event_create'),
        ]),
        ['Checked calendar', 'Saved to calendar'],
      );
      expect(
        _sum([
          _rec('calendar-mcp_event_create'),
          _rec('calendar-mcp_event_update'),
        ]),
        ['Saved to calendar ×2'],
      );
    });

    test('image tools say made an image', () {
      expect(_sum([_rec('generate_image')]), ['Made an image']);
    });

    test('failures replace the success of the same system and action', () {
      final summary = buildToolSummary([
        _rec('actual-mcp_actual_transactions_create'),
        _rec('actual-mcp_actual_transactions_create', failed: true),
        _rec('notes-mcp_search_notes', failed: true),
        _rec('notes-mcp_get_note'),
        _rec('calendar-mcp_event_list'),
      ]);
      expect(summary, [
        const ToolSummarySegment(ToolSummaryKind.read, 'Checked calendar'),
        const ToolSummarySegment(
          ToolSummaryKind.failedWrite,
          "Couldn't save to budget",
        ),
        const ToolSummarySegment(
          ToolSummaryKind.failedRead,
          "Couldn't check notes",
        ),
      ]);
    });

    test('skipped tools leave nothing', () {
      expect(
        _sum([
          _rec('ask_user'),
          _rec('get_current_timestamp'),
          _rec('calculate_timestamp'),
          _rec('view_skill'),
          _rec('read_skill_file'),
          _rec('grep_skill_files'),
          _rec('update_skill_files'),
          _rec('create_skill'),
        ]),
        isEmpty,
      );
    });
  });

  group('ToolStamp widget', () {
    testWidgets('tap expands the exact tool list', (tester) async {
      final data = ToolStampData.fromRecords([
        _rec('calendar-mcp_event_list'),
        _rec('calendar-mcp_event_create'),
      ]);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ToolStamp(data: data)),
        ),
      );
      expect(find.byKey(const ValueKey('tool-stamp-detail')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('tool-stamp')));
      await tester.pump();
      final detail = tester.widget<Text>(
        find.byKey(const ValueKey('tool-stamp-detail')),
      );
      expect(detail.data, 'event list ✓ · event create ✓');
      await tester.tap(find.byKey(const ValueKey('tool-stamp')));
      await tester.pump();
      expect(find.byKey(const ValueKey('tool-stamp-detail')), findsNothing);
    });
  });
}
