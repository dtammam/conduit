import 'package:checks/checks.dart';
import 'package:conduit/features/chat/avatar/assistant_action_log.dart';
import 'package:conduit/features/chat/avatar/assistant_pending_approval.dart';
import 'package:conduit/features/chat/avatar/omni_tab_bar.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit_core/features/automations/providers/automation_providers.dart';
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
        ('activity', AssistantSheetTab.activity),
        ('approvals', AssistantSheetTab.approvals),
        ('routines', AssistantSheetTab.routines),
        ('appearance', AssistantSheetTab.appearance),
      ]) {
        await tester.tap(find.byKey(ValueKey('omni-tab-$id')));
        check(opened.last).equals(tab);
      }
      check(opened.length).equals(4);
    });
  }

  testWidgets('the chat button is the selected page and opens nothing', (
    tester,
  ) async {
    final opened = await _mount(tester);
    await tester.tap(find.byKey(const ValueKey('omni-tab-chat')));
    check(opened).isEmpty();
    check(find.bySemanticsLabel('Chat').evaluate()).isNotEmpty;
  });

  testWidgets('the bar is hidden while the keyboard is up', (tester) async {
    await _mount(tester, keyboard: true);
    check(find.byKey(const ValueKey('omni-tab-bar')).evaluate()).isEmpty();
    check(find.byKey(const ValueKey('omni-tab-chat')).evaluate()).isEmpty();
  });

  testWidgets('no Routines button without a routines source', (tester) async {
    await _mount(tester, routines: false);
    check(find.byKey(const ValueKey('omni-tab-routines')).evaluate()).isEmpty();
    check(find.byKey(const ValueKey('omni-tab-appearance')).evaluate()).length
        .equals(1);
  });

  testWidgets('no badge without a waiting approval', (tester) async {
    await _mount(tester);
    check(find.byKey(const ValueKey('omni-tab-badge-approvals')).evaluate())
        .isEmpty();
  });
}
