import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit/features/chat/providers/text_to_speech_provider.dart';
import 'package:conduit/features/chat/reactions/quick_reply_reactions.dart';
import 'package:conduit/features/chat/widgets/assistant_message_widget.dart';
import 'package:conduit/features/chat/widgets/message_badge.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class _TestTextToSpeechController extends TextToSpeechController {
  @override
  TextToSpeechState build() => const TextToSpeechState();
}

Widget _buildHarness(
  ChatMessage message, {
  bool isStreaming = false,
  FutureOr<void> Function(String text)? onQuickReply,
  QuickReplyReaction? badge,
  Locale? locale,
}) {
  return ProviderScope(
    overrides: [
      textToSpeechControllerProvider.overrideWith(
        _TestTextToSpeechController.new,
      ),
      streamingHapticsEnabledProvider.overrideWithValue(false),
    ],
    child: MaterialApp(
      theme: AppTheme.light(TweakcnThemes.t3Chat),
      locale: locale,
      localizationsDelegates: conduitLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.only(top: 200),
          child: AssistantMessageWidget(
            message: message,
            isStreaming: isStreaming,
            showFollowUps: false,
            animateOnMount: false,
            modelName: 'Assistant',
            onCopy: () {},
            onDelete: () {},
            onQuickReply: onQuickReply,
            quickReplyBadge: badge,
          ),
        ),
      ),
    ),
  );
}

ChatMessage _reply({
  bool isStreaming = false,
  String content = 'Send the report?',
  ChatMessageError? error,
}) => ChatMessage(
  id: 'assistant-quick-reply',
  role: 'assistant',
  content: content,
  timestamp: DateTime.utc(2024, 1, 1),
  model: 'Assistant',
  isStreaming: isStreaming,
  error: error,
);

final _picker = find.byKey(const ValueKey('quick-reply-picker'));

