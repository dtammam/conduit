import 'package:checks/checks.dart';
import 'package:conduit/features/chat/reactions/quick_reply_reactions.dart';
import 'package:conduit/features/chat/views/chat_page.dart';
import 'package:conduit/features/chat/widgets/user_message_bubble.dart';
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
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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
    AppSettings settings = const AppSettings(
      quickReplyReactionsEnabled: true,
      deliveryReceiptsEnabled: true,
    ),
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
    _user('u2', 'Yes', parent: 'a1'),
    _assistant('a2', parent: 'u2'),
  ];
  final replyBadge = find.byKey(const ValueKey('assistant-quick-reply-badge'));
  final receipt = find.byKey(const Key('user-message-receipt'));

  testWidgets('a reaction turn shows as a badge on the reply it answers', (
    tester,
  ) async {
    await mountPage(tester, messages: transcript);

    check(find.text('Lunch at a cafe').evaluate()).length.equals(1);
    check(find.text('Yes').evaluate()).isEmpty();
    check(replyBadge.evaluate()).length.equals(1);
    check(
      find
          .descendant(of: replyBadge, matching: find.text('\u{1F44D}'))
          .evaluate(),
    ).length.equals(1);
    // The hidden turn has no receipt; the visible bubble before it keeps one.
    check(receipt.evaluate()).length.equals(1);
    check(
      find
          .ancestor(
            of: receipt,
            matching: find.byWidgetPredicate(
              (w) => w is UserMessageBubble && w.message.id == 'u1',
            ),
          )
          .evaluate(),
    ).length.equals(1);
  });

  test('a reaction send does not pin its hidden turn to the top', () {
    final beforeReaction = transcript.sublist(0, 2);
    check(
      shouldPinSentTurn(
        text: 'Yes',
        includeComposerContext: false,
        quickRepliesEnabled: true,
        messagesBeforeSend: beforeReaction,
      ),
    ).isFalse();
    // A typed "Yes" from the composer, the setting off, or a "Yes" that does
    // not answer a reply all pin as usual.
    check(
      shouldPinSentTurn(
        text: 'Yes',
        includeComposerContext: true,
        quickRepliesEnabled: true,
        messagesBeforeSend: beforeReaction,
      ),
    ).isTrue();
    check(
      shouldPinSentTurn(
        text: 'Yes',
        includeComposerContext: false,
        quickRepliesEnabled: false,
        messagesBeforeSend: beforeReaction,
      ),
    ).isTrue();
    check(
      shouldPinSentTurn(
        text: 'Yes',
        includeComposerContext: false,
        quickRepliesEnabled: true,
        messagesBeforeSend: const [],
      ),
    ).isTrue();
    check(
      shouldPinSentTurn(
        text: 'Tell me more',
        includeComposerContext: false,
        quickRepliesEnabled: true,
        messagesBeforeSend: beforeReaction,
      ),
    ).isTrue();
  });

  test('a reaction that failed to send stays visible with its failure', () {
    bool hidden(List<ChatMessage> messages, int index) =>
        isQuickReplyTurn(messages, index, failedSendMessageId: 'u2');
    // The send appended the reaction turn but did not dispatch it, so no
    // reply follows.
    final failed = transcript.sublist(0, 3);

    check(hidden(failed, 2)).isFalse();
    check(
      deriveMessageReceipt(
        messages: failed,
        messageId: 'u2',
        failedSendMessageId: 'u2',
        isHiddenTurn: hidden,
      ),
    ).equals(MessageReceipt.failed);
    check(
      deriveMessageReceipt(
        messages: failed,
        messageId: 'u1',
        failedSendMessageId: 'u2',
        isHiddenTurn: hidden,
      ),
    ).equals(MessageReceipt.none);
    check(quickReplyBadgeFor(failed, 'a1', failedSendMessageId: 'u2')).isNull();
    // Without the failure it is an ordinary, hidden reaction turn.
    check(isQuickReplyTurn(failed, 2)).isTrue();
    check(quickReplyBadgeFor(failed, 'a1')).isNotNull();
  });

  testWidgets('a reaction sent in another language still shows as a badge', (
    tester,
  ) async {
    await mountPage(
      tester,
      messages: [
        _user('u1', 'Lunch at a cafe'),
        _assistant('a1', parent: 'u1'),
        _user('u2', 'Nein', parent: 'a1'),
        _assistant('a2', parent: 'u2'),
      ],
    );

    check(find.text('Nein').evaluate()).isEmpty();
    check(
      find
          .descendant(of: replyBadge, matching: find.text('\u{1F44E}'))
          .evaluate(),
    ).length.equals(1);
  });

  testWidgets('with the setting off the reaction turn is a plain bubble', (
    tester,
  ) async {
    await mountPage(
      tester,
      messages: transcript,
      settings: const AppSettings(
        deliveryReceiptsEnabled: true,
        quickReplyReactionsEnabled: false,
      ),
    );

    check(find.text('Yes').evaluate()).length.equals(1);
    check(replyBadge.evaluate()).isEmpty();
  });

  test(
    'a quick reply keeps the chat\'s selected tools, a follow-up does not',
    () {
      const selected = ['web_search', 'calendar'];
      // The quick reply: no composer context, tools asked for explicitly.
      check(
        resolveSendToolIds(
          includeComposerContext: false,
          includeSelectedTools: true,
          selectedToolIds: selected,
        ),
      ).deepEquals(selected);
      // A follow-up suggestion sends none.
      check(
        resolveSendToolIds(
          includeComposerContext: false,
          includeSelectedTools: null,
          selectedToolIds: selected,
        ),
      ).isEmpty();
      // The composer's own turn follows the composer.
      check(
        resolveSendToolIds(
          includeComposerContext: true,
          includeSelectedTools: null,
          selectedToolIds: selected,
        ),
      ).deepEquals(selected);
    },
  );
}
