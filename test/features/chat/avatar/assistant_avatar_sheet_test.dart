import 'package:checks/checks.dart';
import 'package:conduit/features/chat/avatar/assistant_action_log.dart';
import 'package:conduit/features/chat/avatar/assistant_avatar_media.dart';
import 'package:conduit/features/chat/avatar/assistant_avatar_strip.dart';
import 'package:conduit/features/chat/avatar/assistant_pending_approval.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit_core/features/automations/providers/automation_providers.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/openwebui_chat_prompt.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class _Messages extends ChatMessagesNotifier {
  _Messages([this.initial = const []]);

  final List<ChatMessage> initial;

  @override
  List<ChatMessage> build() => initial;

  void replace(List<ChatMessage> messages) => state = messages;
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

class _SeededLog extends AssistantActionLog {
  _SeededLog(this.seed);

  final List<AssistantActionRecord> seed;

  @override
  AssistantActionLogState build() => AssistantActionLogState(
    records: seed,
    failuresSeenAt: DateTime.now().subtract(const Duration(days: 1)),
  );
}

class _FakeStore extends AssistantAvatarMediaStore {
  @override
  Future<AssistantAvatarMediaSet> load({String? personaId}) async =>
      AssistantAvatarMediaSet.empty;
}

AssistantActionRecord _call(
  String id, {
  String message = 'm1',
  String tool = 'web_search',
  bool failed = false,
  String result = 'Found a cafe',
  DateTime? at,
}) {
  final time = at ?? DateTime.now();
  return AssistantActionRecord(
    id: id,
    chatId: 'chat',
    messageId: message,
    toolName: tool,
    arguments: '{"query": "cafe"}',
    result: result,
    status: failed
        ? AssistantActionStatus.failed
        : AssistantActionStatus.succeeded,
    startedAt: time,
    finishedAt: time,
  );
}

const _toolApproval = AssistantApproval(
  conversationId: 'chat',
  prompt: OpenWebUiComposerPrompt(
    identity: 'saved:m1:c1',
    kind: OpenWebUiComposerPromptKind.toolApproval,
    title: 'create_event',
    message: '{"title": "Lunch at a cafe"}',
  ),
);

const _question = AssistantApproval(
  conversationId: 'chat',
  prompt: OpenWebUiComposerPrompt(
    identity: 'saved:m1:c2',
    kind: OpenWebUiComposerPromptKind.askUser,
    questions: [
      OpenWebUiPromptQuestion(
        id: 'q',
        header: 'Which cafe?',
        question: 'Pick a place for lunch.',
        options: [
          OpenWebUiPromptOption(label: 'A', description: 'First'),
          OpenWebUiPromptOption(label: 'B', description: 'Second'),
        ],
        allowOther: false,
      ),
    ],
  ),
);

