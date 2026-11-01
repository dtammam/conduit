import 'package:checks/checks.dart';
import 'package:conduit/features/chat/views/chat_page.dart';
import 'package:conduit/features/chat/widgets/chat_timeline_viewport.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/chat_database_repository.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit_core/features/tools/providers/tools_providers.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/folder.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/server_user_settings.dart';
import 'package:conduit_core/models/tool.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/connectivity_service.dart'
    show isOnlineProvider;
import 'package:conduit_core/services/optimized_storage_service.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_core/sync/sync_engine.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// iMessage-style scrolling: a send animates to the bottom (no pin to the top,
/// no blank space), streaming stays pinned near the bottom, and a reader who
/// scrolled up is left alone.
void main() {
  final at = DateTime.utc(2024, 1, 1);

  ChatMessage user(String id, String content, {String? parent}) => ChatMessage(
    id: id,
    role: 'user',
    content: content,
    timestamp: at,
    model: 'alpha',
    metadata: {
      'parentId': ?parent,
      'models': ['alpha'],
    },
  );

  ChatMessage assistant(String id, String content, {required String parent}) =>
      ChatMessage(
        id: id,
        role: 'assistant',
        content: content,
        timestamp: at,
        model: 'alpha',
        metadata: {'parentId': parent, 'responseDone': true},
      );

  final longAnswer = List.filled(
    30,
    'A paragraph of the earlier answer that fills the screen.',
  ).join('\n\n');

  final transcript = [
    user('u1', 'Lunch at a cafe'),
    assistant('a1', longAnswer, parent: 'u1'),
    user('u2', 'And the coffee too', parent: 'a1'),
    assistant('a2', 'Send the report?', parent: 'u2'),
  ];

  Future<void> frames(WidgetTester tester, [int count = 6]) async {
    for (var i = 0; i < count; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<ProviderContainer> mountPage(WidgetTester tester) async {
    final originalErrorWidgetBuilder = ErrorWidget.builder;
    final originalFlutterErrorOnError = FlutterError.onError;
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      ErrorWidget.builder = originalErrorWidgetBuilder;
      FlutterError.onError = originalFlutterErrorOnError;
      await db.close();
    });
    await tester.runAsync(
      () => db
          .into(db.chats)
          .insert(
            ChatsCompanion.insert(
              id: 'stored-chat',
              title: 'A chat',
              createdAt: 1,
              updatedAt: 1,
              bodySynced: const Value(true),
            ),
          ),
    );
    final chat = withChatStorageProvenance(
      Conversation(
        id: 'stored-chat',
        title: 'A chat',
        createdAt: at,
        updatedAt: at,
        messages: transcript,
      ),
      ChatStorageKind.openWebUi,
    );
    final container = ProviderContainer(
      overrides: [
        appSettingsProvider.overrideWith(_Settings.new),
        apiServiceProvider.overrideWithValue(
          _QuietApi(
            serverConfig: const ServerConfig(
              id: 'page',
              name: 'page',
              url: 'https://page.example.test',
            ),
            workerManager: WorkerManager(),
          ),
        ),
        appDatabaseProvider.overrideWith((ref) => db),
        syncEngineProvider.overrideWith(_NoDrainEngine.new),
        isAuthenticatedProvider2.overrideWithValue(true),
        reviewerModeProvider.overrideWithValue(false),
        selectedModelProvider.overrideWith(_Selected.new),
        activeConversationProvider.overrideWith(() => _Active(chat)),
        chatMessagesProvider.overrideWith(() => _Messages(transcript)),
        optimizedStorageServiceProvider.overrideWithValue(_Storage()),
        isOnlineProvider.overrideWithValue(true),
        conversationsProvider.overrideWith(_Conversations.new),
        modelsProvider.overrideWith(_Models.new),
        foldersProvider.overrideWith(_Folders.new),
        toolsListProvider.overrideWith(_Tools.new),
        personalizationSettingsProvider.overrideWith(_Personalization.new),
        directConnectionProfilesProvider.overrideWith(_NoProfiles.new),
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
    await frames(tester, 10);
    return container;
  }

  ScrollPosition position(WidgetTester tester) => tester
      .state<ScrollableState>(
        find
            .descendant(
              of: find.byType(ChatTimelineViewport),
              matching: find.byType(Scrollable),
            )
            .first,
      )
      .position;

  Rect rectOf(WidgetTester tester, String text) =>
      tester.getRect(find.textContaining(text).first);

  String? pinnedId(WidgetTester tester) => tester
      .widget<ChatTimelineViewport>(find.byType(ChatTimelineViewport))
      .pinnedUserMessageId;

  Future<void> finish(WidgetTester tester, ProviderContainer container) async {
    container.read(chatMessagesProvider.notifier)
      ..clearMessages()
      ..finishStreaming();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 10));
  }

  Future<void> dragDown(WidgetTester tester, int dy) async {
    final g = await tester.startGesture(const Offset(200, 300));
    for (var moved = 0; moved < dy; moved += 20) {
      await g.moveBy(const Offset(0, 20));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g.up();
  }

  Future<void> sendTyped(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField), text);
    await frames(tester, 2);
    await tester.tap(find.byKey(const ValueKey('primary-btn-send')));
    await frames(tester, 8);
  }

  testWidgets('a typed send ends at the bottom with the earlier reply still '
      'on screen and nothing pinned', (tester) async {
    final container = await mountPage(tester);
    final viewport = position(tester).viewportDimension;

    await sendTyped(tester, 'One more thing');

    check(container.read(chatMessagesProvider).length).equals(6);
    check(pinnedId(tester)).isNull();
    check(position(tester).pixels).equals(position(tester).maxScrollExtent);
    // The new bubble is low on the screen, not pinned near the top, and the
    // previous reply is visible above it.
    final sent = rectOf(tester, 'One more thing');
    check(sent.top).isGreaterThan(viewport / 2);
    final prior = rectOf(tester, 'Send the report?');
    check(prior.bottom).isLessThan(sent.top);
    check(prior.top).isGreaterThan(0);
    await finish(tester, container);
  });

  testWidgets('streaming growth keeps the view at the bottom', (tester) async {
    final container = await mountPage(tester);
    await sendTyped(tester, 'One more thing');

    for (var i = 0; i < 4; i++) {
      container
          .read(chatMessagesProvider.notifier)
          .appendToLastMessage('\n\nAnother streamed paragraph number $i.');
      await frames(tester, 3);
      check(position(tester).pixels).equals(position(tester).maxScrollExtent);
    }
    await finish(tester, container);
  });

  testWidgets('a reader scrolled up is not moved by a new message', (
    tester,
  ) async {
    final container = await mountPage(tester);
    await dragDown(tester, 600);
    await frames(tester, 6);
    check(position(tester).maxScrollExtent - position(tester).pixels)
        .isGreaterThan(300);
    final before = position(tester).pixels;

    container
        .read(chatMessagesProvider.notifier)
        .addMessage(assistant('a3', 'A routine posted this.', parent: 'a2'));
    await frames(tester, 6);

    check(position(tester).pixels).equals(before);
    await finish(tester, container);
  });

  testWidgets(
    'a reader within 80 px of the bottom stays pinned for a new message',
    (tester) async {
      final container = await mountPage(tester);
      await dragDown(tester, 40);
      await frames(tester, 6);

      container
          .read(chatMessagesProvider.notifier)
          .addMessage(assistant('a3', 'A routine posted this.', parent: 'a2'));
      await frames(tester, 8);

      check(position(tester).pixels).equals(position(tester).maxScrollExtent);
      await finish(tester, container);
    },
  );

  test('voice mode always follows and never decides to scroll up', () {
    for (final distance in [0.0, 40.0, 500.0, 5000.0]) {
      check(
        debugShouldFollowAppendedRowForTesting(
          voiceActive: true,
          userInteracting: false,
          distanceFromLatest: distance,
          sentByUser: false,
        ),
      ).isTrue();
    }
    check(
      debugShouldFollowAppendedRowForTesting(
        voiceActive: true,
        userInteracting: true,
        distanceFromLatest: 0,
        sentByUser: true,
      ),
    ).isFalse();
    check(
      debugShouldFollowAppendedRowForTesting(
        voiceActive: false,
        userInteracting: false,
        distanceFromLatest: 300,
        sentByUser: false,
      ),
    ).isFalse();
    check(
      debugShouldFollowAppendedRowForTesting(
        voiceActive: false,
        userInteracting: false,
        distanceFromLatest: 300,
        sentByUser: true,
      ),
    ).isTrue();
  });
}

