import 'package:checks/checks.dart';
import 'package:conduit/features/chat/providers/text_to_speech_provider.dart';
import 'package:conduit/features/chat/widgets/assistant_message_widget.dart';
import 'package:conduit/features/chat/widgets/reply_to_bar.dart';
import 'package:conduit/features/chat/widgets/user_message_bubble.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit_core/features/chat/reply/reply_to.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../../helpers/message_menu.dart';

class _Tts extends TextToSpeechController {
  _Tts(this.spoken);
  final List<(String, String)> spoken;

  @override
  TextToSpeechState build() =>
      const TextToSpeechState(initialized: true, available: true);

  @override
  Future<void> toggleForMessage({
    required String messageId,
    required String text,
  }) async {
    spoken.add((messageId, text));
  }
}

class _ImmediateWorkerManager extends WorkerManager {
  _ImmediateWorkerManager() : super(maxConcurrentTasks: 1);

  @override
  Future<R> schedule<Q, R>(
    WorkerTask<Q, R> callback,
    Q message, {
    String? debugLabel,
  }) => Future<R>.value(callback(message));
}

ChatMessage _assistant(String id, String content) => ChatMessage(
  id: id,
  role: 'assistant',
  content: content,
  timestamp: DateTime.utc(2024, 1, 1),
  model: 'Assistant',
  metadata: const {'responseDone': true},
);

Widget _app(
  List<Widget> children, {
  List<(String, String)>? spoken,
  List<Override> overrides = const [],
}) => ProviderScope(
  overrides: [
    textToSpeechControllerProvider.overrideWith(
      () => _Tts(spoken ?? <(String, String)>[]),
    ),
    workerManagerProvider.overrideWithValue(_ImmediateWorkerManager()),
    streamingHapticsEnabledProvider.overrideWithValue(false),
    ...overrides,
  ],
  child: MaterialApp(
    theme: AppTheme.light(TweakcnThemes.t3Chat),
    localizationsDelegates: conduitLocalizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: SingleChildScrollView(child: Column(children: children)),
    ),
  ),
);

AssistantMessageWidget _row(
  ChatMessage message, {
  List<String>? copied,
  void Function(String, String)? onReply,
  void Function(String)? onQuickReply,
}) => AssistantMessageWidget(
  message: message,
  showFollowUps: false,
  animateOnMount: false,
  modelName: 'Assistant',
  onCopy: () => copied?.add(message.content),
  onRegenerate: () {},
  onDelete: () {},
  onReply: onReply,
  onQuickReply: onQuickReply,
);

