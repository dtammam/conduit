import 'package:checks/checks.dart';
import 'package:conduit/features/chat/avatar/omni_tab_bar.dart';
import 'package:conduit/features/chat/views/chat_page.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit_core/database/chat_database_repository.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/tools/providers/tools_providers.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/folder.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/tool.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/connectivity_service.dart'
    show isOnlineProvider;
import 'package:conduit_core/services/optimized_storage_service.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/ports/key_value_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cupertino_ui/cupertino_ui.dart' show CupertinoIcons;
import 'package:conduit/features/chat/widgets/modern_chat_input.dart';
import 'package:material_ui/material_ui.dart';

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
  _Settings(this.initial);

  final AppSettings initial;

  @override
  AppSettings build() => initial;
}

ApiService _api() => ApiService(
  serverConfig: const ServerConfig(
    id: 'page',
    name: 'page',
    url: 'https://page.example.test',
  ),
  workerManager: WorkerManager(),
);

final _at = DateTime.utc(2024, 1, 1);

ChatMessage _user(String id, String content, {String? parent}) => ChatMessage(
  id: id,
  role: 'user',
  content: content,
  timestamp: _at,
  metadata: {'parentId': ?parent},
);

ChatMessage _assistant(String id, {required String parent}) => ChatMessage(
  id: id,
  role: 'assistant',
  content: 'answer $id',
  timestamp: _at,
  model: 'model-1',
  metadata: {'parentId': parent, 'responseDone': true},
);

