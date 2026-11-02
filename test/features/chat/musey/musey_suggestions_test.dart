import 'package:conduit/features/chat/musey/musey_actions_provider.dart';
import 'package:conduit/features/chat/musey/musey_actions_sheet.dart';
import 'package:conduit/features/chat/musey/musey_api.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class _Api implements MuseyApi {
  final calls = <(String, Map<String, Object?>)>[];

  @override
  Future<List<MuseyAction>> fetchActions() async => const [];
  @override
  Future<String> compose(String action, Map<String, Object?> slots) async {
    calls.add((action, slots));
    return 'composed';
  }

  @override
  Future<bool> postFlag(MuseyFlag flag) async => true;
}

const _payees = [
  'Whole Foods',
  'Foodland',
  'Costco',
  'Tim Hortons',
  'Hot Dog Stand',
  'Shoppers',
  'Seafood Market',
  'Food Basics',
  'Fresh Foods',
  'Foodie Bar',
  'Good Food Co',
  'Metro',
  'Bakery',
];

MuseyAction _action({int categories = 3}) => parseMuseyActions({
  'actions': [
    {
      'id': 'expense',
      'label': 'Log an expense',
      'fields': [
        {
          'key': 'payee',
          'label': 'Payee',
          'type': 'text',
          'required': true,
          'suggestions': [
            for (final p in _payees) {'value': p.toLowerCase(), 'label': p},
          ],
        },
        {
          'key': 'cat',
          'label': 'Category',
          'type': 'choice',
          'options': [
            for (var i = 0; i < categories; i++)
              {'value': 'c$i', 'label': 'Category $i'},
          ],
        },
      ],
    },
  ],
}).single;

Future<_Api> _pump(WidgetTester tester, MuseyAction action) async {
  tester.view.physicalSize = const Size(400, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final api = _Api();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [museyApiProvider.overrideWithValue(api)],
      child: MaterialApp(
        theme: AppTheme.light(TweakcnThemes.t3Chat),
        localizationsDelegates: conduitLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: MuseyActionForm(
            action: action,
            send: (_) async => true,
            onDone: () {},
          ),
        ),
      ),
    ),
  );
  return api;
}

Finder _payeeInput() => find.descendant(
  of: find.byKey(const ValueKey('musey-field-payee')),
  matching: find.byType(EditableText),
);

Finder _suggestions() => find.byWidgetPredicate(
  (w) =>
      w.key is ValueKey<String> &&
      (w.key! as ValueKey<String>).value.startsWith('musey-suggestion-payee-'),
);

