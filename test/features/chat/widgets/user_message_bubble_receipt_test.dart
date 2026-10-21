import 'package:checks/checks.dart';
import 'package:conduit/features/chat/widgets/message_badge.dart';
import 'package:conduit/features/chat/widgets/user_message_bubble.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

Widget _buildHarness(
  MessageReceipt receipt, {
  String content = 'Lunch at a cafe',
}) {
  return ProviderScope(
    child: MaterialApp(
      theme: AppTheme.light(TweakcnThemes.t3Chat),
      localizationsDelegates: conduitLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      // Like the transcript, the list leaves the message its own height.
      home: Scaffold(
        body: ListView(
          children: [
            UserMessageBubble(
              message: ChatMessage(
                id: 'user-1',
                role: 'user',
                content: content,
                timestamp: DateTime.utc(2024, 1, 1),
              ),
              isUser: true,
              onDelete: () {},
              receipt: receipt,
            ),
          ],
        ),
      ),
    ),
  );
}

void main() {
  final receiptFinder = find.byKey(const Key('user-message-receipt'));

  testWidgets('shows nothing without a receipt', (tester) async {
    await tester.pumpWidget(_buildHarness(MessageReceipt.none));
    await tester.pump();

    check(receiptFinder.evaluate()).isEmpty();
    check(find.text('\u{1F44D}').evaluate()).isEmpty();
    check(find.text('❌').evaluate()).isEmpty();
  });

  testWidgets('shows a full-strength thumbs up when delivered', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(_buildHarness(MessageReceipt.delivered));
    await tester.pump();

    check(receiptFinder.evaluate()).length.equals(1);
    check(find.text('\u{1F44D}').evaluate()).length.equals(1);
    check(
      find
          .ancestor(of: find.text('\u{1F44D}'), matching: find.byType(Opacity))
          .evaluate(),
    ).isEmpty();
    check(find.bySemanticsLabel(RegExp(r'\bDelivered$')).evaluate()).length
        .equals(1);
    semantics.dispose();
  });

  testWidgets('shows a cross badge when failed', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(_buildHarness(MessageReceipt.failed));
    await tester.pump();

    check(receiptFinder.evaluate()).length.equals(1);
    final badge = tester.widget<MessageBadge>(find.byType(MessageBadge));
    check(badge.emoji).equals('\u274C');
    check(find.bySemanticsLabel(RegExp(r'\bNot delivered$')).evaluate()).length
        .equals(1);
    semantics.dispose();
  });

  testWidgets(
    'a third of the badge sits on the bubble bottom-trailing corner',
    (tester) async {
      await tester.pumpWidget(_buildHarness(MessageReceipt.delivered));
      await tester.pump();

      final bubble = tester.getRect(
        find.byKey(const Key('user-message-bubble-surface')),
      );
      final badge = tester.getRect(find.byType(MessageBadge));
      check(badge.width).equals(MessageBadge.size);
      check(badge.left).equals(bubble.right - MessageBadge.overlap);
      check(badge.top).equals(bubble.bottom - MessageBadge.overlap);
    },
  );

  testWidgets('the badge never covers the text of a one-word bubble', (
    tester,
  ) async {
    await tester.pumpWidget(
      _buildHarness(MessageReceipt.delivered, content: 'Thanks!'),
    );
    await tester.pump();

    final text = tester.getRect(find.text('Thanks!'));
    final badge = tester.getRect(find.byType(MessageBadge));
    check(text.overlaps(badge)).isFalse();
  });

  testWidgets('a failed send that is retried successfully turns to delivered', (
    tester,
  ) async {
    await tester.pumpWidget(_buildHarness(MessageReceipt.failed));
    await tester.pump();
    check(find.text('\u274C').evaluate()).length.equals(1);

    await tester.pumpWidget(_buildHarness(MessageReceipt.delivered));
    await tester.pump();
    check(find.text('\u274C').evaluate()).isEmpty();
    check(find.text('\u{1F44D}').evaluate()).length.equals(1);
  });
}
