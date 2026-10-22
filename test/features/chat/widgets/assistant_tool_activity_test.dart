import 'package:checks/checks.dart';
import 'package:conduit/features/chat/avatar/assistant_action_log.dart';
import 'package:conduit/features/chat/providers/text_to_speech_provider.dart';
import 'package:conduit/features/chat/widgets/assistant_message_widget.dart';
import 'package:conduit/features/chat/widgets/streaming_status_widget.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _twoCalls = '''
<details type="tool_calls" done="true" id="call_1" name="web_search" result="&quot;Found a cafe&quot;">
<summary>Tool Executed</summary>
</details>
<details type="tool_calls" done="true" id="call_2" name="create_event" result="&quot;Error: calendar offline&quot;">
<summary>Tool Executed</summary>
</details>
Lunch is not booked.
''';

const _oneFailure = '''
<details type="tool_calls" done="true" id="call_2" name="create_event" result="&quot;Error: calendar offline&quot;">
<summary>Tool Executed</summary>
</details>
Lunch is not booked.
''';

const _noFailure = '''
<details type="tool_calls" done="true" id="call_1" name="web_search" result="&quot;Found a cafe&quot;">
<summary>Tool Executed</summary>
</details>
Found one.
''';

class _Messages extends ChatMessagesNotifier {
  _Messages(this.initial);

  final List<ChatMessage> initial;

  @override
  List<ChatMessage> build() => initial;
}

class _Active extends ActiveConversationNotifier {
  @override
  Conversation? build() => Conversation(
    id: 'chat',
    title: 'Chat',
    createdAt: DateTime(2024, 1, 1),
    updatedAt: DateTime(2024, 1, 1),
  );
}

class _Settings extends AppSettingsNotifier {
  _Settings(this.value);

  final AppSettings value;

  @override
  AppSettings build() => value;
}

class _SeededLog extends AssistantActionLog {
  _SeededLog(this.seed);

  final List<AssistantActionRecord> seed;

  @override
  AssistantActionLogState build() =>
      AssistantActionLogState(records: seed, failuresSeenAt: DateTime.now());
}

class _Tts extends TextToSpeechController {
  @override
  TextToSpeechState build() => const TextToSpeechState();
}

AssistantActionRecord _record(
  String id,
  String messageId, {
  bool failed = false,
}) => AssistantActionRecord(
  id: id,
  chatId: 'chat',
  messageId: messageId,
  toolName: 'create_event',
  arguments: '{}',
  result: failed ? 'Error: calendar offline' : 'ok',
  status: failed
      ? AssistantActionStatus.failed
      : AssistantActionStatus.succeeded,
  startedAt: DateTime.now(),
  finishedAt: DateTime.now(),
);

ChatMessage _reply(String id, String content) => ChatMessage(
  id: id,
  role: 'assistant',
  content: content,
  timestamp: DateTime(2024, 1, 1),
);

void main() {
  late ProviderContainer container;

  Future<void> mount(
    WidgetTester tester, {
    required List<ChatMessage> transcript,
    required ChatMessage message,
    bool active = true,
    List<AssistantActionRecord> records = const [],
  }) async {
    final overrides = <Override>[
      textToSpeechControllerProvider.overrideWith(_Tts.new),
      streamingHapticsEnabledProvider.overrideWithValue(false),
      chatMessagesProvider.overrideWith(() => _Messages(transcript)),
      activeConversationProvider.overrideWith(_Active.new),
      chatForkAvailabilityProvider.overrideWithValue(
        ChatForkAvailability.hidden,
      ),
      assistantActionLogProvider.overrideWith(() => _SeededLog(records)),
      appSettingsProvider.overrideWith(
        () => _Settings(
          AppSettings(
            assistantAvatarEnabled: active,
            toolActivityInAvatar: active,
          ),
        ),
      ),
    ];
    container = ProviderContainer(overrides: overrides);
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(TweakcnThemes.t3Chat),
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: AssistantMessageWidget(
              message: message,
              isStreaming: false,
              showFollowUps: false,
              animateOnMount: false,
              modelName: 'Assistant',
              onCopy: () {},
              onRegenerate: () {},
              onDelete: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  final failureLine = find.byKey(
    const ValueKey<String>('assistant-tool-failure-line'),
  );

  group('failure line', () {
    testWidgets('one failed call names the tool and the reason', (
      tester,
    ) async {
      final message = _reply('m1', _oneFailure);
      await mount(tester, transcript: [message], message: message);

      check(failureLine.evaluate()).length.equals(1);
      check(
        find
            .text("Couldn't finish Create event: Error: calendar offline")
            .evaluate(),
      ).length.equals(1);
      check(find.text('Lunch is not booked.').evaluate()).length.equals(1);
    });

    testWidgets('several calls make one line, not one each', (tester) async {
      final message = _reply(
        'm1',
        _twoCalls.replaceFirst('Found a cafe', 'Error: offline'),
      );
      await mount(tester, transcript: [message], message: message);

      check(failureLine.evaluate()).length.equals(1);
      check(find.text("Couldn't finish 2 actions").evaluate()).length.equals(1);
    });

    testWidgets('tapping it opens the sheet filtered to this message', (
      tester,
    ) async {
      final message = _reply('m1', _oneFailure);
      await mount(tester, transcript: [message], message: message);

      await tester.tap(failureLine);
      await tester.pump();

      final request = container.read(assistantSheetRequestProvider);
      check(request).isNotNull();
      check(request!.tab).equals(AssistantSheetTab.activity);
      check(request.messageIds).isNotNull().deepEquals({'m1'});
    });

    testWidgets('a reply with no failure has no line', (tester) async {
      final message = _reply('m1', _noFailure);
      await mount(tester, transcript: [message], message: message);

      check(failureLine.evaluate()).isEmpty();
    });

    testWidgets('with the setting off there is no line', (tester) async {
      final message = _reply('m1', _oneFailure);
      await mount(
        tester,
        transcript: [message],
        message: message,
        active: false,
      );

      check(failureLine.evaluate()).isEmpty();
    });
  });

  group('View actions', () {
    Future<void> openMenu(WidgetTester tester) async {
      await tester.tap(find.byIcon(Icons.more_horiz_rounded));
      await tester.pumpAndSettle();
    }

    testWidgets('counts the calls of the turn and the failed ones', (
      tester,
    ) async {
      final earlier = _reply('a1', _noFailure);
      final message = _reply('a2', _oneFailure);
      final transcript = [
        ChatMessage(
          id: 'u1',
          role: 'user',
          content: 'Book lunch',
          timestamp: DateTime(2024, 1, 1),
        ),
        earlier,
        ChatMessage(
          id: 'q1',
          role: 'user',
          content: 'Yes, do it.',
          timestamp: DateTime(2024, 1, 1),
        ),
        message,
      ];
      await mount(
        tester,
        transcript: transcript,
        message: message,
        records: [
          _record('c1', 'a1'),
          _record('c2', 'a2', failed: true),
          _record('c3', 'unrelated'),
        ],
      );

      await openMenu(tester);

      check(find.text('View actions').evaluate()).length.equals(1);

      await tester.tap(find.text('View actions'));
      await tester.pumpAndSettle();
      final request = container.read(assistantSheetRequestProvider);
      check(request!.messageIds).isNotNull().deepEquals({'a1', 'a2'});
    });

    testWidgets('is absent when the log has nothing for the turn', (
      tester,
    ) async {
      final message = _reply('m1', _noFailure);
      await mount(
        tester,
        transcript: [message],
        message: message,
        records: [_record('c1', 'elsewhere')],
      );

      await openMenu(tester);

      check(find.text('View actions').evaluate()).isEmpty();
    });

    testWidgets('is absent with the setting off', (tester) async {
      final message = _reply('m1', _noFailure);
      await mount(
        tester,
        transcript: [message],
        message: message,
        active: false,
        records: [_record('c1', 'm1')],
      );

      await openMenu(tester);

      check(find.text('View actions').evaluate()).isEmpty();
    });
  });

  testWidgets('Hermes tool steps leave the status timeline', (tester) async {
    const updates = [
      ChatStatusUpdate(
        action: 'hermes_tool_web_search',
        description: 'web_search',
        done: true,
      ),
      ChatStatusUpdate(
        action: 'hermes_tool_create_event',
        description: 'create_event',
        done: true,
      ),
    ];
    Widget harness({required bool hide}) => MaterialApp(
      theme: AppTheme.light(TweakcnThemes.t3Chat),
      localizationsDelegates: conduitLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: StreamingStatusWidget(
          updates: updates,
          isStreaming: false,
          hideToolSteps: hide,
        ),
      ),
    );

    await tester.pumpWidget(harness(hide: false));
    check(find.textContaining('web_search').evaluate()).isNotEmpty();

    await tester.pumpWidget(harness(hide: true));
    check(find.textContaining('web_search').evaluate()).isEmpty();
    check(find.byType(SizedBox).evaluate()).isNotEmpty();
  });
}