void main() {
  setUp(() async {
    PreferencesStore.installLoader(() async => InMemoryKeyValueStore());
    await PreferencesStore.ensureInitialized();
    await PreferencesStore.put(PreferenceKeys.omniChatEnabled, true);
    await PreferencesStore.put(PreferenceKeys.omniChatId, 'omni-1');
  });
  tearDown(PreferencesStore.debugReset);

  Future<void> mountPage(
    WidgetTester tester, {
    required List<ChatMessage> messages,
    AppSettings settings = const AppSettings(assistantAvatarEnabled: true),
    String chatId = 'omni-1',
  }) async {
    final originalErrorWidgetBuilder = ErrorWidget.builder;
    final originalFlutterErrorOnError = FlutterError.onError;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      ErrorWidget.builder = originalErrorWidgetBuilder;
      FlutterError.onError = originalFlutterErrorOnError;
    });
    final chat = withChatStorageProvenance(
      Conversation(
        id: chatId,
        title: 'A chat',
        createdAt: _at,
        updatedAt: _at,
        messages: messages,
      ),
      ChatStorageKind.openWebUi,
    );
    final container = ProviderContainer(
      overrides: [
        appSettingsProvider.overrideWith(() => _Settings(settings)),
        apiServiceProvider.overrideWithValue(_api()),
        appDatabaseProvider.overrideWith((ref) => null),
        isAuthenticatedProvider2.overrideWithValue(false),
        reviewerModeProvider.overrideWithValue(false),
        selectedModelProvider.overrideWith(_SelectedModel.new),
        activeConversationProvider.overrideWith(() => _Active(chat)),
        chatMessagesProvider.overrideWith(() => _Messages(messages)),
        optimizedStorageServiceProvider.overrideWithValue(_Storage()),
        isChatStreamingProvider.overrideWith((ref) => false),
        // The app runs one connectivity service everywhere; the fork action
        // only reads whether it is online.
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
    // A page with a transcript keeps scheduling frames, so it never settles:
    // give the sibling reads and the first layout a bounded number of frames.
    for (var frame = 0; frame < 6; frame++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  Future<void> mountPageFrames(WidgetTester tester) async {
    for (var frame = 0; frame < 3; frame++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  final transcript = <ChatMessage>[
    _user('u1', 'Lunch at a cafe'),
    _assistant('a1', parent: 'u1'),
  ];
  final bar = find.byKey(const ValueKey('omni-tab-bar'));
  final newChat = find.byIcon(Icons.add_comment);

  testWidgets('the Omni chat has the tab bar and no New chat button', (
    tester,
  ) async {
    await mountPage(tester, messages: transcript);
    check(bar.evaluate()).length.equals(1);
    check(find.byType(OmniTabBar).evaluate()).length.equals(1);
    check(newChat.evaluate()).isEmpty();
    check(find.byIcon(CupertinoIcons.create).evaluate()).isEmpty();
  });

  testWidgets(
    'the bar sits 22 pt up with 21 pt sides and about 11 pt under the composer',
    (tester) async {
      tester.view.physicalSize = const Size(393, 852);
      tester.view.devicePixelRatio = 1;
      tester.view.padding = const FakeViewPadding(top: 59, bottom: 34);
      tester.view.viewPadding = const FakeViewPadding(top: 59, bottom: 34);
      addTearDown(tester.view.reset);
      await mountPage(tester, messages: transcript);
      final rect = tester.getRect(bar);
      check(852 - rect.bottom).isCloseTo(22, 0.5);
      check(rect.left).isCloseTo(21, 0.5);
      check(393 - rect.right).isCloseTo(21, 0.5);
      check(rect.height).isCloseTo(60, 0.5);
      // The composer's shell ends about 11 pt above the bar.
      final composer = tester.getRect(find.byType(ModernChatInput));
      check(rect.top - composer.bottom).isLessThan(14);
      check(rect.top - composer.bottom).isGreaterOrEqual(9);
    },
  );

  testWidgets(
    'the bar hides with the keyboard and the composer follows it without a jump',
    (tester) async {
      tester.view.physicalSize = const Size(393, 852);
      tester.view.devicePixelRatio = 1;
      tester.view.padding = const FakeViewPadding(top: 59, bottom: 34);
      tester.view.viewPadding = const FakeViewPadding(top: 59, bottom: 34);
      addTearDown(tester.view.reset);
      await mountPage(tester, messages: transcript);
      final composer = find.byType(ModernChatInput);
      final closedBottom = tester.getRect(composer).bottom;
      check(bar.evaluate()).length.equals(1);

      var previous = closedBottom;
      for (final inset in [100.0, 200.0, 300.0, 336.0]) {
        tester.view.viewInsets = FakeViewPadding(bottom: inset);
        await mountPageFrames(tester);
        final bottom = tester.getRect(composer).bottom;
        // Rising with the keyboard, never dropping back.
        check(bottom).isLessThan(previous);
        // And never by more than the keyboard''s own step plus the bar''s room.
        check(previous - bottom).isLessThan(100 + 100);
        previous = bottom;
      }
      // Fully up: no bar, the composer 8 pt above the keyboard.
      check(bar.evaluate()).isEmpty();
      check(find.byKey(const ValueKey('omni-tab-bar-hidden')).evaluate()).length
          .equals(1);
      check(852 - 336 - tester.getRect(composer).bottom).isCloseTo(8, 0.5);

      // Keyboard down again: the bar is back and the composer is where it was.
      tester.view.viewInsets = FakeViewPadding.zero;
      await mountPageFrames(tester);
      check(bar.evaluate()).length.equals(1);
      check(tester.getRect(composer).bottom).isCloseTo(closedBottom, 0.5);
    },
  );

  testWidgets('another chat has neither the bar nor the missing button', (
    tester,
  ) async {
    await mountPage(tester, messages: transcript, chatId: 'other-chat');
    check(bar.evaluate()).isEmpty();
    check(
      [
        Icons.add_comment,
        CupertinoIcons.create,
      ].expand((i) => find.byIcon(i).evaluate()),
    ).isNotEmpty;
  });

  testWidgets('no bar when the assistant avatar is off', (tester) async {
    await mountPage(
      tester,
      messages: transcript,
      settings: const AppSettings(),
    );
    check(bar.evaluate()).isEmpty();
  });

  testWidgets('a bar button opens the assistant page over the chat', (
    tester,
  ) async {
    await mountPage(tester, messages: transcript);
    await tester.tap(find.byKey(const ValueKey('omni-tab-appearance')));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    check(find.byKey(const ValueKey('assistant-sheet-body')).evaluate()).length
        .equals(1);
  });
}
