import 'dart:convert';

import 'package:conduit/features/chat/widgets/tool_stamp.dart';
import 'package:conduit/features/chat/avatar/assistant_action_log.dart';
import 'package:conduit/features/chat/musey/musey_feed_views.dart'
    show MuseyImage;
import 'package:conduit/features/chat/widgets/web_sources.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:flutter/material.dart';
import 'package:material_ui/material_ui.dart' as mui;
import 'package:flutter_riverpod/flutter_riverpod.dart';
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

  group('web sources', () {
    AssistantActionRecord web(
      String name,
      String result, {
      String args = '',
      bool failed = false,
    }) => AssistantActionRecord(
      id: '$name${result.hashCode}${args.hashCode}',
      chatId: '',
      messageId: '',
      toolName: name,
      arguments: args,
      result: result,
      status: failed
          ? AssistantActionStatus.failed
          : AssistantActionStatus.succeeded,
      startedAt: DateTime.fromMillisecondsSinceEpoch(0),
      finishedAt: DateTime.fromMillisecondsSinceEpoch(0),
    );

    const search =
        '[{"title":"DDR Community","link":"https://www.ddrcommunity.com/a?x=1",'
        '"snippet":"Rhythm game news"},{"title":"Dupe","link":"https://www.ddrcommunity.com/a?x=1","snippet":"s"},'
        '{"title":"Odd","link":"javascript:alert(1)","snippet":"s"},'
        '{"title":"File","link":"file:///etc/passwd","snippet":"s"},'
        '{"title":"Other","link":"http://example.org/p","snippet":"Other snippet"}]';
    const q1 = '{"query":"ddr machines near me"}';

    test('search_web gives title, link, snippet and the call query', () {
      final s = webSourcesFromRecords([web('search_web', search, args: q1)]);
      expect(s.map((e) => e.url), [
        'https://www.ddrcommunity.com/a?x=1',
        'http://example.org/p',
      ]);
      expect(s.first.title, 'DDR Community');
      expect(s.first.snippet, 'Rhythm game news');
      expect(s.first.query, 'ddr machines near me');
      expect(s.first.domain, 'ddrcommunity.com');
      expect(s.first.opened, isFalse);
    });

    test('a URL keeps the first query that returned it', () {
      final s = webSourcesFromRecords([
        web('search_web', search, args: q1),
        web('search_web', search, args: '{"query":"second"}'),
      ]);
      expect(s.length, 2);
      expect(s.first.query, 'ddr machines near me');
    });

    test('pages opened with fetch_url come first and are marked', () {
      final s = webSourcesFromRecords([
        web('search_web', search, args: q1),
        web('fetch_url', '{"url":"https://news.site/story","content":"x"}'),
        web('fetch_url', '', args: '{"url":"https://args.site/p"}'),
        web(
          'search_web',
          search.replaceAll('example.org', 'bad.org'),
          failed: true,
        ),
      ]);
      expect(s.map((e) => e.domain).toList(), [
        'news.site',
        'args.site',
        'ddrcommunity.com',
        'example.org',
      ]);
      expect(s.take(2).every((e) => e.opened), isTrue);
      expect(s.skip(2).any((e) => e.opened), isFalse);
    });

    test(
      'a page both found and opened keeps its query and is marked opened',
      () {
        final s = webSourcesFromRecords([
          web('search_web', search, args: q1),
          web('fetch_url', '', args: '{"url":"http://example.org/p"}'),
        ]);
        expect(s.first.url, 'http://example.org/p');
        expect(s.first.opened, isTrue);
        expect(s.first.query, 'ddr machines near me');
        expect(s.first.snippet, 'Other snippet');
        expect(s.length, 2);
      },
    );

    test('no cap on the list', () {
      final many = [
        for (var i = 0; i < 12; i++)
          {'title': 't$i', 'link': 'https://s$i.com/'},
      ];
      expect(
        webSourcesFromRecords([web('search_web', jsonEncode(many))]).length,
        12,
      );
    });

    test('a clipped result still yields its whole entries', () {
      const clipped =
          '[{"title":"One","link":"https://one.com/","snippet":"aaa"},'
          '{"title":"Two","link":"https://two.com/","snippet":"bb';
      expect(
        webSourcesFromRecords([web('search_web', clipped)])
            .map((e) => e.domain),
        ['one.com', 'two.com'],
      );
    });

    test('content parts wrapping the JSON text are read', () {
      final wrapped = jsonEncode([
        {'type': 'text', 'text': search},
      ]);
      expect(webSourcesFromRecords([web('search_web', wrapped)]).length, 2);
    });

    test('text the model wrote is never a source; no web step shows none', () {
      expect(
        webSourcesFromRecords([web('calendar-mcp_event_list', search)]),
        isEmpty,
      );
      final fromContent = toolRecordsFromContent(
        messageId: 'm',
        content: 'See https://evil.example/x for more.',
      );
      expect(webSourcesFromRecords(fromContent), isEmpty);
    });

    test('read from a stored output array (an old chat reopened)', () {
      final records = toolRecordsFromOutput([
        {
          'type': 'function_call',
          'call_id': 'a',
          'name': 'search_web',
          'status': 'completed',
          'arguments': '{"query":"ddr"}',
        },
        {'type': 'function_call_output', 'call_id': 'a', 'output': search},
      ]);
      final s = webSourcesFromRecords(records);
      expect(s.length, 2);
      expect(s.first.query, 'ddr');
      expect(ToolStampData.fromRecords(records).sources.length, 2);
    });
  });

  group('web sources control and sheet', () {
    List<WebSource> five() => [
      const WebSource(
        url: 'https://a.com/1',
        title: 'Alpha page',
        snippet: 'Alpha snippet',
        query: 'alpha query',
        opened: true,
      ),
      const WebSource(url: 'https://b.com/1', title: 'Beta', query: 'q2'),
      const WebSource(url: 'https://c.com/1', title: 'Gamma'),
      const WebSource(url: 'https://d.com/1', title: 'Delta'),
      const WebSource(url: 'https://e.com/1', title: 'Epsilon'),
      const WebSource(url: 'https://f.com/1', title: 'Zeta'),
    ];

    Future<void> mount(
      WidgetTester tester,
      Widget child, {
      double width = 320,
    }) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          child: mui.MaterialApp(
            localizationsDelegates: conduitLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: Align(alignment: Alignment.topLeft, child: child),
            ),
          ),
        ),
      );
    }

    testWidgets('one short line: Sources, four icons, +N; no scroll', (
      tester,
    ) async {
      await mount(tester, WebSourcesControl(sources: five()));
      final control = find.byKey(const ValueKey('web-sources-control'));
      expect(find.text('Sources'), findsOneWidget);
      expect(find.byType(SourceFavicon), findsNWidgets(kSourceIconLimit));
      expect(find.text('+2'), findsOneWidget);
      expect(find.byType(ListView), findsNothing);
      expect(find.byType(SingleChildScrollView), findsNothing);
      final size = tester.getSize(control);
      expect(size.height, 22);
      expect(size.width, lessThan(200));
    });

    testWidgets('few sources: no +N; none: nothing', (tester) async {
      await mount(tester, WebSourcesControl(sources: five().take(2).toList()));
      expect(find.byType(SourceFavicon), findsNWidgets(2));
      expect(find.byKey(const ValueKey('web-sources-more')), findsNothing);
      await mount(tester, const WebSourcesControl(sources: []));
      expect(find.byKey(const ValueKey('web-sources-control')), findsNothing);
    });

    testWidgets('tap opens a sheet listing every source, opened first', (
      tester,
    ) async {
      await mount(tester, WebSourcesControl(sources: five()));
      await tester.tap(find.byKey(const ValueKey('web-sources-control')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('web-sources-title')), findsOneWidget);
      for (final t in [
        'Alpha page',
        'Beta',
        'Gamma',
        'Delta',
        'Epsilon',
        'Zeta',
      ]) {
        expect(find.text(t), findsOneWidget);
      }
      expect(find.text('a.com'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('web-source-opened-https://a.com/1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('web-source-opened-https://b.com/1')),
        findsNothing,
      );
      expect(
        tester.getTopLeft(find.text('Alpha page')).dy,
        lessThan(tester.getTopLeft(find.text('Beta')).dy),
      );
    });

    testWidgets(
      'a row tap expands it with query, snippet and Open page; second tap collapses',
      (tester) async {
        final opened = <String>[];
        await mount(
          tester,
          WebSourcesControl(sources: five(), onOpen: opened.add),
        );
        await tester.tap(find.byKey(const ValueKey('web-sources-control')));
        await tester.pumpAndSettle();
        final row = find.byKey(
          const ValueKey('web-source-row-https://a.com/1'),
        );
        expect(find.text('Searched: alpha query'), findsNothing);
        await tester.tap(row);
        await tester.pumpAndSettle();
        // A row tap never jumps to the browser.
        expect(opened, isEmpty);
        expect(find.text('Searched: alpha query'), findsOneWidget);
        expect(find.text('Alpha snippet'), findsOneWidget);
        expect(find.text('Open page'), findsOneWidget);
        await tester.tap(find.text('Open page'));
        expect(opened, ['https://a.com/1']);
        await tester.tap(row);
        await tester.pumpAndSettle();
        expect(find.text('Searched: alpha query'), findsNothing);
        expect(find.text('Open page'), findsNothing);
      },
    );

    testWidgets('a row with no query or snippet still offers Open page', (
      tester,
    ) async {
      final opened = <String>[];
      await mount(
        tester,
        WebSourcesControl(sources: five(), onOpen: opened.add),
      );
      await tester.tap(find.byKey(const ValueKey('web-sources-control')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('web-source-row-https://c.com/1')),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Searched:'), findsNothing);
      await tester.tap(find.text('Open page'));
      expect(opened, ['https://c.com/1']);
    });

    testWidgets('favicons come from the relay path, with a letter fallback', (
      tester,
    ) async {
      await mount(tester, const SourceFavicon(domain: 'ddrcommunity.com'));
      final img = tester.widget<MuseyImage>(
        find.byKey(const ValueKey('source-icon-ddrcommunity.com')),
      );
      expect(img.src, '/musey/favicon?domain=ddrcommunity.com');
      expect(img.src, isNot(contains('google')));
      await tester.pump();
      // No relay in the test: the letter shows, no broken image, no throw.
      expect(find.text('D'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await mount(tester, const SourceFavicon(domain: ''));
      expect(find.text('?'), findsOneWidget);
    });

    testWidgets('the stamp carries the control, not scrolling pills', (
      tester,
    ) async {
      final data = ToolStampData(const [], const [], five());
      expect(data.sources.length, 6);
      final records = [
        AssistantActionRecord(
          id: 'x',
          chatId: '',
          messageId: '',
          toolName: 'search_web',
          arguments: '{"query":"x"}',
          result: '[{"title":"T","link":"https://t.com/","snippet":"s"}]',
          status: AssistantActionStatus.succeeded,
          startedAt: DateTime.fromMillisecondsSinceEpoch(0),
          finishedAt: DateTime.fromMillisecondsSinceEpoch(0),
        ),
      ];
      await mount(tester, ToolStamp(data: ToolStampData.fromRecords(records)));
      expect(find.byKey(const ValueKey('web-sources-control')), findsOneWidget);
      expect(find.byKey(const ValueKey('web-source-pills')), findsNothing);
    });
  });
}
