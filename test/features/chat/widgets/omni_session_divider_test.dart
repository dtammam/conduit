import 'package:conduit/features/chat/widgets/omni_session_divider.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit_core/features/chat/omni/omni_session.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Session extends OmniSessionNotifier {
  _Session(this.initial);

  final OmniSessionState initial;

  @override
  OmniSessionState build() => initial;
}

Widget _app(OmniSessionState state, String messageId, Brightness brightness) =>
    ProviderScope(
      overrides: [omniSessionProvider.overrideWith(() => _Session(state))],
      child: MaterialApp(
        theme: brightness == Brightness.dark
            ? AppTheme.dark(TweakcnThemes.t3Chat)
            : AppTheme.light(TweakcnThemes.t3Chat),
        localizationsDelegates: conduitLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: OmniSessionDividerGate(
            messageId: messageId,
            child: const Text('message'),
          ),
        ),
      ),
    );

void main() {
  const state = OmniSessionState(chatId: 'omni', boundaries: ['u2']);

  for (final brightness in Brightness.values) {
    testWidgets('a session start gets the divider ($brightness)', (
      tester,
    ) async {
      await tester.pumpWidget(_app(state, 'u2', brightness));
      expect(find.byType(OmniSessionDivider), findsOneWidget);
      expect(find.bySemanticsLabel('New session'), findsOneWidget);
      expect(find.text('message'), findsOneWidget);
    });
  }

  testWidgets('any other message has no divider', (tester) async {
    await tester.pumpWidget(_app(state, 'u1', Brightness.light));
    expect(find.byType(OmniSessionDivider), findsNothing);
    expect(find.text('message'), findsOneWidget);
  });
}
