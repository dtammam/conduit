import 'package:checks/checks.dart';
import 'package:conduit/features/chat/avatar/assistant_action_log.dart';
import 'package:conduit/features/chat/widgets/context_usage_ring.dart';
import 'package:conduit/features/chat/views/chat_page.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/platform/flutter_key_value_store.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/adaptive_toolbar_components.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:conduit_core/database/chat_database_repository.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/automations/providers/automation_providers.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/tools/providers/tools_providers.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/folder.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/tool.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/connectivity_service.dart'
    show isOnlineProvider;
import 'package:conduit_core/services/optimized_storage_service.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _at = DateTime.utc(2024, 1, 1);

class _Conversations extends Conversations {
  @override
  Future<List<Conversation>> build() async => const <Conversation>[];
}

class _Models extends Models {
  @override
  Future<List<Model>> build() async => const [
    Model(id: 'model-1', name: 'Model 1'),
  ];
}

class _Folders extends Folders {
  @override
  Future<List<Folder>> build() async => const <Folder>[];
}

class _Tools extends ToolsList {
  @override
  Future<List<Tool>> build() async => const <Tool>[];
}

class _SelectedModel extends SelectedModel {
  @override
  Model? build() => const Model(id: 'model-1', name: 'Model 1');
}

class _Active extends ActiveConversationNotifier {
  _Active(this.initial);

  final Conversation? initial;

  @override
  Conversation? build() => initial;
}

class _Messages extends ChatMessagesNotifier {
  _Messages(this.initial);

  final List<ChatMessage> initial;

  @override
  List<ChatMessage> build() => initial;
}

class _Storage extends Fake implements OptimizedStorageService {
  @override
  Future<void> saveLocalDefaultModel(Model? model) async {}
}

class _Settings extends AppSettingsNotifier {
  _Settings({required this.showContextUsage, this.tooling = false});

  final bool showContextUsage;

  /// Both the avatar and the tool activity setting on.
  final bool tooling;

  @override
  AppSettings build() => AppSettings(
    showContextUsage: showContextUsage,
    assistantAvatarEnabled: tooling,
    toolActivityInAvatar: tooling,
  );
}

/// A log holding one failed call nobody has seen, so the avatar badge shows.
class _FailedLog extends AssistantActionLog {
  @override
  AssistantActionLogState build() => AssistantActionLogState(
    records: [
      AssistantActionRecord(
        id: 'call_1',
        chatId: 'chat',
        messageId: 'm1',
        toolName: 'create_event',
        arguments: '{}',
        result: 'Error: offline',
        status: AssistantActionStatus.failed,
        startedAt: DateTime.now(),
        finishedAt: DateTime.now(),
      ),
    ],
    failuresSeenAt: DateTime.now().subtract(const Duration(days: 1)),
  );
}

ApiService _api() => ApiService(
  serverConfig: const ServerConfig(
    id: 'page',
    name: 'page',
    url: 'https://page.example.test',
  ),
  workerManager: WorkerManager(),
);

Conversation _chat(List<ChatMessage> messages) => withChatStorageProvenance(
  Conversation(
    id: 'stored-chat',
    title: 'A chat',
    createdAt: _at,
    updatedAt: _at,
    messages: messages,
  ),
  ChatStorageKind.openWebUi,
);

final _messages = <ChatMessage>[
  ChatMessage(
    id: 'u1',
    role: 'user',
    content: 'hello',
    timestamp: _at,
    metadata: const {'parentId': null},
  ),
  ChatMessage(
    id: 'a1',
    role: 'assistant',
    content: 'hi',
    timestamp: _at,
    model: 'model-1',
    usage: const {'prompt_tokens': 1000, 'completion_tokens': 24},
    metadata: const {'parentId': 'u1', 'responseDone': true},
  ),
];

