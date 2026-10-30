import 'package:conduit/features/chat/widgets/omni_session_divider.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit_core/features/chat/omni/omni_session.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:flutter_test/flutter_test.dart';

class _Session extends OmniSessionNotifier {
  _Session(this.initial);

  final OmniSessionState initial;

  @override
  OmniSessionState build() => initial;
}

final _now = DateTime(2026, 10, 29, 15, 0);
final _start = DateTime(2026, 10, 29, 14, 36);

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
            timestamp: _start,
            now: _now,
            child: const Text('message'),
          ),
        ),
      ),
    );

/// CLDR puts a narrow no-break space before AM/PM; compare with a plain one.
String _plain(String s) => s.replaceAll('\u202f', ' ');

void main() {
  const state = OmniSessionState(chatId: 'omni', boundaries: ['u2']);
  setUpAll(() async {
    await initializeDateFormatting('en');
    await initializeDateFormatting('de');
  });

  group('omniSessionTimeLabel', () {
    String label(DateTime d) => _plain(omniSessionTimeLabel(d, _now, 'en'));

    test('today is the time alone', () {
      expect(label(DateTime(2026, 10, 29, 0, 5)), '12:05 AM');
    });
    test('another day is the ISO date, a comma and the time', () {
      expect(label(DateTime(2026, 10, 28, 23, 59)), '2026-10-28, 11:59 PM');
      expect(label(DateTime(2026, 10, 12, 15, 26)), '2026-10-12, 3:26 PM');
    });
    test('uses the locale time format', () {
      expect(_plain(omniSessionTimeLabel(_start, _now, 'de')), '14:36');
      expect(
        omniSessionTimeLabel(DateTime(2026, 10, 12, 15, 26), _now, 'de'),
        '2026-10-12, 15:26',
      );
    });
  });

  for (final brightness in Brightness.values) {
    testWidgets('a session start gets the divider ($brightness)', (
      tester,
    ) async {
      await tester.pumpWidget(_app(state, 'u2', brightness));
      expect(find.byType(OmniSessionDivider), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (w) => w is Text && _plain(w.data ?? '') == '2:36 PM',
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(OmniSessionDivider),
          matching: find.byType(CustomPaint),
        ),
        findsNothing,
      );
      expect(find.text('message'), findsOneWidget);
    });
  }

  testWidgets('any other message has no divider', (tester) async {
    await tester.pumpWidget(_app(state, 'u1', Brightness.light));
    expect(find.byType(OmniSessionDivider), findsNothing);
    expect(find.text('message'), findsOneWidget);
  });
}
