import 'package:conduit/features/chat/widgets/tool_stamp.dart';
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
}
