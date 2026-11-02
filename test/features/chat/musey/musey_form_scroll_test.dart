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
import 'package:shared_preferences/shared_preferences.dart';

class _Api implements MuseyApi {
  @override
  Future<List<MuseyAction>> fetchActions() async => [_expense()];
  @override
  Future<String> compose(String action, Map<String, Object?> slots) async =>
      'composed';
  @override
  Future<bool> postFlag(MuseyFlag flag) async => true;
}

MuseyAction _expense() => parseMuseyActions({
  'actions': [
    {
      'id': 'expense',
      'label': 'Log an expense',
      'fields': [
        {'key': 'a', 'label': 'Payee', 'type': 'text', 'required': true},
        {'key': 'b', 'label': 'Amount', 'type': 'number', 'required': true},
        {'key': 'c', 'label': 'Memo', 'type': 'text'},
        {'key': 'd', 'label': 'Day', 'type': 'date'},
        {'key': 'e', 'label': 'Account', 'type': 'text'},
        {'key': 'f', 'label': 'Tag', 'type': 'text'},
        {'key': 'g', 'label': 'Split', 'type': 'text'},
        {
          'key': 'cat',
          'label': 'Category',
          'type': 'choice',
          'options': [
            for (var i = 0; i < 6; i++) {'value': 'c$i', 'label': 'Cat $i'},
          ],
        },
      ],
    },
  ],
}).single;

Future<void> _open(
  WidgetTester tester, {
  double textScale = 1,
  double keyboard = 0,
}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(320, 568);
  tester.view.devicePixelRatio = 1;
  tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [museyApiProvider.overrideWithValue(_Api())],
      child: MaterialApp(
        theme: AppTheme.light(TweakcnThemes.t3Chat),
        localizationsDelegates: conduitLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              key: const ValueKey('open'),
              onPressed: () => showMuseyActionsSheet(
                context,
                send: (_) async => true,
                initial: _expense(),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const ValueKey('open')));
  await tester.pumpAndSettle();
}

void main() {
  for (final c in [
    (name: 'plain', scale: 1.0, kb: 0.0),
    (name: 'large type', scale: 2.0, kb: 0.0),
    (name: 'keyboard up', scale: 1.0, kb: 260.0),
    (name: 'large type and keyboard', scale: 2.0, kb: 260.0),
  ]) {
    testWidgets('a long form scrolls to the last field at 320x568, ${c.name}', (
      tester,
    ) async {
      await _open(tester, textScale: c.scale, keyboard: c.kb);
      expect(tester.takeException(), isNull);
      final last = find.byKey(const ValueKey('musey-option-cat-c5'));
      await tester.scrollUntilVisible(
        last,
        80,
        scrollable: find
            .descendant(
              of: find.byType(MuseyActionForm),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(tester.takeException(), isNull);
      final rect = tester.getRect(last);
      expect(rect.bottom, lessThanOrEqualTo(568 - c.kb));
      // The send button stays on screen above the keyboard.
      final send = tester.getRect(find.byKey(const ValueKey('musey-send')));
      expect(send.bottom, lessThanOrEqualTo(568 - c.kb));
      expect(send.top, greaterThanOrEqualTo(0));
    });
  }
}
