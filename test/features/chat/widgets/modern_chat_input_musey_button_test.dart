import 'package:checks/checks.dart';
import 'package:conduit/features/chat/musey/musey_api.dart';
import 'package:conduit/features/chat/widgets/modern_chat_input.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class _FakeMuseyApi implements MuseyApi {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

Future<void> _pump(WidgetTester tester, {required double width}) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiServiceProvider.overrideWithValue(null),
        museyApiProvider.overrideWithValue(_FakeMuseyApi()),
      ],
      child: MaterialApp(
        localizationsDelegates: conduitLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: ModernChatInput(
              onSendMessage: (_) {},
              onMuseySend: (_) async => true,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

final _wrench = find.byKey(const ValueKey('composer-musey-button'));
final _primary = find.byWidgetPredicate((w) {
  final k = w.key;
  return k is ValueKey<String> && k.value.startsWith('primary-btn-');
});

void main() {
  for (final width in [320.0, 390.0]) {
    testWidgets('wrench sits right of the field, left of the primary button, '
        'and does not move with text at $width pt', (tester) async {
      await _pump(tester, width: width);
      check(_wrench.evaluate()).length.equals(1);
      final empty = tester.getRect(_wrench);
      final primaryEmpty = tester.getRect(_primary.first);
      check(empty.width).isGreaterOrEqual(44);
      check(empty.height).isGreaterOrEqual(44);
      check(empty.left)
          .isGreaterThan(tester.getRect(find.byType(TextField)).left);
      check(empty.right).isLessThan(primaryEmpty.left + 0.01);

      await tester.enterText(find.byType(TextField), 'word ' * 80);
      await tester.pump();
      await tester.pump();
      check(tester.takeException()).isNull();
      final typed = tester.getRect(_wrench);
      final primaryTyped = tester.getRect(_primary.first);
      check(typed.right).isLessThan(primaryTyped.left + 0.01);
      check(typed.right).isCloseTo(empty.right, 0.01);
      check(typed.width).isGreaterOrEqual(44);
      check(_wrench.hitTestable().evaluate()).length.equals(1);
    });
  }
}
