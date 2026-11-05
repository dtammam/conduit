import 'package:checks/checks.dart';
import 'package:conduit/core/startup/omni_launch_gate.dart';
import 'package:conduit/features/chat/widgets/composer_focus_intent.dart';
import 'package:conduit/features/chat/widgets/modern_chat_input.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

Future<ProviderContainer> _mount(WidgetTester tester) async {
  late ProviderContainer container;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [apiServiceProvider.overrideWithValue(null)],
      child: Consumer(
        builder: (context, ref, _) {
          container = ProviderScope.containerOf(context);
          return MaterialApp(
            localizationsDelegates: conduitLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: Align(
                alignment: Alignment.bottomCenter,
                child: ModernChatInput(onSendMessage: (_) {}),
              ),
            ),
          );
        },
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  return container;
}

bool _focused(WidgetTester tester) =>
    tester.widget<TextField>(find.byType(TextField)).focusNode?.hasFocus ??
    false;

void main() {
  testWidgets('a cold launch leaves the composer unfocused', (tester) async {
    await _mount(tester);
    check(_focused(tester)).isFalse();
  });

  testWidgets('a focus request raised before the composer existed is ignored', (
    tester,
  ) async {
    // A launch path (share, widget, intent) bumped the trigger earlier.
    final early = ProviderContainer(
      overrides: [apiServiceProvider.overrideWithValue(null)],
    );
    addTearDown(early.dispose);
    early.read(inputFocusTriggerProvider.notifier).increment();
    // Mount the composer in the same container later.
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: early,
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
    await tester.pump(const Duration(milliseconds: 300));
    check(_focused(tester)).isFalse();
  });

  testWidgets('the launch gate settling does not focus it either', (
    tester,
  ) async {
    OmniLaunchGate.settled.value = false;
    addTearDown(() => OmniLaunchGate.settled.value = true);
    await _mount(tester);
    OmniLaunchGate.settled.value = true;
    await tester.pump(const Duration(milliseconds: 300));
    check(_focused(tester)).isFalse();
  });

  testWidgets('returning from the background keeps the keyboard down', (
    tester,
  ) async {
    await _mount(tester);
    await tester.tap(find.byType(TextField));
    await tester.pump(const Duration(milliseconds: 300));
    check(_focused(tester)).isTrue();

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(milliseconds: 300));
    check(_focused(tester)).isFalse();
  });

  testWidgets('tapping the field focuses it', (tester) async {
    await _mount(tester);
    check(_focused(tester)).isFalse();
    await tester.tap(find.byType(TextField));
    await tester.pump(const Duration(milliseconds: 300));
    check(_focused(tester)).isTrue();
  });

  testWidgets('a trigger bump while it is on screen still focuses it', (
    tester,
  ) async {
    final container = await _mount(tester);
    await tester.tap(find.byType(TextField));
    await tester.pump(const Duration(milliseconds: 300));
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    check(_focused(tester)).isFalse();
    container.read(composerAutofocusEnabledProvider.notifier).set(true);
    container.read(inputFocusTriggerProvider.notifier).increment();
    await tester.pump(const Duration(milliseconds: 300));
    check(_focused(tester)).isTrue();
  });

  group('an explicit ask to type', () {
    testWidgets('focuses the composer with the cursor after the shared text', (
      tester,
    ) async {
      final container = await _mount(tester);
      container.read(prefilledInputTextProvider.notifier).set('shared words');
      container.read(composerFocusIntentProvider.notifier).request();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      check(_focused(tester)).isTrue();
      final field = tester.widget<TextField>(find.byType(TextField));
      check(field.controller!.text).equals('shared words');
      check(field.controller!.selection.baseOffset).equals(12);
      check(field.controller!.selection.extentOffset).equals(12);
      check(container.read(composerFocusIntentProvider)).isFalse();
    });

    testWidgets(
      'an ask made before the composer exists is served once it does',
      (tester) async {
        final early = ProviderContainer(
          overrides: [apiServiceProvider.overrideWithValue(null)],
        );
        addTearDown(early.dispose);
        early.read(composerFocusIntentProvider.notifier).request();
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: early,
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
        await tester.pump(const Duration(milliseconds: 300));
        check(_focused(tester)).isTrue();
      },
    );

    testWidgets(
      'on a cold start it waits for the launch gate, no flash before',
      (tester) async {
        OmniLaunchGate.settled.value = false;
        addTearDown(() => OmniLaunchGate.settled.value = true);
        final container = await _mount(tester);
        container.read(composerFocusIntentProvider.notifier).request();
        await tester.pump(const Duration(milliseconds: 300));
        check(_focused(tester)).isFalse();
        check(container.read(composerFocusIntentProvider)).isTrue();
        OmniLaunchGate.settled.value = true;
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        check(_focused(tester)).isTrue();
      },
    );

    testWidgets('without an ask a plain open and a reveal leave it down', (
      tester,
    ) async {
      final container = await _mount(tester);
      container.read(composerRevealRequestProvider.notifier).request();
      await tester.pump(const Duration(milliseconds: 300));
      check(_focused(tester)).isFalse();
    });
  });
}
