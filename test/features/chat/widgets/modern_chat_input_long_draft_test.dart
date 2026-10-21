import 'package:checks/checks.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit/features/chat/widgets/modern_chat_input.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _shellKey = ValueKey('expanded-composer-shell');
const _inputKey = ValueKey('composer-expanded-input');
const _buttonsKey = ValueKey('composer-expanded-buttons');

Future<void> _pumpComposer(WidgetTester tester) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [apiServiceProvider.overrideWithValue(null)],
      child: MaterialApp(
        localizationsDelegates: conduitLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: ModernChatInput(onSendMessage: (_) {}),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

Future<void> _type(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField), text);
  await tester.pump();
  await tester.pump();
}

void _checkControlsTappable() {
  check(
    find
        .byKey(const ValueKey<String>('composer-overflow-button'))
        .hitTestable()
        .evaluate(),
  ).length.equals(1);
  check(
    find
        .byKey(const ValueKey<String>('primary-btn-send'))
        .hitTestable()
        .evaluate(),
  ).length.equals(1);
}

void main() {
  testWidgets('a long draft scrolls inside the composer while the action row '
      'stays pinned and tappable', (tester) async {
    await _pumpComposer(tester);
    final longDraft = List<String>.generate(
      60,
      (index) => 'line ${index + 1}',
    ).join('\n');
    await _type(tester, longDraft);

    final shellRect = tester.getRect(find.byKey(_shellKey));
    final buttonsRect = tester.getRect(find.byKey(_buttonsKey));
    final inputRect = tester.getRect(find.byKey(_inputKey));

    // The shell hits its height cap; the text, not the shell, overflows.
    check(inputRect.height).isGreaterThan(shellRect.height);
    // The whole action row sits inside the visible shell, at its bottom.
    check(buttonsRect.top).isGreaterOrEqual(shellRect.top);
    check(buttonsRect.bottom).isCloseTo(shellRect.bottom, 0.01);
    _checkControlsTappable();

    // Scrolling the text back to its start leaves the row where it was.
    await tester.drag(find.byKey(_inputKey), const Offset(0, 2000));
    await tester.pump();
    check(tester.getRect(find.byKey(_buttonsKey))).equals(buttonsRect);
    _checkControlsTappable();
  });

  testWidgets('a short multiline draft keeps the shell sized to its content', (
    tester,
  ) async {
    await _pumpComposer(tester);
    await _type(tester, 'first line\nsecond line');

    final shellRect = tester.getRect(find.byKey(_shellKey));
    final inputRect = tester.getRect(find.byKey(_inputKey));
    final buttonsRect = tester.getRect(find.byKey(_buttonsKey));

    check(shellRect.height)
        .isCloseTo(inputRect.height + buttonsRect.height, 0.01);
    check(inputRect.top).isCloseTo(shellRect.top, 0.01);
    check(buttonsRect.top).isCloseTo(inputRect.bottom, 0.01);
  });
}
