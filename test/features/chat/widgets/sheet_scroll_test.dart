import 'package:conduit/features/chat/widgets/chat_export_sheet.dart';
import 'package:conduit/features/chat/widgets/chat_share_sheet.dart';
import 'package:conduit/features/chat/widgets/context_usage_ring.dart';
import 'package:conduit/features/chat/widgets/usage_stats_modal.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/themed_sheets.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// Opens a sheet through [open] on a 320x568 screen with text scaled by
/// [scale] and [keyboard] pixels of keyboard, the way a small iPhone with
/// large Dynamic Type shows it.
Future<void> _host(
  WidgetTester tester, {
  required void Function(BuildContext) open,
  double scale = 2.5,
  double keyboard = 0,
}) async {
  tester.view.physicalSize = const Size(320, 568);
  tester.view.devicePixelRatio = 1;
  tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: AppTheme.light(TweakcnThemes.t3Chat),
        localizationsDelegates: conduitLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              key: const ValueKey('open'),
              onPressed: () => open(context),
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

/// Scrolls the sheet to its end and checks nothing overflowed.
Future<void> _scrollsToEnd(WidgetTester tester, Finder body) async {
  expect(tester.takeException(), isNull);
  expect(body, findsOneWidget);
  await tester.drag(body, const Offset(0, -2000));
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

void main() {
  // None of these sheets has a text field, so the keyboard is never up.
  for (final keyboard in [0.0]) {
    const label = 'large type';

    testWidgets('export sheet scrolls at 320x568, $label', (tester) async {
      await _host(
        tester,
        keyboard: keyboard,
        open: (context) => ThemedSheets.showCustom<void>(
          context: context,
          builder: (_) => ChatExportSheet(
            prepare: (_) async => throw StateError('not used'),
          ),
        ),
      );
      await _scrollsToEnd(
        tester,
        find.descendant(
          of: find.byType(ChatExportSheet),
          matching: find.byType(SingleChildScrollView),
        ),
      );
      final last = tester.getRect(
        find.byKey(const Key('chat-export-transcript')),
      );
      expect(last.bottom, lessThanOrEqualTo(568 - keyboard));
    });

    testWidgets('share sheet scrolls at 320x568, $label', (tester) async {
      await _host(
        tester,
        keyboard: keyboard,
        open: (context) => ThemedSheets.showCustom<void>(
          context: context,
          useSafeArea: true,
          builder: (_) => ChatShareSheet(
            conversation: Conversation(
              id: 'c',
              title: 'Chat',
              createdAt: DateTime.utc(2026),
              updatedAt: DateTime.utc(2026),
              shareId: 'existing',
            ),
          ),
        ),
      );
      await _scrollsToEnd(
        tester,
        find.descendant(
          of: find.byType(ChatShareSheet),
          matching: find.byType(SingleChildScrollView),
        ),
      );
      final last = tester.getRect(find.byKey(const Key('chat-share-delete')));
      expect(last.bottom, lessThanOrEqualTo(568 - keyboard));
    });

    testWidgets('usage sheet scrolls at 320x568, $label', (tester) async {
      await _host(
        tester,
        keyboard: keyboard,
        open: (context) => UsageStatsModal.show(context, const {
          'completion_tokens': 120,
          'prompt_tokens': 800,
          'total_tokens': 920,
          'eval_count': 120,
          'eval_duration': 3000000000,
          'prompt_eval_count': 800,
          'prompt_eval_duration': 1000000000,
          'total_duration': 5000000000,
        }),
      );
      await _scrollsToEnd(tester, find.byType(SheetScrollBody));
    });

    testWidgets('context sheet scrolls at 320x568, $label', (tester) async {
      await _host(
        tester,
        keyboard: keyboard,
        open: (context) => showContextUsageSheet(context),
      );
      await _scrollsToEnd(tester, find.byType(SheetScrollBody));
    });
  }
}