void main() {
  testWidgets('the menu has the reactions on top and the actions under them', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app([_row(_assistant('a1', 'Send the report?'), onQuickReply: (_) {})]),
    );
    await tester.pumpAndSettle();
    await openMessageMenu(tester);

    final reactions = tester.getRect(
      find.byKey(const ValueKey('quick-reply-picker')),
    );
    final actions = tester.getRect(
      find.byKey(const ValueKey('message-menu-actions')),
    );
    check(reactions.bottom).isLessOrEqual(actions.top);
    for (final id in ['copy', 'tts', 'share', 'more']) {
      check(menuAction(id).evaluate()).length.equals(1);
    }
    // No Reply without a handler, and nothing else on the first row.
    check(menuAction('reply').evaluate()).isEmpty();
    check(menuAction('regenerate').evaluate()).isEmpty();
  });

  testWidgets('no action bar under the reply', (tester) async {
    await tester.pumpWidget(_app([_row(_assistant('a1', 'Hello there'))]));
    await tester.pumpAndSettle();
    check(find.byIcon(Icons.content_copy_outlined).evaluate()).isEmpty();
    check(find.byIcon(Icons.refresh).evaluate()).isEmpty();
  });

  testWidgets('Copy, Listen and Reply act on the pressed row only', (
    tester,
  ) async {
    final copied = <String>[];
    final spoken = <(String, String)>[];
    final replies = <(String, String)>[];
    await tester.pumpWidget(
      _app([
        _row(
          _assistant('a1', 'First part.'),
          copied: copied,
          onReply: (id, text) => replies.add((id, text)),
        ),
        _row(
          _assistant('a2', 'Second part.'),
          copied: copied,
          onReply: (id, text) => replies.add((id, text)),
        ),
      ], spoken: spoken),
    );
    await tester.pumpAndSettle();
    final first = find.textContaining('First part.');

    await chooseFromMessageMenu(tester, 'copy', on: first);
    check(copied).deepEquals(['First part.']);

    await chooseFromMessageMenu(tester, 'tts', on: first);
    check(spoken.map((s) => s.$1)).deepEquals(['a1']);
    check(spoken.single.$2).contains('First part.');
    check(spoken.single.$2).not((it) => it.contains('Second part.'));

    await chooseFromMessageMenu(tester, 'reply', on: first);
    check(replies).deepEquals([('a1', 'First part.')]);
    check(menuAction('copy').evaluate()).isEmpty();
  });

  testWidgets('More holds the rest and a tap outside closes the menu', (
    tester,
  ) async {
    await tester.pumpWidget(_app([_row(_assistant('a1', 'Hello there'))]));
    await tester.pumpAndSettle();
    await openMessageMenu(tester);
    await tester.tap(menuAction('more'));
    await tester.pumpAndSettle();
    check(menuAction('regenerate').evaluate()).length.equals(1);
    check(menuAction('delete').evaluate()).length.equals(1);

    await tester.tapAt(const Offset(2, 2));
    await tester.pumpAndSettle();
    check(menuAction('delete').evaluate()).isEmpty();
  });

  testWidgets('a user message has Reply, Copy, Listen, Share and More', (
    tester,
  ) async {
    final replies = <(String, String)>[];
    await tester.pumpWidget(
      _app([
        UserMessageBubble(
          message: ChatMessage(
            id: 'u1',
            role: 'user',
            content: 'Book lunch',
            timestamp: DateTime.utc(2024, 1, 1),
          ),
          isUser: true,
          onDelete: () {},
          onCopy: () {},
          onReply: (id, text) => replies.add((id, text)),
        ),
      ]),
    );
    await tester.pumpAndSettle();
    await openMessageMenu(tester);
    // No reactions on your own message.
    check(find.byKey(const ValueKey('quick-reply-picker')).evaluate())
        .isEmpty();
    for (final id in ['reply', 'copy', 'tts', 'share', 'more']) {
      check(menuAction(id).evaluate()).length.equals(1);
    }
    await tester.tap(menuAction('more'));
    await tester.pumpAndSettle();
    check(menuAction('edit').evaluate()).length.equals(1);
    check(menuAction('delete').evaluate()).length.equals(1);
  });

  testWidgets('a user message that starts with a quote shows it as a quote', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app([
        UserMessageBubble(
          message: ChatMessage(
            id: 'u1',
            role: 'user',
            content: composeReplyText('Is it done?', 'Yes, ship it'),
            timestamp: DateTime.utc(2024, 1, 1),
          ),
          isUser: true,
          onDelete: () {},
        ),
      ]),
    );
    await tester.pumpAndSettle();
    check(find.byKey(const ValueKey('user-message-quote')).evaluate()).length
        .equals(1);
    check(find.text('Is it done?').evaluate()).length.equals(1);
    check(find.text('Yes, ship it').evaluate()).length.equals(1);
    check(find.textContaining('> ').evaluate()).isEmpty();
  });

  group('reply bar', () {
    testWidgets('shows the first line, and the X cancels', (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.light(TweakcnThemes.t3Chat),
            localizationsDelegates: conduitLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const Scaffold(body: ReplyToBar()),
          ),
        ),
      );
      check(find.byKey(const ValueKey('reply-to-bar')).evaluate()).isEmpty();

      container
          .read(replyTargetProvider.notifier)
          .set('a1', '**Title**\nSecond line');
      await tester.pump();
      check(find.text('**Title**').evaluate()).length.equals(1);
      check(find.text('Second line').evaluate()).isEmpty();

      await tester.tap(find.byKey(const ValueKey('reply-to-cancel')));
      await tester.pump();
      check(container.read(replyTargetProvider)).isNull();
      check(find.byKey(const ValueKey('reply-to-bar')).evaluate()).isEmpty();
    });
  });
}
