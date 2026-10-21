import 'package:checks/checks.dart';
import 'package:conduit/features/chat/avatar/assistant_avatar_strip.dart';
import 'package:conduit/features/chat/views/chat_page.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/adaptive_toolbar_components.dart';
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
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cupertino_ui/cupertino_ui.dart' show CupertinoIcons;
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
  Future<void> mountPage(
    WidgetTester tester, {
    required List<ChatMessage> messages,
    AppSettings settings = const AppSettings(),
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
        id: 'stored-chat',
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

  final transcript = <ChatMessage>[
    _user('u1', 'Lunch at a cafe'),
    _assistant('a1', parent: 'u1'),
  ];
  final strip = find.byKey(const ValueKey('assistant-avatar-strip'));

  testWidgets('no avatar strip while the setting is off (the default)', (
    tester,
  ) async {
    check(const AppSettings().assistantAvatarEnabled).isFalse();
    await mountPage(tester, messages: transcript);

    check(find.text('Lunch at a cafe').evaluate()).length.equals(1);
    check(find.byType(AssistantAvatarStrip).evaluate()).isEmpty();
    check(strip.evaluate()).isEmpty();
  });

  testWidgets('without the avatar the title keeps its chevron', (tester) async {
    await mountPage(tester, messages: transcript);

    final selector = find.byType(ConduitAdaptiveAppBarModelSelector);
    check(selector.evaluate()).length.equals(1);
    check(
      find.descendant(of: selector, matching: find.text('Model 1')).evaluate(),
    ).length.equals(1);
    final chevrons = [Icons.keyboard_arrow_down, CupertinoIcons.chevron_down]
        .expand(
          (icon) => find
              .descendant(of: selector, matching: find.byIcon(icon))
              .evaluate(),
        );
    check(chevrons).length.equals(1);
  });

  testWidgets(
    'the strip takes the title slot and names the model when the setting is on',
    (tester) async {
      await mountPage(
        tester,
        messages: transcript,
        settings: const AppSettings(assistantAvatarEnabled: true),
      );

      check(strip.evaluate()).length.equals(1);
      // The toolbar's own model selector gives way to the strip's pill.
      check(find.byType(ConduitAdaptiveAppBarModelSelector).evaluate())
          .isEmpty();
      check(find.byKey(const ValueKey('chat-title-in-avatar-strip')).evaluate())
          .length
          .equals(1);
      // The circle starts on the toolbar's top line, centered, overlapping the
      // toolbar's row, and still receives taps there.
      final circle = find.byKey(const ValueKey('assistant-avatar-circle'));
      final circleRect = tester.getRect(circle);
      final toolbarHeight = conduitAdaptiveToolbarHeightOf(
        tester.element(strip),
      );
      final statusBar = MediaQuery.viewPaddingOf(tester.element(strip)).top;
      check(circleRect.top).equals(statusBar);
      check(circleRect.center.dy).isLessThan(statusBar + toolbarHeight);
      check(circleRect.center.dx)
          .equals(tester.getSize(find.byType(ChatPage)).width / 2);
      // The menu button keeps its place beside the circle.
      final menu = tester.getRect(
        find.byKey(const ValueKey('chat-sidebar-toggle')),
      );
      check(menu.center.dy).equals(statusBar + toolbarHeight / 2);
      check(menu.right).isLessThan(circleRect.left);
      await tester.tap(circle);
      for (var frame = 0; frame < 3; frame++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      check(find.byKey(const ValueKey('assistant-avatar-row-idle')).evaluate())
          .length
          .equals(1);
      await tester.tapAt(const Offset(8, 8));
      for (var frame = 0; frame < 3; frame++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      check(
        find.descendant(of: strip, matching: find.text('Model 1')).evaluate(),
      ).length.equals(1);
      check(
        find
            .descendant(
              of: strip,
              matching: find.byWidgetPredicate(
                (w) => w is Semantics && w.properties.label == 'Model 1, Idle',
              ),
            )
            .evaluate(),
      ).length.equals(1);
      // The model initial stands in for a clip.
      check(find.descendant(of: strip, matching: find.text('M')).evaluate())
          .length
          .equals(1);
      check(find.text('Lunch at a cafe').evaluate()).length.equals(1);
      final stripRect = tester.getRect(strip);
      final firstMessage = tester.getRect(find.text('Lunch at a cafe'));
      check(firstMessage.top).isGreaterOrEqual(stripRect.bottom);
    },
  );
}