/// Holds a press on the reply text past the picker's 400 ms threshold.
Future<void> _longPressReply(WidgetTester tester, String text) async {
  final gesture = await tester.startGesture(
    tester.getCenter(find.textContaining(text).first),
  );
  await tester.pump(const Duration(milliseconds: 450));
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('long-press opens the picker and a tap on a reaction sends it', (
    tester,
  ) async {
    final sent = <String>[];
    await tester.pumpWidget(
      _buildHarness(_reply(), onQuickReply: (text) => sent.add(text)),
    );
    await tester.pumpAndSettle();

    await _longPressReply(tester, 'Send the report?');
    check(_picker.evaluate()).length.equals(1);
    final pill = tester.getRect(_picker);
    final reply = tester.getRect(find.textContaining('Send the report?'));
    check(pill.bottom).isLessOrEqual(reply.top);

    await tester.tap(find.text('✅'));
    await tester.pumpAndSettle();

    check(sent).deepEquals(['Yes, do it.']);
    check(_picker.evaluate()).isEmpty();
  });

  testWidgets('a reaction is sent in the app language', (tester) async {
    final sent = <String>[];
    await tester.pumpWidget(
      _buildHarness(
        _reply(),
        onQuickReply: (text) => sent.add(text),
        locale: const Locale('de'),
      ),
    );
    await tester.pumpAndSettle();

    await _longPressReply(tester, 'Send the report?');
    await tester.tap(find.text('✅'));
    await tester.pumpAndSettle();

    check(sent).deepEquals(['Ja, mach das.']);
  });

  testWidgets('a tap outside the picker dismisses it without sending', (
    tester,
  ) async {
    final sent = <String>[];
    await tester.pumpWidget(
      _buildHarness(_reply(), onQuickReply: (text) => sent.add(text)),
    );
    await tester.pumpAndSettle();

    await _longPressReply(tester, 'Send the report?');
    check(_picker.evaluate()).length.equals(1);
    await tester.tapAt(const Offset(400, 590));
    await tester.pumpAndSettle();

    check(_picker.evaluate()).isEmpty();
    check(sent).isEmpty();
  });

  testWidgets('no picker while the reply streams', (tester) async {
    final sent = <String>[];
    await tester.pumpWidget(
      _buildHarness(
        _reply(isStreaming: true),
        isStreaming: true,
        onQuickReply: (text) => sent.add(text),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(AssistantMessageWidget)),
    );
    await tester.pump(const Duration(milliseconds: 450));
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 300));

    check(_picker.evaluate()).isEmpty();
    check(sent).isEmpty();
  });

  testWidgets('no picker on an error reply', (tester) async {
    await tester.pumpWidget(
      _buildHarness(
        _reply(
          content: 'Upstream refused',
          error: const ChatMessageError(content: '503 profile_switching'),
        ),
        onQuickReply: (_) {},
      ),
    );
    await tester.pumpAndSettle();

    await _longPressReply(tester, 'Upstream refused');
    check(_picker.evaluate()).isEmpty();
  });

  testWidgets('no picker when the setting turns the handler off', (
    tester,
  ) async {
    await tester.pumpWidget(_buildHarness(_reply()));
    await tester.pumpAndSettle();

    await _longPressReply(tester, 'Send the report?');
    check(_picker.evaluate()).isEmpty();
  });

  testWidgets('a reaction already sent sits on the reply as a badge', (
    tester,
  ) async {
    await tester.pumpWidget(
      _buildHarness(
        _reply(),
        onQuickReply: (_) {},
        badge: quickReplyReactions.first,
      ),
    );
    await tester.pumpAndSettle();

    final badge = tester.widget<MessageBadge>(find.byType(MessageBadge));
    check(badge.emoji).equals('\u{1F44D}');
    final badgeFinder = find.byKey(
      const ValueKey('assistant-quick-reply-badge'),
    );
    check(badgeFinder.evaluate()).length.equals(1);
    // Bottom-trailing corner, a third over the reply content and the rest
    // outside, in room reserved under and past it so nothing covers it.
    final anchor = tester.getRect(find.byType(MessageBadgeAnchor));
    final content = tester.getRect(
      find
          .descendant(
            of: find.byType(MessageBadgeAnchor),
            matching: find.byType(Column),
          )
          .first,
    );
    final badgeRect = tester.getRect(badgeFinder);
    check(badgeRect.left).equals(content.right - MessageBadge.overlap);
    check(badgeRect.top).equals(content.bottom - MessageBadge.overlap);
    check(badgeRect.bottom).equals(anchor.bottom);
    check(anchor.right).isGreaterOrEqual(content.right);
  });

  group('derivation', () {
    ChatMessage message(String id, String role, String content) => ChatMessage(
      id: id,
      role: role,
      content: content,
      timestamp: DateTime.utc(2024, 1, 1),
    );

    final messages = [
      message('u1', 'user', 'Lunch at a cafe'),
      message('a1', 'assistant', 'Send the report?'),
      message('u2', 'user', 'Yes'),
      message('a2', 'assistant', 'Saved.'),
      message('u3', 'user', 'No'),
    ];

    test('a reply answered with a reaction text carries its badge', () {
      check(quickReplyBadgeFor(messages, 'a1'))
          .identicalTo(quickReplyReactions.first);
      check(quickReplyBadgeFor(messages, 'a2')?.emoji).equals('\u{1F44E}');
    });

    test('only a reaction text right after a reply is a reaction turn', () {
      check(isQuickReplyTurn(messages, 0)).isFalse();
      check(isQuickReplyTurn(messages, 2)).isTrue();
      final typedNo = [
        message('u1', 'user', 'Hi'),
        message('u2', 'user', 'No'),
      ];
      check(isQuickReplyTurn(typedNo, 1)).isFalse();
      check(quickReplyReactionForText('yes')).isNull();
    });

    test('a reaction sent in any supported language carries its badge', () {
      final german = [
        message('a1', 'assistant', 'Send the report?'),
        message('u1', 'user', 'Ja, mach das.'),
      ];
      check(quickReplyBadgeFor(german, 'a1'))
          .equals(QuickReplyReaction.confirm);
      for (final locale in AppLocalizations.supportedLocales) {
        final l10n = lookupAppLocalizations(locale);
        for (final reaction in quickReplyReactions) {
          check(
            because: '$locale',
            quickReplyReactionForText(reaction.localizedText(l10n)),
          ).equals(reaction);
          // Chats from before the texts were translated keep their badges.
          check(quickReplyReactionForText(reaction.text)).equals(reaction);
        }
      }
    });

    test('the answers of a list are found once for every row', () {
      final answers = QuickReplyAnswers.of(messages);
      check(answers.answerFor('a1')?.reaction).equals(QuickReplyReaction.yes);
      check(answers.answerFor('a1')?.turnId).equals('u2');
      check(answers.answerFor('a2')?.reaction).equals(QuickReplyReaction.no);
      check(answers.answerFor('u1')).isNull();
      check(answers.isTurn('u2')).isTrue();
      check(answers.isTurn('u3')).isTrue();
      check(answers.isTurn('u1')).isFalse();
    });

    test('a reaction text with attachments or files stays a message', () {
      final withImage = [
        message('a1', 'assistant', 'Which file?'),
        message('u1', 'user', 'Yes').copyWith(attachmentIds: ['image-1']),
      ];
      final withFile = [
        message('a1', 'assistant', 'Which file?'),
        message('u1', 'user', 'Yes').copyWith(
          files: [
            {'type': 'file', 'id': 'file-1'},
          ],
        ),
      ];
      check(isQuickReplyTurn(withImage, 1)).isFalse();
      check(isQuickReplyTurn(withFile, 1)).isFalse();
      check(quickReplyBadgeFor(withImage, 'a1')).isNull();
      check(quickReplyBadgeFor(withFile, 'a1')).isNull();
    });
  });
}
