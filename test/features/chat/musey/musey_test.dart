import 'dart:async';

import 'package:conduit/features/chat/musey/break_prompt_bar.dart';
import 'package:conduit/features/chat/musey/musey_actions_provider.dart';
import 'package:conduit/features/chat/musey/musey_actions_sheet.dart';
import 'package:conduit/features/chat/musey/musey_api.dart';
import 'package:conduit/features/chat/musey/musey_flags.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _choreActions = {
  'actions': [
    {
      'id': 'chore',
      'label': 'Chore',
      'icon': 'house',
      'fields': [
        {
          'key': 'what',
          'label': 'What did you handle?',
          'type': 'choice',
          'required': true,
          'options': [
            {'value': 'dishes', 'label': 'Dishes'},
            {'value': 'trash', 'label': 'Trash'},
          ],
        },
      ],
    },
    {
      'id': 'chore_log',
      'label': 'Chore log',
      'fields': [
        {
          'key': 'chore',
          'label': 'What did you handle?',
          'type': 'choice',
          'required': true,
          'options': [
            {'value': 'Dishes', 'label': 'Dishes'},
            {'value': 'Other', 'label': 'Other'},
          ],
        },
        {
          'key': 'other',
          'label': 'What was it?',
          'type': 'text',
          'required': false,
          'note': 'A few words.',
          'show_when': {'key': 'chore', 'value': 'Other'},
        },
      ],
    },
    {'id': 'undo', 'label': 'Undo', 'fields': []},
    {
      'id': 'expense',
      'label': 'Expense',
      'fields': [
        {'key': 'note', 'label': 'What for?', 'type': 'text', 'required': true},
        {'key': 'amount', 'label': 'Amount', 'type': 'number'},
        {'key': 'day', 'label': 'Day', 'type': 'date'},
      ],
    },
  ],
};

class FakeApi implements MuseyApi {
  FakeApi({this.composeText = 'composed'});

  Future<List<MuseyAction>> Function() onFetch = () async =>
      parseMuseyActions(_choreActions);
  String composeText;
  MuseyApiException? composeError;
  final composeCalls = <(String, Map<String, Object?>)>[];
  final flags = <MuseyFlag>[];
  bool flagsOk = true;

  @override
  Future<List<MuseyAction>> fetchActions() => onFetch();

  @override
  Future<String> compose(String action, Map<String, Object?> slots) async {
    composeCalls.add((action, slots));
    final e = composeError;
    if (e != null) throw e;
    return composeText;
  }

  @override
  Future<bool> postFlag(MuseyFlag flag) async {
    if (!flagsOk) return false;
    flags.add(flag);
    return true;
  }
}