class _Conversations extends Conversations {
  @override
  Future<List<Conversation>> build() async => const <Conversation>[];
}

class _Models extends Models {
  @override
  Future<List<Model>> build() async => const [
    Model(id: 'alpha', name: 'Alpha'),
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

class _Selected extends SelectedModel {
  @override
  Model? build() => const Model(id: 'alpha', name: 'Alpha');
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
  @override
  AppSettings build() => const AppSettings(
    quickReplyReactionsEnabled: true,
    deliveryReceiptsEnabled: true,
  );
}

class _Personalization extends PersonalizationSettings {
  @override
  Future<ServerUserSettings> build() async => const ServerUserSettings();
}

class _NoProfiles extends DirectConnectionProfilesController {
  @override
  Future<List<DirectConnectionProfile>> build() async => const [];
}

/// Answers the settings read an admission makes, without a network.
class _QuietApi extends ApiService {
  _QuietApi({required super.serverConfig, required super.workerManager});

  @override
  Future<Map<String, dynamic>> getUserSettings({Object? authSnapshot}) async =>
      const <String, dynamic>{};
}

/// A server drain that sends nothing: the turn stays exactly as admitted.
class _NoDrainEngine extends SyncEngine {
  @override
  SyncStatus build() => const SyncStatus();

  @override
  Future<void> drainNowForDatabase(AppDatabase expectedDatabase) async {}
}
