import 'package:conduit/features/chat/musey/musey_actions_provider.dart';
import 'package:conduit/features/chat/musey/musey_actions_sheet.dart';
import 'package:conduit/features/chat/musey/musey_api.dart';
import 'package:conduit/features/chat/widgets/prompt_suggestion_overlay.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit_core/features/prompts/providers/prompts_providers.dart';
import 'package:conduit_core/models/prompt.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Api implements MuseyApi {
  @override
  Future<List<MuseyAction>> fetchActions() async => const [
    MuseyAction(id: 'chore', label: 'Chore'),
    MuseyAction(id: 'groceries', label: 'Grocery add'),
  ];
  @override
  Future<String> compose(String a, Map<String, Object?> s) async => '';
  @override
  Future<bool> postFlag(MuseyFlag f) async => true;
}

const _prompts = [
  Prompt(command: '/checklist', title: 'Checklist', content: 'a'),
  Prompt(command: '/summary', title: 'Summary', content: 'b'),
];

/// The "/" list as the composer builds it: actions first, then the saved
/// prompts under a divider, both filtered by [query].
Widget _overlay(
  String query, {
  required List<Prompt> picked,
  required List<MuseyAction> actionsPicked,
  int index = 0,
  bool withRelay = true,
}) {
  return ProviderScope(
    overrides: [
      museyApiProvider.overrideWithValue(withRelay ? _Api() : null),
      promptsListProvider.overrideWith((ref) async => _prompts),
    ],
    child: MaterialApp(
      theme: AppTheme.light(TweakcnThemes.t3Chat),
      localizationsDelegates: conduitLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Consumer(
          builder: (context, ref, _) {
            final actions = filterMuseyActions(
              ref.watch(museyActionsProvider).actions ?? const [],
              query,
            );
            List<Prompt> filter(List<Prompt> all) => [
              for (final p in all)
                if (p.command.contains(query)) p,
            ];
            final prompts = ref.watch(promptsListProvider).value ?? const [];
            final saved = PromptSuggestionOverlay(
              filteredPrompts: filter,
              selectionIndex: index - actions.length,
              onPromptSelected: picked.add,
            );
            if (!withRelay) return saved;
            return MuseySlashOverlay(
              query: query,
              selectionIndex: index,
              onPicked: actionsPicked.add,
              below: filter(prompts).isEmpty ? null : saved,
            );
          },
        ),
      ),
    ),
  );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> load(WidgetTester tester) async {
    final c = ProviderScope.containerOf(tester.element(find.byType(Scaffold)));
    await c.read(museyActionsProvider.notifier).load();
    await tester.pumpAndSettle();
  }

  testWidgets('shows the actions first, then saved prompts under a divider', (
    tester,
  ) async {
    await tester.pumpWidget(_overlay('', picked: [], actionsPicked: []));
    await tester.pumpAndSettle();
    await load(tester);
    expect(find.byKey(const ValueKey('musey-slash-chore')), findsOneWidget);
    expect(find.byKey(const ValueKey('musey-slash-groceries')), findsOneWidget);
    expect(find.byKey(const ValueKey('musey-slash-divider')), findsOneWidget);
    expect(find.text('/checklist'), findsOneWidget);
    final actionY = tester.getTopLeft(find.text('Chore')).dy;
    final dividerY = tester
        .getTopLeft(find.byKey(const ValueKey('musey-slash-divider')))
        .dy;
    final promptY = tester.getTopLeft(find.text('/checklist')).dy;
    expect(actionY, lessThan(dividerY));
    expect(dividerY, lessThan(promptY));
  });

  testWidgets('the query filters both lists', (tester) async {
    await tester.pumpWidget(_overlay('ch', picked: [], actionsPicked: []));
    await tester.pumpAndSettle();
    await load(tester);
    expect(find.byKey(const ValueKey('musey-slash-chore')), findsOneWidget);
    expect(find.byKey(const ValueKey('musey-slash-groceries')), findsNothing);
    expect(find.text('/checklist'), findsOneWidget);
    expect(find.text('/summary'), findsNothing);
  });

  testWidgets('saved prompts and actions are both reachable by tap', (
    tester,
  ) async {
    final picked = <Prompt>[];
    final actions = <MuseyAction>[];
    await tester.pumpWidget(_overlay('', picked: picked, actionsPicked: actions));
    await tester.pumpAndSettle();
    await load(tester);
    await tester.tap(find.text('/summary'));
    await tester.tap(find.byKey(const ValueKey('musey-slash-chore')));
    expect(picked.single.command, '/summary');
    expect(actions.single.id, 'chore');
  });

  testWidgets('with no matching action the saved prompts stand alone', (
    tester,
  ) async {
    await tester.pumpWidget(_overlay('sum', picked: [], actionsPicked: []));
    await tester.pumpAndSettle();
    await load(tester);
    expect(find.byKey(const ValueKey('musey-slash-divider')), findsNothing);
    expect(find.text('/summary'), findsOneWidget);
  });

  testWidgets('without a relay only saved prompts show', (tester) async {
    await tester.pumpWidget(
      _overlay('', picked: [], actionsPicked: [], withRelay: false),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('musey-slash-overlay')), findsNothing);
    expect(find.text('/checklist'), findsOneWidget);
  });
}