void main() {
  late ProviderContainer container;

  Future<void> mount(
    WidgetTester tester, {
    List<AssistantActionRecord> records = const [],
    AssistantApproval? approval,
    bool upcoming = false,
  }) async {
    final overrides = <Override>[
      chatMessagesProvider.overrideWith(_Messages.new),
      activeConversationProvider.overrideWith(_Active.new),
      assistantActionLogProvider.overrideWith(() => _SeededLog(records)),
      assistantApprovalProvider.overrideWithValue(approval),
      automationsAvailableProvider.overrideWithValue(upcoming),
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
            body: Align(
              alignment: Alignment.topCenter,
              child: AssistantAvatarStrip(
                modelName: 'Assistant',
                mediaStore: _FakeStore(),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> openSheet(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('assistant-avatar-circle')));
    await tester.pumpAndSettle();
  }

  final failedBadge = find.byKey(
    const ValueKey('assistant-avatar-badge-failed'),
  );
  final approvalBadge = find.byKey(
    const ValueKey('assistant-avatar-badge-approval'),
  );

  group('badge', () {
    testWidgets('a red count of failures not yet seen', (tester) async {
      await mount(
        tester,
        records: [
          _call('a', failed: true, result: 'Error: offline'),
          _call('b', failed: true, result: 'Error: offline'),
          _call('c'),
        ],
      );

      check(failedBadge.evaluate()).length.equals(1);
      check(
        find.descendant(of: failedBadge, matching: find.text('2')).evaluate(),
      ).length.equals(1);
      check(approvalBadge.evaluate()).isEmpty();
    });

    testWidgets('an amber mark while a prompt waits and nothing failed', (
      tester,
    ) async {
      await mount(tester, records: [_call('a')], approval: _toolApproval);

      check(failedBadge.evaluate()).isEmpty();
      check(approvalBadge.evaluate()).length.equals(1);
    });

    testWidgets('failures win over a waiting prompt', (tester) async {
      await mount(
        tester,
        records: [_call('a', failed: true, result: 'Error: offline')],
        approval: _toolApproval,
      );

      check(failedBadge.evaluate()).length.equals(1);
      check(approvalBadge.evaluate()).isEmpty();
    });

    testWidgets('no badge when nothing failed and nothing waits', (
      tester,
    ) async {
      await mount(tester, records: [_call('a')]);

      check(failedBadge.evaluate()).isEmpty();
      check(approvalBadge.evaluate()).isEmpty();
    });

    testWidgets('viewing the Activity tab marks the failures seen', (
      tester,
    ) async {
      await mount(
        tester,
        records: [_call('a', failed: true, result: 'Error: offline')],
      );
      check(failedBadge.evaluate()).length.equals(1);

      await openSheet(tester);

      // The sheet opens on Activity and keeps the count on its label.
      check(container.read(assistantActionLogProvider).unseenFailures)
          .equals(0);
      check(failedBadge.evaluate()).isEmpty();
      check(
        find
            .byKey(const ValueKey('assistant-sheet-tab-count-Activity'))
            .evaluate(),
      ).length.equals(1);
    });
  });

  group('tabs', () {
    testWidgets('opens on Activity with the calls newest first', (
      tester,
    ) async {
      final now = DateTime.now();
      await mount(
        tester,
        records: [
          _call('new', tool: 'create_event', at: now),
          _call('old', at: now.subtract(const Duration(minutes: 5))),
        ],
      );
      await openSheet(tester);

      check(find.text('Today').evaluate()).length.equals(1);
      final newer = tester.getTopLeft(find.text('Create event'));
      final older = tester.getTopLeft(find.text('Web search'));
      check(newer.dy).isLessThan(older.dy);
      check(find.textContaining('create_event', findRichText: true).evaluate())
          .length
          .equals(1);
      check(find.text('Found a cafe').evaluate()).length.equals(2);
    });

    testWidgets('a row expands to the arguments and the result', (
      tester,
    ) async {
      await mount(tester, records: [_call('a')]);
      await openSheet(tester);
      check(find.text('ARGUMENTS').evaluate()).isEmpty();

      await tester.tap(find.text('Web search'));
      await tester.pumpAndSettle();

      check(find.text('ARGUMENTS').evaluate()).length.equals(1);
      check(find.text('RESULT').evaluate()).length.equals(1);
      check(find.textContaining('"query": "cafe"').evaluate()).length.equals(1);
      check(find.text('Open in chat').evaluate()).length.equals(1);
    });

    testWidgets('an empty log says so', (tester) async {
      await mount(tester);
      await openSheet(tester);

      check(find.text('No tool calls yet').evaluate()).length.equals(1);
    });

    testWidgets('Clear asks first, then empties the log', (tester) async {
      await mount(tester, records: [_call('a')]);
      await openSheet(tester);

      await tester.tap(find.byKey(const ValueKey('assistant-activity-clear')));
      await tester.pumpAndSettle();
      check(find.text('Clear tool activity?').evaluate()).length.equals(1);
      check(container.read(assistantActionLogProvider).records).isNotEmpty();

      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Clear'),
        ),
      );
      await tester.pumpAndSettle();
      check(container.read(assistantActionLogProvider).records).isEmpty();
    });

    testWidgets('Approvals says nothing waits', (tester) async {
      await mount(tester);
      await openSheet(tester);
      await tester.tap(find.text('Approvals'));
      await tester.pumpAndSettle();

      check(find.text('Nothing waiting for you').evaluate()).length.equals(1);
    });

    testWidgets('opens on Approvals while a tool prompt waits', (tester) async {
      await mount(tester, approval: _toolApproval);
      await openSheet(tester);

      check(find.byKey(const ValueKey('assistant-approval-card')).evaluate())
          .length
          .equals(1);
      check(find.text('create_event').evaluate()).isNotEmpty();
      check(find.byKey(const ValueKey('assistant-approval-approve')).evaluate())
          .length
          .equals(1);
      check(find.byKey(const ValueKey('assistant-approval-deny')).evaluate())
          .length
          .equals(1);
      check(
        find
            .byKey(const ValueKey('assistant-sheet-tab-count-Approvals'))
            .evaluate(),
      ).length.equals(1);
    });

    testWidgets('a question is answered in the chat', (tester) async {
      await mount(tester, approval: _question);
      await openSheet(tester);

      check(find.text('Which cafe?').evaluate()).length.equals(1);
      check(find.byKey(const ValueKey('assistant-approval-approve')).evaluate())
          .isEmpty();
      await tester.tap(
        find.byKey(const ValueKey('assistant-approval-answer-in-chat')),
      );
      await tester.pumpAndSettle();

      check(find.byKey(const ValueKey('assistant-sheet-tabs')).evaluate())
          .isEmpty();
    });

    testWidgets('Upcoming is hidden when automations are unavailable', (
      tester,
    ) async {
      await mount(tester);
      await openSheet(tester);

      check(find.text('Upcoming').evaluate()).isEmpty();
      check(find.text('Appearance').evaluate()).length.equals(1);
    });

    testWidgets('Upcoming shows when automations are available', (
      tester,
    ) async {
      await mount(tester, upcoming: true);
      await openSheet(tester);

      check(find.text('Upcoming').evaluate()).length.equals(1);
    });

    testWidgets('the sheet and the tab control keep their place across tabs', (
      tester,
    ) async {
      await mount(tester, upcoming: true, records: [_call('a')]);
      await openSheet(tester);

      final tabs = find.byKey(const ValueKey('assistant-sheet-tabs'));
      final avatar = find.byKey(const ValueKey('assistant-sheet-avatar'));
      final sheet = find.byKey(const ValueKey('assistant-sheet-body'));
      final tabsAt = tester.getRect(tabs);
      final avatarAt = tester.getRect(avatar);
      final sheetAt = tester.getRect(sheet);
      check(sheetAt.height).isGreaterThan(
        tester.view.physicalSize.height / tester.view.devicePixelRatio * 0.8,
      );

      for (final label in const [
        'Approvals',
        'Upcoming',
        'Appearance',
        'Activity',
      ]) {
        await tester.tap(find.descendant(of: tabs, matching: find.text(label)));
        await tester.pumpAndSettle();
        check(tester.getRect(tabs)).equals(tabsAt);
        check(tester.getRect(avatar)).equals(avatarAt);
        check(tester.getRect(sheet)).equals(sheetAt);
      }
    });

    testWidgets('a row puts the time and raw name under the preview', (
      tester,
    ) async {
      await mount(
        tester,
        records: [
          _call(
            'a',
            tool: 'calendar-mcp_event_create',
            result: '[{"type": "input_text", "text": "Created"}]',
          ),
        ],
      );
      await openSheet(tester);

      check(find.text('Event create').evaluate()).length.equals(1);
      check(find.text('Created').evaluate()).length.equals(1);
      check(
        find
            .textContaining('calendar-mcp_event_create', findRichText: true)
            .evaluate(),
      ).length.equals(1);
    });

    testWidgets('Appearance keeps the four state rows', (tester) async {
      await mount(tester);
      await openSheet(tester);
      await tester.tap(find.text('Appearance'));
      await tester.pumpAndSettle();

      for (final state in const ['idle', 'working', 'making', 'done']) {
        check(find.byKey(ValueKey('assistant-avatar-row-$state')).evaluate())
            .length
            .equals(1);
      }
    });
  });

  group('turn filter', () {
    testWidgets('shows only the replies asked for and clears on the chip', (
      tester,
    ) async {
      await mount(
        tester,
        records: [
          _call('a', message: 'm1', tool: 'create_event'),
          _call('b', message: 'm2'),
        ],
      );
      container
          .read(assistantSheetRequestProvider.notifier)
          .open(messageIds: {'m1'});
      await tester.pumpAndSettle();

      check(find.text('From this reply').evaluate()).length.equals(1);
      check(find.text('Create event').evaluate()).length.equals(1);
      check(find.text('Web search').evaluate()).isEmpty();

      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('assistant-activity-filter')),
          matching: find.byType(Icon),
        ),
      );
      await tester.pumpAndSettle();

      check(find.text('From this reply').evaluate()).isEmpty();
      check(find.text('Web search').evaluate()).length.equals(1);
    });
  });

  group('recording', () {
    final at = DateTime.now().subtract(const Duration(minutes: 1));

    ChatMessage reply(String content, {required bool streaming}) => ChatMessage(
      id: 'm1',
      role: 'assistant',
      content: content,
      timestamp: at,
      isStreaming: streaming,
    );

    testWidgets('a reply is recorded once, when it stops streaming', (
      tester,
    ) async {
      final messages = _Messages([
        ChatMessage(id: 'u', role: 'user', content: 'Book it', timestamp: at),
        reply('', streaming: true),
      ]);
      container = ProviderContainer(
        overrides: [
          chatMessagesProvider.overrideWith(() => messages),
          activeConversationProvider.overrideWith(_Active.new),
          automationsAvailableProvider.overrideWithValue(false),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.light(TweakcnThemes.t3Chat),
            localizationsDelegates: conduitLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: AssistantAvatarStrip(
                modelName: 'Assistant',
                mediaStore: _FakeStore(),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      const running =
          '<details type="tool_calls" done="false" id="call_1" '
          'name="create_event">\n<summary>Executing...</summary>\n';
      messages.replace([messages.state.first, reply(running, streaming: true)]);
      await tester.pump();
      check(container.read(assistantActionLogProvider).records).isEmpty();

      const done =
          '<details type="tool_calls" done="true" id="call_1" '
          'name="create_event" result="&quot;Error: offline&quot;">\n'
          '<summary>Tool Executed</summary>\n</details>\nSorry.';
      messages.replace([messages.state.first, reply(done, streaming: false)]);
      await tester.pump();
      await tester.pump();

      final records = container.read(assistantActionLogProvider).records;
      check(records.length).equals(1);
      check(records.single.id).equals('call_1');
      check(records.single.chatId).equals('chat');
      check(records.single.failed).isTrue();
      // The start is when the call was first seen running, not the reply's
      // timestamp.
      check(records.single.startedAt.isAfter(at)).isTrue();

      // The same reply again records nothing new.
      messages.replace([messages.state.first, reply(done, streaming: false)]);
      await tester.pump();
      check(container.read(assistantActionLogProvider).records.length)
          .equals(1);
    });
  });
}