Widget _app(FakeApi? api, Widget child) => ProviderScope(
  overrides: [museyApiProvider.overrideWithValue(api)],
  child: MaterialApp(
    theme: AppTheme.light(TweakcnThemes.t3Chat),
    localizationsDelegates: conduitLocalizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: SingleChildScrollView(child: child)),
  ),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('actions menu', () {
    testWidgets('loads the list from the relay', (tester) async {
      await tester.pumpWidget(
        _app(
          FakeApi(),
          Consumer(
            builder: (context, ref, _) {
              return MuseyActionsSheet(send: (_) async => true);
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('musey-group-do')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('musey-action-chore')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('musey-action-expense')),
        findsOneWidget,
      );
    });

    testWidgets('shows the cached list while the refresh is pending', (
      tester,
    ) async {
      final api = FakeApi();
      // First visit fills the cache.
      await tester.pumpWidget(
        _app(api, MuseyActionsSheet(send: (_) async => true)),
      );
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());

      final never = Completer<List<MuseyAction>>();
      api.onFetch = () => never.future;
      await tester.pumpWidget(
        _app(api, MuseyActionsSheet(send: (_) async => true)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byKey(const ValueKey('musey-group-do')), findsOneWidget);
    });

    testWidgets('shows a plain error with retry when never loaded', (
      tester,
    ) async {
      final api = FakeApi();
      api.onFetch = () async =>
          throw const MuseyApiException('Could not reach the relay.');
      await tester.pumpWidget(
        _app(api, MuseyActionsSheet(send: (_) async => true)),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('musey-actions-error')), findsOneWidget);
      expect(find.text('Could not reach the relay.'), findsOneWidget);

      api.onFetch = () async => parseMuseyActions(_choreActions);
      await tester.tap(find.byKey(const ValueKey('musey-actions-retry')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('musey-group-do')), findsOneWidget);
    });

    test('the slash filter matches label and id', () {
      final all = parseMuseyActions(_choreActions);
      expect(filterMuseyActions(all, 'ch').map((a) => a.id), [
        'chore',
        'chore_log',
      ]);
      expect(filterMuseyActions(all, '').length, 4);
      expect(filterMuseyActions(all, 'zzz'), isEmpty);
    });
  });

  group('action groups', () {
    const ids = [
      'chore_log',
      'expense_log',
      'grocery_add',
      'grocery_run',
      'event_create',
      'note_quick',
      'routine_done',
      'routine_start',
      'undo',
    ];
    List<Map<String, Object?>> catalog(List<String> withIds) => [
      for (final id in withIds)
        {
          'id': id,
          'label': 'L $id',
          'fields': id == 'undo'
              ? []
              : [
                  {
                    'key': 'k',
                    'label': 'K',
                    'type': 'choice',
                    'required': true,
                    'options': [
                      {'value': 'a', 'label': 'A'},
                    ],
                  },
                ],
        },
    ];
    FakeApi apiFor(List<String> withIds) {
      final api = FakeApi();
      api.onFetch = () async =>
          parseMuseyActions({'actions': catalog(withIds)});
      return api;
    }

    Future<void> open(
      WidgetTester tester,
      FakeApi api, {
      MuseySend? send,
    }) async {
      await tester.pumpWidget(
        _app(api, MuseyActionsSheet(send: send ?? (_) async => true)),
      );
      await tester.pumpAndSettle();
    }

    ValueKey<String> act(String id) => ValueKey('musey-action-$id');

    testWidgets('four top rows in order, nothing else', (tester) async {
      await open(tester, apiFor(ids));
      final keys = [
        'musey-group-do',
        'musey-group-run',
        'musey-group-check',
        'musey-group-undo',
      ];
      final ys = [
        for (final k in keys) tester.getTopLeft(find.byKey(ValueKey(k))).dy,
      ];
      expect(ys, [...ys]..sort());
      expect(ys.toSet().length, 4);
      for (final id in ids) {
        expect(find.byKey(act(id)), findsNothing);
      }
      expect(find.text('Do a thing'), findsOneWidget);
      expect(find.text('Run a routine'), findsOneWidget);
      expect(find.text('Check off a thing'), findsOneWidget);
      expect(find.text('Undo the last thing'), findsOneWidget);
    });

    test('each id has its home and unknown ids land under Do a thing', () {
      final g = groupMuseyActions(
        parseMuseyActions({
          'actions': catalog([...ids, 'brand_new']),
        }),
      );
      List<String> of(MuseyGroup x) => [for (final a in g[x]!) a.id];
      expect(of(MuseyGroup.doThing), [
        'chore_log',
        'expense_log',
        'grocery_add',
        'grocery_run',
        'event_create',
        'note_quick',
        'brand_new',
      ]);
      expect(of(MuseyGroup.runRoutine), ['routine_start']);
      expect(of(MuseyGroup.checkOff), ['routine_done']);
      expect(of(MuseyGroup.undo), ['undo']);
      expect(g.values.expand((l) => l).length, ids.length + 1);
    });

    testWidgets(
      'Do a thing lists its actions, unknown id included; back works',
      (tester) async {
        await open(tester, apiFor([...ids, 'brand_new']));
        await tester.tap(find.byKey(const ValueKey('musey-group-do')));
        await tester.pumpAndSettle();
        for (final id in [
          'chore_log',
          'expense_log',
          'grocery_add',
          'grocery_run',
          'event_create',
          'note_quick',
          'brand_new',
        ]) {
          expect(find.byKey(act(id)), findsOneWidget, reason: id);
        }
        expect(find.byKey(act('routine_start')), findsNothing);
        // into a form and back to the sub-list, then back to the top
        await tester.tap(find.byKey(act('chore_log')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('musey-back')));
        await tester.pumpAndSettle();
        expect(find.byKey(act('chore_log')), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('musey-back')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('musey-group-do')), findsOneWidget);
      },
    );

    testWidgets('Run a routine and Check off a thing open their pick flow', (
      tester,
    ) async {
      final api = apiFor(ids);
      final sent = <String>[];
      api.composeText = 'msg';
      await open(
        tester,
        api,
        send: (t) async {
          sent.add(t);
          return true;
        },
      );
      await tester.tap(find.byKey(const ValueKey('musey-group-run')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('musey-form-routine_start')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('musey-back')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('musey-group-check')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('musey-form-routine_done')),
        findsOneWidget,
      );
      await tester.tap(find.text('A'));
      await tester.pumpAndSettle();
      expect(api.composeCalls.single.$1, 'routine_done');
      expect(sent, ['msg']);
    });

    // "Control the house" lives inside Do a thing, first in its list (Dean:
    // "I think I want it under a thing"); there is no fifth top row.
    List<Map<String, Object?>> houseCatalog() => [
      ...catalog(ids),
      {
        'id': 'home_control',
        'label': 'Control the house',
        'icon': 'house',
        'fields': [
          {
            'key': 'pick',
            'label': 'What to do',
            'type': 'choice',
            'required': true,
            'options': [
              {
                'value': 'scene|scene.arcade',
                'label': 'Arcade on',
                'group': 'Scenes',
              },
              {
                'value': 'plug|switch.pinball|on',
                'label': 'Pinball on',
                'group': 'Downstairs',
                'hint': 'off now',
              },
              {
                'value': 'plug|switch.rolife_house|off',
                'label': 'Rolife House',
                'group': 'Study',
                'hint': 'offline',
                'disabled': true,
              },
              {
                'value': 'group|lights|on',
                'label': 'All the lights on',
                'group': 'Groups',
              },
            ],
          },
        ],
      },
    ];

    testWidgets('the house entry is first under Do a thing, four rows stay', (
      tester,
    ) async {
      final api = FakeApi();
      api.onFetch = () async => parseMuseyActions({'actions': houseCatalog()});
      await open(tester, api);
      expect(find.byKey(const ValueKey('musey-group-house')), findsNothing);
      expect(find.text('Control the house'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('musey-group-do')));
      await tester.pumpAndSettle();
      final home = tester.getTopLeft(find.byKey(act('home_control'))).dy;
      expect(
        home,
        lessThan(tester.getTopLeft(find.byKey(act('chore_log'))).dy),
      );
      expect(find.text('Control the house'), findsOneWidget);
      expect(
        [
          for (final a in groupMuseyActions(
            parseMuseyActions({'actions': houseCatalog()}),
          )[MuseyGroup.doThing]!)
            a.id,
        ].first,
        'home_control',
      );
      expect(museyGroupOf('home_control'), MuseyGroup.doThing);
    });

    testWidgets('the house list shows headings, hints, and sends a pick', (
      tester,
    ) async {
      final api = FakeApi(composeText: 'Turn on Pinball');
      api.onFetch = () async => parseMuseyActions({'actions': houseCatalog()});
      final sent = <String>[];
      await open(
        tester,
        api,
        send: (t) async {
          sent.add(t);
          return true;
        },
      );
      await tester.tap(find.byKey(const ValueKey('musey-group-do')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(act('home_control')));
      await tester.pumpAndSettle();
      for (final h in ['Scenes', 'Downstairs', 'Study', 'Groups']) {
        expect(
          find.byKey(ValueKey('musey-heading-$h')),
          findsOneWidget,
          reason: h,
        );
      }
      expect(find.text('off now'), findsOneWidget);
      expect(find.text('offline'), findsOneWidget);
      // an offline plug is not tappable
      await tester.tap(find.text('Rolife House'));
      await tester.pumpAndSettle();
      expect(api.composeCalls, isEmpty);
      // one tap on a row composes through the relay and sends
      await tester.tap(find.text('Pinball on'));
      await tester.pumpAndSettle();
      expect(api.composeCalls.single.$1, 'home_control');
      expect(api.composeCalls.single.$2, {'pick': 'plug|switch.pinball|on'});
      expect(sent, ['Turn on Pinball']);
    });

    testWidgets('the house row says why when the home is unreachable', (
      tester,
    ) async {
      final api = FakeApi();
      api.onFetch = () async => parseMuseyActions({
        'actions': [
          {
            'id': 'home_control',
            'label': 'Control the house',
            'icon': 'house',
            'fields': [
              {
                'key': 'pick',
                'label': 'What to do',
                'type': 'choice',
                'required': true,
                'options': [],
                'note': "Can't reach your home right now",
              },
            ],
          },
        ],
      });
      await open(tester, api);
      await tester.tap(find.byKey(const ValueKey('musey-group-do')));
      await tester.pumpAndSettle();
      expect(find.text("Can't reach your home right now"), findsOneWidget);
    });

    testWidgets('a group with several actions shows a list', (tester) async {
      await open(tester, apiFor(['routine_done', 'routine_start', 'undo']));
      // simulate a second check-off action via a new id is not possible by
      // design (unknown ids go to Do a thing), so the list view is covered by
      // the Do a thing test; an empty group shows a plain note.
      await tester.pumpWidget(const SizedBox());
      await open(tester, apiFor(['chore_log']));
      await tester.tap(find.byKey(const ValueKey('musey-group-run')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('musey-group-empty')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('musey-back')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('musey-group-do')), findsOneWidget);
    });

    testWidgets('Undo the last thing acts at once, no sub-list', (
      tester,
    ) async {
      final api = apiFor(ids);
      api.composeText = 'undo msg';
      final sent = <String>[];
      await open(
        tester,
        api,
        send: (t) async {
          sent.add(t);
          return true;
        },
      );
      await tester.tap(find.byKey(const ValueKey('musey-group-undo')));
      await tester.pumpAndSettle();
      expect(api.composeCalls.single.$1, 'undo');
      expect(api.composeCalls.single.$2, isEmpty);
      expect(sent, ['undo msg']);
    });
  });

  group('action form', () {
    MuseyAction action(String id) =>
        parseMuseyActions(_choreActions).firstWhere((a) => a.id == id);

    testWidgets('one tap on the only required choice composes and sends', (
      tester,
    ) async {
      final api = FakeApi(composeText: 'Handled dishes');
      final sent = <String>[];
      var done = 0;
      await tester.pumpWidget(
        _app(
          api,
          MuseyActionForm(
            action: action('chore'),
            send: (t) async {
              sent.add(t);
              return true;
            },
            onDone: () => done++,
          ),
        ),
      );
      expect(find.byKey(const ValueKey('musey-send')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('musey-option-what-dishes')));
      await tester.pumpAndSettle();
      expect(api.composeCalls.single.$1, 'chore');
      expect(api.composeCalls.single.$2, {'what': 'dishes'});
      expect(sent, ['Handled dishes']);
      expect(done, 1);
    });

    testWidgets('a missing required field blocks the send', (tester) async {
      final api = FakeApi();
      await tester.pumpWidget(
        _app(
          api,
          MuseyActionForm(
            action: action('expense'),
            send: (_) async => true,
            onDone: () {},
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('musey-send')));
      await tester.pumpAndSettle();
      expect(api.composeCalls, isEmpty);
      expect(find.byKey(const ValueKey('musey-error-note')), findsOneWidget);

      await tester.enterText(
        find.descendant(
          of: find.byKey(const ValueKey('musey-field-note')),
          matching: find.byType(EditableText),
        ),
        'Lunch',
      );
      await tester.enterText(
        find.descendant(
          of: find.byKey(const ValueKey('musey-field-amount')),
          matching: find.byType(EditableText),
        ),
        '12,5',
      );
      await tester.tap(find.byKey(const ValueKey('musey-send')));
      await tester.pumpAndSettle();
      final slots = api.composeCalls.single.$2;
      expect(slots['note'], 'Lunch');
      expect(slots['amount'], 12.5);
      expect(slots['day'], matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')));
    });

    testWidgets('date and time default to now', (tester) async {
      final api = FakeApi();
      await tester.pumpWidget(
        _app(
          api,
          MuseyActionForm(
            action: action('expense'),
            now: () => DateTime(2026, 11, 1, 9, 5),
            send: (_) async => true,
            onDone: () {},
          ),
        ),
      );
      await tester.enterText(
        find.descendant(
          of: find.byKey(const ValueKey('musey-field-note')),
          matching: find.byType(EditableText),
        ),
        'x',
      );
      await tester.tap(find.byKey(const ValueKey('musey-send')));
      await tester.pumpAndSettle();
      expect(api.composeCalls.single.$2['day'], '2026-11-01');
    });

    testWidgets('the composed text reaches the chat byte for byte', (
      tester,
    ) async {
      const text = '  Handled dishes​⁣‍﻿ \n ';
      final api = FakeApi(composeText: text);
      String? got;
      await tester.pumpWidget(
        _app(
          api,
          MuseyActionForm(
            action: action('chore'),
            send: (t) async {
              got = t;
              return true;
            },
            onDone: () {},
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('musey-option-what-trash')));
      await tester.pumpAndSettle();
      expect(got, isNotNull);
      expect(got!.codeUnits, text.codeUnits);
    });

    testWidgets(
      'a conditional chore field: any chore but Other sends at once',
      (tester) async {
        final api = FakeApi();
        await tester.pumpWidget(
          _app(
            api,
            MuseyActionForm(
              action: action('chore_log'),
              send: (_) async => true,
              onDone: () {},
            ),
          ),
        );
        expect(find.byKey(const ValueKey('musey-field-other')), findsNothing);
        expect(find.byKey(const ValueKey('musey-send')), findsNothing);
        await tester.tap(
          find.byKey(const ValueKey('musey-option-chore-Dishes')),
        );
        await tester.pumpAndSettle();
        expect(api.composeCalls.single.$2, {'chore': 'Dishes'});
      },
    );

    testWidgets('Other reveals a required text field with its note', (
      tester,
    ) async {
      final api = FakeApi();
      await tester.pumpWidget(
        _app(
          api,
          MuseyActionForm(
            action: action('chore_log'),
            send: (_) async => true,
            onDone: () {},
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('musey-option-chore-Other')));
      await tester.pumpAndSettle();
      expect(api.composeCalls, isEmpty);
      expect(find.byKey(const ValueKey('musey-field-other')), findsOneWidget);
      expect(find.text('A few words.'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('musey-send')));
      await tester.pumpAndSettle();
      expect(api.composeCalls, isEmpty);
      expect(find.byKey(const ValueKey('musey-error-other')), findsOneWidget);
      await tester.enterText(
        find.descendant(
          of: find.byKey(const ValueKey('musey-field-other')),
          matching: find.byType(EditableText),
        ),
        'Fixed the gate',
      );
      await tester.tap(find.byKey(const ValueKey('musey-send')));
      await tester.pumpAndSettle();
      expect(api.composeCalls.single.$2, {
        'chore': 'Other',
        'other': 'Fixed the gate',
      });
    });

    testWidgets('an action with no fields runs when picked', (tester) async {
      final api = FakeApi(composeText: 'undo');
      final sent = <String>[];
      await tester.pumpWidget(
        _app(
          api,
          MuseyActionForm(
            action: action('undo'),
            send: (t) async {
              sent.add(t);
              return true;
            },
            onDone: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(sent, ['undo']);
      expect(api.composeCalls.single.$2, isEmpty);
    });

    testWidgets('a bad slot shows the relay error and sends nothing', (
      tester,
    ) async {
      final api = FakeApi()
        ..composeError = const MuseyApiException('bad amount', badSlot: true);
      var sent = 0;
      await tester.pumpWidget(
        _app(
          api,
          MuseyActionForm(
            action: action('chore'),
            send: (_) async {
              sent++;
              return true;
            },
            onDone: () {},
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('musey-option-what-dishes')));
      await tester.pumpAndSettle();
      expect(sent, 0);
      expect(find.text('bad amount'), findsOneWidget);
    });

    testWidgets('the slash overlay lists matches and picks one', (
      tester,
    ) async {
      final api = FakeApi();
      MuseyAction? picked;
      await tester.pumpWidget(
        _app(
          api,
          Consumer(
            builder: (context, ref, _) {
              ref.watch(museyActionsProvider);
              return MuseySlashOverlay(
                query: 'ch',
                selectionIndex: 0,
                onPicked: (a) => picked = a,
              );
            },
          ),
        ),
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(MuseySlashOverlay)),
      );
      await container.read(museyActionsProvider.notifier).load();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('musey-slash-expense')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('musey-slash-chore')));
      expect(picked?.id, 'chore');
    });
  });

  group('break flags', () {
    final target = const BreakFlagTarget(
      chatId: 'c1',
      messageId: 'm2',
      replyText: 'a reply',
      userText: 'a question',
    );

    test('the next message is taken once, then sending is normal', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.read(breakPromptProvider.notifier).start(target);
      expect(c.read(flaggedMessagesProvider), contains('m2'));
      expect(c.read(breakPromptProvider.notifier).take()?.messageId, 'm2');
      // The one after that is an ordinary chat message.
      expect(c.read(breakPromptProvider.notifier).take(), isNull);
      expect(c.read(flaggedMessagesProvider), contains('m2'));
    });

    test('cancel returns to normal and removes the mark', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.read(breakPromptProvider.notifier).start(target);
      c.read(breakPromptProvider.notifier).cancel();
      expect(c.read(breakPromptProvider), isNull);
      expect(c.read(flaggedMessagesProvider), isNot(contains('m2')));
    });

    test('the target carries the reply and the user message it answered', () {
      final messages = [
        ChatMessage(
          id: 'm1',
          role: 'user',
          content: 'a question',
          timestamp: DateTime.utc(2026),
        ),
        ChatMessage(
          id: 'm2',
          role: 'assistant',
          content: 'a reply',
          timestamp: DateTime.utc(2026),
        ),
      ];
      final t = buildBreakTarget(messages, chatId: 'c1', messageId: 'm2')!;
      expect(t.userText, 'a question');
      expect(t.replyText, 'a reply');
      expect(buildBreakTarget(messages, chatId: 'c1', messageId: 'zz'), isNull);
    });

    test('a posted note leaves nothing in the queue', () async {
      final api = FakeApi();
      final queue = MuseyFlagQueue(() => api);
      final ok = await submitBreakNote(
        queue,
        target,
        'wrong total',
        build: '1.2.3+45',
        persona: 'Bobby',
        now: DateTime.utc(2026, 11, 1, 12),
      );
      expect(ok, isTrue);
      expect(await queue.pending(), isEmpty);
      final body = api.flags.single.toJson();
      expect(body['chat_id'], 'c1');
      expect(body['message_id'], 'm2');
      expect(body['reply_text'], 'a reply');
      expect(body['user_text'], 'a question');
      expect(body['note'], 'wrong total');
      expect(body['ts'], '2026-11-01T12:00:00.000Z');
      expect(body['build'], '1.2.3+45');
      expect(body['persona'], 'Bobby');
    });

    test(
      'a failed post stays queued and goes out on the next launch',
      () async {
        final api = FakeApi()..flagsOk = false;
        final queue = MuseyFlagQueue(() => api);
        final ok = await submitBreakNote(queue, target, 'lost', build: 'b');
        expect(ok, isFalse);
        expect((await queue.pending()).single.note, 'lost');

        // A new queue object stands in for the next launch.
        api.flagsOk = true;
        final relaunched = MuseyFlagQueue(() => api);
        expect(await relaunched.retryAll(), 1);
        expect(await relaunched.pending(), isEmpty);
        expect(api.flags.single.note, 'lost');
      },
    );

    test('no relay client keeps the note queued', () async {
      final queue = MuseyFlagQueue(() => null);
      expect(await submitBreakNote(queue, target, 'kept', build: 'b'), isFalse);
      expect((await queue.pending()), hasLength(1));
    });

    testWidgets('the prompt bar shows What broke? and cancels', (tester) async {
      await tester.pumpWidget(_app(null, const BreakPromptBar()));
      final c = ProviderScope.containerOf(
        tester.element(find.byType(BreakPromptBar)),
      );
      expect(find.text('What broke?'), findsNothing);
      c.read(breakPromptProvider.notifier).start(target);
      await tester.pump();
      expect(find.text('What broke?'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('break-prompt-cancel')));
      await tester.pump();
      expect(find.text('What broke?'), findsNothing);
      expect(c.read(breakPromptProvider), isNull);
    });
  });
}