void main() {
  group('parsing suggestions', () {
    test('keeps good entries, skips malformed ones, label falls back', () {
      final f = parseMuseyActions({
        'actions': [
          {
            'id': 'a',
            'label': 'A',
            'fields': [
              {
                'key': 'p',
                'label': 'P',
                'type': 'text',
                'suggestions': [
                  {'value': 'one', 'label': 'One'},
                  {'value': 'two'},
                  {'label': 'no value'},
                  {'value': 3, 'label': 'number'},
                  'junk',
                  {'value': '', 'label': 'empty'},
                ],
              },
              {'key': 'q', 'label': 'Q', 'type': 'text'},
              {'key': 'r', 'label': 'R', 'type': 'text', 'suggestions': 'x'},
            ],
          },
        ],
      }).single.fields;
      expect(f[0].suggestions.map((o) => (o.value, o.label)), [
        ('one', 'One'),
        ('two', 'two'),
      ]);
      expect(f[1].suggestions, isEmpty);
      expect(f[2].suggestions, isEmpty);
    });
  });

  group('filterMuseyOptions', () {
    final options = [
      for (final p in _payees) MuseyOption(value: p.toLowerCase(), label: p),
    ];
    List<String> labels(String q, {int? limit, bool all = false}) =>
        filterMuseyOptions(
          options,
          q,
          limit: limit,
          emptyKeepsAll: all,
        ).map((o) => o.label).toList();

    test('word starts first, then anywhere, case-insensitive', () {
      expect(labels('FOOD'), [
        'Whole Foods',
        'Foodland',
        'Food Basics',
        'Fresh Foods',
        'Foodie Bar',
        'Good Food Co',
        'Seafood Market',
      ]);
    });

    test('a match at a word start beats an earlier match inside a word', () {
      final out = labels('ho');
      expect(
        out.indexOf('Hot Dog Stand'),
        lessThan(out.indexOf('Whole Foods')),
      );
      expect(
        out.indexOf('Shoppers'),
        greaterThan(out.indexOf('Hot Dog Stand')),
      );
    });

    test('at most the limit, empty query shows none unless asked', () {
      expect(labels('o', limit: 8), hasLength(8));
      expect(labels('  '), isEmpty);
      expect(labels('', all: true), hasLength(_payees.length));
      expect(labels('zzz'), isEmpty);
    });
  });

  group('suggestions in the form', () {
    testWidgets('nothing shows before typing, matches show while typing', (
      tester,
    ) async {
      await _pump(tester, _action());
      expect(_suggestions(), findsNothing);
      await tester.enterText(_payeeInput(), 'food');
      await tester.pump();
      expect(_suggestions(), findsNWidgets(7));
      await tester.enterText(_payeeInput(), 'costc');
      await tester.pump();
      expect(_suggestions(), findsOneWidget);
    });

    testWidgets('shows at most 8 suggestions', (tester) async {
      await _pump(tester, _action());
      await tester.enterText(_payeeInput(), 'o');
      await tester.pump();
      expect(_suggestions(), findsNWidgets(8));
    });

    testWidgets('tapping one fills the field and sends its value', (
      tester,
    ) async {
      final api = await _pump(tester, _action());
      await tester.enterText(_payeeInput(), 'costc');
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('musey-suggestion-payee-costco')),
      );
      await tester.pump();
      expect(
        tester.widget<EditableText>(_payeeInput()).controller.text,
        'Costco',
      );
      expect(_suggestions(), findsNothing);
      await tester.tap(find.byKey(const ValueKey('musey-send')));
      await tester.pumpAndSettle();
      expect(api.calls.single.$2['payee'], 'costco');
    });

    testWidgets('free text still sends as typed', (tester) async {
      final api = await _pump(tester, _action());
      await tester.enterText(_payeeInput(), 'Corner stall');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('musey-send')));
      await tester.pumpAndSettle();
      expect(api.calls.single.$2['payee'], 'Corner stall');
    });

    testWidgets('editing after a tap sends what is typed', (tester) async {
      final api = await _pump(tester, _action());
      await tester.enterText(_payeeInput(), 'costc');
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('musey-suggestion-payee-costco')),
      );
      await tester.pump();
      await tester.enterText(_payeeInput(), 'Costco Gas');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('musey-send')));
      await tester.pumpAndSettle();
      expect(api.calls.single.$2['payee'], 'Costco Gas');
    });

    testWidgets('a text field without suggestions stays plain', (tester) async {
      await _pump(
        tester,
        parseMuseyActions({
          'actions': [
            {
              'id': 'x',
              'label': 'X',
              'fields': [
                {'key': 'payee', 'label': 'Payee', 'type': 'text'},
              ],
            },
          ],
        }).single,
      );
      await tester.enterText(_payeeInput(), 'food');
      await tester.pump();
      expect(_suggestions(), findsNothing);
    });
  });

  group('long choice picker', () {
    testWidgets('12 options or fewer stay inline', (tester) async {
      await _pump(tester, _action(categories: 12));
      expect(find.byKey(const ValueKey('musey-picker-cat')), findsNothing);
      expect(
        find.byKey(const ValueKey('musey-option-cat-c11')),
        findsOneWidget,
      );
    });

    testWidgets('13 options open a picker with a search box', (tester) async {
      final api = await _pump(tester, _action(categories: 40));
      expect(find.byKey(const ValueKey('musey-option-cat-c0')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('musey-picker-cat')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('musey-picker-search')), findsOneWidget);
      await tester.enterText(
        find.descendant(
          of: find.byKey(const ValueKey('musey-picker-search')),
          matching: find.byType(EditableText),
        ),
        'category 3',
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('musey-pick-c3')), findsOneWidget);
      expect(find.byKey(const ValueKey('musey-pick-c30')), findsOneWidget);
      expect(find.byKey(const ValueKey('musey-pick-c4')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('musey-pick-c30')));
      await tester.pumpAndSettle();
      expect(find.text('Category 30'), findsOneWidget);
      await tester.enterText(_payeeInput(), 'Shop');
      await tester.tap(find.byKey(const ValueKey('musey-send')));
      await tester.pumpAndSettle();
      expect(api.calls.single.$2, {'payee': 'Shop', 'cat': 'c30'});
    });
  });
}
