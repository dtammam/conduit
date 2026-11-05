import 'package:checks/checks.dart';
import 'package:conduit/features/chat/avatar/assistant_action_log.dart';
import 'package:conduit/features/chat/avatar/assistant_pending_approval.dart';
import 'package:conduit/features/chat/avatar/omni_tab_bar.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit_core/features/automations/providers/automation_providers.dart';
import 'package:conduit_core/models/openwebui_chat_prompt.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class _Settings extends AppSettingsNotifier {
  _Settings(this.value);

  final AppSettings value;

  @override
  AppSettings build() => value;
}

Future<List<AssistantSheetTab>> _mount(
  WidgetTester tester, {
  Brightness brightness = Brightness.light,
  bool keyboard = false,
  bool routines = true,
  AssistantApproval? approval,
  List<Override> overrides = const [],
}) async {
  final opened = <AssistantSheetTab>[];
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        automationsAvailableProvider.overrideWithValue(false),
        appSettingsProvider.overrideWith(
          () => _Settings(
            AppSettings(routinesServerUrl: routines ? 'https://r.test' : ''),
          ),
        ),
        assistantApprovalProvider.overrideWithValue(approval),
        ...overrides,
      ],
      child: MaterialApp(
        theme: brightness == Brightness.dark
            ? AppTheme.dark(TweakcnThemes.t3Chat)
            : AppTheme.light(TweakcnThemes.t3Chat),
        localizationsDelegates: conduitLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Center(
            child: OmniTabBar(onOpen: opened.add, keyboardVisible: keyboard),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return opened;
}

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('each button opens its page ($brightness)', (tester) async {
      final opened = await _mount(tester, brightness: brightness);
      check(find.byKey(const ValueKey('omni-tab-bar')).evaluate()).length
          .equals(1);
      for (final (id, tab) in [
        ('chat', AssistantSheetTab.chat),
        ('feed', AssistantSheetTab.feed),
        ('ideas', AssistantSheetTab.ideas),
        ('routines', AssistantSheetTab.routines),
        ('more', AssistantSheetTab.more),
      ]) {
        await tester.tap(find.byKey(ValueKey('omni-tab-$id')));
        check(opened.last).equals(tab);
      }
      check(opened.length).equals(5);
    });
  }

  testWidgets(
    'icons only: no visible labels, names kept as semantics and tooltips',
    (tester) async {
      final semantics = tester.ensureSemantics();
      await _mount(tester);
      for (final label in ['Chat', 'Feed', 'Ideas', 'Routines', 'More']) {
        check(find.text(label).evaluate()).isEmpty();
        check(find.byTooltip(label).evaluate()).length.equals(1);
        check(find.bySemanticsLabel(label).evaluate()).isNotEmpty;
      }
      semantics.dispose();
    },
  );

  testWidgets('sits where Muse'
      's bar does: 21 pt sides, 60 pt tall, 22 pt up', (tester) async {
    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          automationsAvailableProvider.overrideWithValue(false),
          appSettingsProvider.overrideWith(
            () => _Settings(const AppSettings(routinesServerUrl: 'x')),
          ),
          assistantApprovalProvider.overrideWithValue(null),
        ],
        child: MaterialApp(
          theme: AppTheme.light(TweakcnThemes.t3Chat),
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: OmniTabBar(onOpen: (_) {}),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final rect = tester.getRect(find.byKey(const ValueKey('omni-tab-bar')));
    check(rect.left).equals(21);
    check(393 - rect.right).equals(21);
    check(rect.height).equals(60);
    check(852 - rect.bottom).equals(22);
  });

  testWidgets('the selected page sits on a dark pill, the others do not', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          automationsAvailableProvider.overrideWithValue(false),
          appSettingsProvider.overrideWith(
            () => _Settings(const AppSettings(routinesServerUrl: 'x')),
          ),
          assistantApprovalProvider.overrideWithValue(null),
        ],
        child: MaterialApp(
          theme: AppTheme.dark(TweakcnThemes.t3Chat),
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Center(
              child: OmniTabBar(
                onOpen: (_) {},
                selected: AssistantSheetTab.approvals,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    check(find.byKey(const ValueKey('omni-tab-selected-more')).evaluate())
        .length
        .equals(1);
    check(find.byKey(const ValueKey('omni-tab-selected-feed')).evaluate())
        .isEmpty();
  });

  testWidgets('the capsule fits a narrow phone without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await _mount(tester);
    check(tester.takeException()).isNull();
    final box = tester.getSize(find.byKey(const ValueKey('omni-tab-bar')));
    check(box.width).isLessOrEqual(320);
  });

  testWidgets('the bar is hidden while the keyboard is up', (tester) async {
    await _mount(tester, keyboard: true);
    check(find.byKey(const ValueKey('omni-tab-bar')).evaluate()).isEmpty();
  });

  testWidgets('no Routines button without a routines source', (tester) async {
    await _mount(tester, routines: false);
    check(find.byKey(const ValueKey('omni-tab-routines')).evaluate()).isEmpty();
    check(find.byKey(const ValueKey('omni-tab-more')).evaluate()).length
        .equals(1);
  });

  testWidgets('no badge without a waiting approval', (tester) async {
    await _mount(tester);
    check(find.byKey(const ValueKey('omni-tab-badge-more')).evaluate())
        .isEmpty();
  });

  testWidgets('a waiting approval puts the dot on More, in the warning color', (
    tester,
  ) async {
    await _mount(
      tester,
      approval: const AssistantApproval(
        conversationId: 'chat',
        prompt: OpenWebUiComposerPrompt(
          identity: 'saved:m1:c1',
          kind: OpenWebUiComposerPromptKind.toolApproval,
          title: 'create_event',
          message: '{}',
        ),
      ),
    );
    check(find.byKey(const ValueKey('omni-tab-badge-more')).evaluate()).length
        .equals(1);
    check(find.byKey(const ValueKey('omni-tab-badge-approvals')).evaluate())
        .isEmpty();
  });

  testWidgets('gives its room back in step with the keyboard', (tester) async {
    Future<double> heightAt(double progress) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            automationsAvailableProvider.overrideWithValue(false),
            appSettingsProvider.overrideWith(
              () => _Settings(const AppSettings(routinesServerUrl: 'x')),
            ),
            assistantApprovalProvider.overrideWithValue(null),
          ],
          child: MaterialApp(
            theme: AppTheme.light(TweakcnThemes.t3Chat),
            localizationsDelegates: conduitLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: Align(
                alignment: Alignment.bottomCenter,
                child: OmniTabBar(onOpen: (_) {}, keyboardProgress: progress),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      return tester.getSize(find.byType(OmniTabBar)).height;
    }

    final down = await heightAt(0);
    final half = await heightAt(0.5);
    final up = await heightAt(1);
    check(down).isGreaterThan(half);
    check(half).isGreaterThan(up);
    check(up).equals(8);
  });
}