Future<void> pumpFrames(WidgetTester tester, [int frames = 6]) async {
  for (var frame = 0; frame < frames; frame++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PreferencesStore.debugReset();
    PreferencesStore.debugOverride(await FlutterKeyValueStore.load());
  });
  tearDown(PreferencesStore.debugReset);

  Future<void> mountPage(
    WidgetTester tester, {
    required List<ChatMessage> messages,
    bool showContextUsage = true,
    bool tooling = false,
  }) async {
    final originalErrorWidgetBuilder = ErrorWidget.builder;
    final originalFlutterErrorOnError = FlutterError.onError;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      ErrorWidget.builder = originalErrorWidgetBuilder;
      FlutterError.onError = originalFlutterErrorOnError;
    });
    final container = ProviderContainer(
      overrides: [
        appSettingsProvider.overrideWith(
          () => _Settings(
            showContextUsage: showContextUsage,
            tooling: tooling,
          ),
        ),
        if (tooling) assistantActionLogProvider.overrideWith(_FailedLog.new),
        if (tooling) automationsAvailableProvider.overrideWithValue(false),
        apiServiceProvider.overrideWithValue(_api()),
        appDatabaseProvider.overrideWith((ref) => null),
        isAuthenticatedProvider2.overrideWithValue(false),
        reviewerModeProvider.overrideWithValue(false),
        selectedModelProvider.overrideWith(_SelectedModel.new),
        activeConversationProvider.overrideWith(
          () => _Active(messages.isEmpty ? null : _chat(messages)),
        ),
        chatMessagesProvider.overrideWith(() => _Messages(messages)),
        optimizedStorageServiceProvider.overrideWithValue(_Storage()),
        isChatStreamingProvider.overrideWith((ref) => false),
        isOnlineProvider.overrideWithValue(true),
        conversationsProvider.overrideWith(_Conversations.new),
        modelsProvider.overrideWith(_Models.new),
        foldersProvider.overrideWith(_Folders.new),
        toolsListProvider.overrideWith(_Tools.new),
        currentUserProvider2.overrideWithValue(
          const User(
            id: 'me',
            username: 'me',
            email: 'me@example.test',
            role: 'user',
          ),
        ),
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
          home: const ChatPage(),
        ),
      ),
    );
    // A page with a transcript keeps scheduling frames, so it never settles.
    await pumpFrames(tester);
  }

  testWidgets('no ring on an empty chat', (tester) async {
    await mountPage(tester, messages: const []);
    expect(find.byType(ContextUsageRing), findsNothing);
  });

  testWidgets('no ring while the setting is off', (tester) async {
    await mountPage(tester, messages: _messages, showContextUsage: false);
    expect(find.byType(ContextUsageRing), findsNothing);
    expect(find.byType(ContextUsageRingButton), findsNothing);
  });

  testWidgets('the ring sits in the app bar without changing its height', (
    tester,
  ) async {
    await mountPage(tester, messages: _messages);
    final ring = find.descendant(
      of: find.byType(AppBar),
      matching: find.byType(ContextUsageRing),
    );
    // The bar keeps the shared toolbar height it has without the ring.
    final emptyHeight =
        MediaQuery.viewPaddingOf(tester.element(ring)).top +
        conduitAdaptiveToolbarHeightOf(tester.element(ring));
    expect(ring, findsOneWidget);
    check(tester.getSize(find.byType(AppBar)).height).equals(emptyHeight);
    // The ring's button is no taller than the bar's other controls.
    final button = find.byType(ContextUsageRingButton);
    check(tester.getSize(button).height)
        .isLessOrEqual(tester.getSize(find.byType(AppBar)).height);
  });

  for (final width in [375.0, 430.0]) {
    testWidgets('at $width points the ring leads: menu, ring, then the title, '
        'with the trailing gap and nothing overlapping', (tester) async {
      tester.view.physicalSize = Size(width, 812);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await mountPage(tester, messages: _messages);

      final menu = find.byKey(const ValueKey('chat-sidebar-toggle'));
      final button = find.byType(ContextUsageRingButton);
      final title = find.byType(ConduitAdaptiveAppBarModelSelector);
      final newChat = find.ancestor(
        of: find.descendant(
          of: find.byType(AppBar),
          matching: find.byIcon(Icons.add_comment),
        ),
        matching: find.byType(ConduitAdaptiveAppBarIconButton),
      );
      expect(menu, findsOneWidget);
      expect(title, findsOneWidget);
      expect(newChat, findsOneWidget);

      final menuRect = tester.getRect(menu);
      final ringRect = tester.getRect(button);
      final titleRect = tester.getRect(title);
      final newChatRect = tester.getRect(newChat);
      // Right after the menu button, the same gap the trailing buttons use.
      check(ringRect.left - menuRect.right).isCloseTo(Spacing.sm, 0.01);
      check(ringRect.center.dy).isCloseTo(menuRect.center.dy, 0.01);
      check(ringRect.size).equals(menuRect.size);
      // The leading model title follows the ring and never touches it.
      check(titleRect.left).isGreaterOrEqual(ringRect.right);
      check(ringRect.overlaps(titleRect)).isFalse();
      // The trailing side keeps only the toolbar actions.
      check(ringRect.right).isLessThan(newChatRect.left);
      expect(
        find.descendant(
          of: find.ancestor(of: newChat, matching: find.byType(Row)).first,
          matching: find.byType(ContextUsageRingButton),
        ),
        findsNothing,
      );
      // The leading group stays in the bar's leading half, clear of
      // anything centered in the title slot.
      check(ringRect.right).isLessThan(width / 2);
    });
  }

  testWidgets('the ring sits in the same circular button as its neighbors', (
    tester,
  ) async {
    await mountPage(tester, messages: _messages);
    final button = find.byType(ContextUsageRingButton);
    final newChat = find.ancestor(
      of: find.descendant(
        of: find.byType(AppBar),
        matching: find.byIcon(Icons.add_comment),
      ),
      matching: find.byType(ConduitAdaptiveAppBarIconButton),
    );
    expect(newChat, findsOneWidget);

    FloatingAppBarPill pillOf(Finder of) => tester.widget<FloatingAppBarPill>(
      find.descendant(of: of, matching: find.byType(FloatingAppBarPill)),
    );
    check(pillOf(newChat).isCircular).isTrue();
    check(pillOf(button).isCircular).isTrue();
    check(tester.getSize(button)).equals(tester.getSize(newChat));
    check(tester.getCenter(button).dy).equals(tester.getCenter(newChat).dy);
    // The ring is drawn inside the circle, smaller than it, like an icon.
    final ring = find.byType(ContextUsageRing);
    check(tester.getSize(ring).width).isLessThan(tester.getSize(button).width);
    check(tester.getCenter(ring)).equals(tester.getCenter(button));
  });

  testWidgets('with the avatar and its badge on, the ring stays put and works', (
    tester,
  ) async {
    await mountPage(tester, messages: _messages, tooling: true);

    final badge = find.byKey(const ValueKey('assistant-avatar-badge-failed'));
    final circle = find.byKey(const ValueKey('assistant-avatar-circle'));
    final button = find.byType(ContextUsageRingButton);
    expect(badge, findsOneWidget);
    expect(button, findsOneWidget);
    expect(find.byType(ContextUsageRing), findsOneWidget);
    // The ring keeps its place beside the menu and clear of the avatar.
    final menu = tester.getRect(
      find.byKey(const ValueKey('chat-sidebar-toggle')),
    );
    final ringRect = tester.getRect(button);
    check(ringRect.left - menu.right).isCloseTo(Spacing.sm, 0.01);
    check(ringRect.overlaps(tester.getRect(circle))).isFalse();
    check(ringRect.overlaps(tester.getRect(badge))).isFalse();

    await tester.tap(button);
    await pumpFrames(tester, 4);
    expect(find.byType(ContextUsageSheetContent), findsOneWidget);
  });

  testWidgets('tapping the ring opens the context sheet', (tester) async {
    await mountPage(tester, messages: _messages);
    await tester.tap(find.byType(ContextUsageRingButton));
    await pumpFrames(tester, 4);
    expect(find.byType(ContextUsageSheetContent), findsOneWidget);
  });
}
