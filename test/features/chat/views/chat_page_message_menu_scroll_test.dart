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
import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/ports/key_value_store.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_core/sync/sync_engine.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// A reaction is sent through the page's real durable send: the transcript
/// must not move when it is sent, and the reply then follows the bottom.
void main() {
  setUp(() async {
    PreferencesStore.installLoader(() async => InMemoryKeyValueStore());
    await PreferencesStore.ensureInitialized();
    await PreferencesStore.put(PreferenceKeys.omniChatEnabled, true);
    await PreferencesStore.put(PreferenceKeys.omniChatId, 'omni-1');
  });
  tearDown(PreferencesStore.debugReset);
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
              id: 'omni-1',
              title: 'A chat',
              createdAt: 1,
              updatedAt: 1,
              bodySynced: const Value(true),
            ),
          ),
    );
    final chat = withChatStorageProvenance(
      Conversation(
        id: 'omni-1',
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

  bool composerFocused(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField)).focusNode?.hasFocus ??
      false;

  Future<void> finish(WidgetTester tester, ProviderContainer container) async {
    container.read(chatMessagesProvider.notifier)
      ..clearMessages()
      ..finishStreaming();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 10));
  }

  bool pageIsCurrentRoute(WidgetTester tester) =>
      ModalRoute.of(tester.element(find.byType(TextField)))?.isCurrent ?? false;

  // Pressing a message opens its menu over the page. The menu must not cover
  // the page as a route does: that rebuilt the composer and the rows as covered
  // and moved the transcript. Nothing under the menu may move, at any frame of
  // opening or closing.
  for (final keyboardUp in [false, true]) {
    testWidgets(
      'the message menu opens and closes without moving the transcript '
      '(keyboard ${keyboardUp ? 'up' : 'down'})',
      (tester) async {
        final container = await mountPage(tester);
        if (keyboardUp) {
          await tester.tap(find.byType(TextField));
          tester.view.viewInsets = const FakeViewPadding(bottom: 600);
          addTearDown(tester.view.resetViewInsets);
          await frames(tester, 6);
        }
        final reply = find.text('Send the report?');
        final before = tester.getRect(reply);
        final composerBefore = tester.getRect(find.byType(TextField));
        final pixels = position(tester).pixels;
        final extent = position(tester).maxScrollExtent;
        final focusedBefore = composerFocused(tester);
        final menu = find.byKey(const ValueKey('message-action-menu'));

        void checkUnmoved() {
          check(tester.getRect(reply)).equals(before);
          check(tester.getRect(find.byType(TextField))).equals(composerBefore);
          check(position(tester).pixels).equals(pixels);
          check(position(tester).maxScrollExtent).equals(extent);
          check(composerFocused(tester)).equals(focusedBefore);
          // The page is still the current route: nothing was pushed over it.
          check(pageIsCurrentRoute(tester)).isTrue();
        }

        final gesture = await tester.startGesture(before.center);
        for (var i = 0; i < 12; i++) {
          await tester.pump(const Duration(milliseconds: 50));
          checkUnmoved();
        }
        await gesture.up();
        await frames(tester, 4);
        check(menu.evaluate()).isNotEmpty();
        checkUnmoved();

        await tester.tapAt(const Offset(5, 300));
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 50));
          checkUnmoved();
        }
        check(menu.evaluate()).isEmpty();
        await finish(tester, container);
      },
    );
  }
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
    assistantAvatarEnabled: true,
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
