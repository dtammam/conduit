import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit/features/chat/avatar/assistant_action_log.dart';
import 'package:conduit/features/chat/avatar/assistant_activity.dart';
import 'package:conduit/features/chat/avatar/assistant_avatar_media.dart';
import 'package:conduit/features/chat/avatar/assistant_avatar_sheet.dart';
import 'package:conduit/features/chat/avatar/assistant_pending_approval.dart';
import 'package:conduit/features/chat/musey/musey_feed_api.dart';
import 'package:conduit/features/chat/musey/musey_feed_providers.dart';
import 'package:conduit/features/chat/widgets/link_preview_cards.dart';
import 'package:conduit/features/chat/widgets/routine_post_actions.dart';
import 'package:conduit/features/routines/push_registration.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit_core/features/automations/providers/automation_providers.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:cupertino_ui/cupertino_ui.dart' show CupertinoIcons;
import 'package:conduit_core/services/settings_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A 1x1 PNG.
final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

class _FakeApi implements MuseyFeedApi {
  _FakeApi({
    this.feed,
    this.ideas,
    this.likeOk = true,
    this.bytes,
    this.preview,
  });

  FeedData? feed;
  List<IdeaItem>? ideas;
  bool likeOk;
  Completer<void>? likeGate;
  Uint8List? bytes;
  LinkPreview? preview;
  final List<String> calls = [];

  /// What the next topics save answers; null saves what was asked.
  TopicsResult? topicsAnswer;
  Completer<void>? topicsGate;
  DismissResult dismissAnswer = DismissResult.done;
  Completer<void>? dismissGate;
  Completer<String?>? reactGate;
  String? reactAnswer;
  final List<String> previewUrls = [];
  int byteFetches = 0;

  @override
  Future<FeedData?> getFeed() async {
    calls.add('feed');
    return feed;
  }

  @override
  Future<bool> setFeedPrompt(String prompt) async {
    calls.add('prompt:$prompt');
    return true;
  }

  @override
  Future<TopicsResult> setFeedTopics(List<String> topics) async {
    calls.add('topics:${topics.join('|')}');
    await topicsGate?.future;
    return topicsAnswer ?? TopicsResult.saved(topics);
  }

  @override
  Future<DismissResult> dismissFeedItem(String id) async {
    calls.add('feed-dismiss:$id');
    await dismissGate?.future;
    return dismissAnswer;
  }

  @override
  Future<String?> react(String text) async {
    calls.add('react:$text');
    final gate = reactGate;
    return gate != null ? await gate.future : reactAnswer;
  }

  @override
  Future<bool> refreshFeed() async {
    calls.add('refresh');
    return true;
  }

  @override
  Future<bool> like(String id, {required bool liked}) async {
    calls.add('like:$id:$liked');
    await likeGate?.future;
    return likeOk;
  }

  @override
  Future<List<IdeaItem>?> getIdeas() async {
    calls.add('ideas');
    return ideas;
  }

  @override
  Future<bool> dismissIdea(String id) async {
    calls.add('dismiss:$id');
    return true;
  }

  @override
  Future<Uint8List?> fetchBytes(String path) async {
    byteFetches++;
    return bytes;
  }

  @override
  Future<LinkPreview?> linkPreview(String url) async {
    previewUrls.add(url);
    return preview;
  }
}

class _ThrowingApi extends _FakeApi {
  @override
  Future<FeedData?> getFeed() async => throw StateError('boom');

  @override
  Future<List<IdeaItem>?> getIdeas() async => throw StateError('boom');

  @override
  Future<bool> like(String id, {required bool liked}) async =>
      throw StateError('boom');
}

class _LikeThrowsApi extends _FakeApi {
  _LikeThrowsApi({super.feed});

  @override
  Future<bool> like(String id, {required bool liked}) async =>
      throw StateError('boom');
}

class _Messages extends ChatMessagesNotifier {
  @override
  List<ChatMessage> build() => const [];
}

class _Active extends ActiveConversationNotifier {
  @override
  Conversation? build() => Conversation(
    id: 'omni-chat',
    title: 'Chat',
    createdAt: DateTime(2024, 1, 1),
    updatedAt: DateTime(2024, 1, 1),
  );
}

class _Log extends AssistantActionLog {
  _Log(this.failures);
  final int failures;

  @override
  AssistantActionLogState build() => AssistantActionLogState(
    records: [
      for (var i = 0; i < failures; i++)
        AssistantActionRecord(
          id: 'f$i',
          chatId: 'c',
          messageId: 'm$i',
          toolName: 'web_search',
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

class _Settings extends AppSettingsNotifier {
  _Settings(this.value);
  final AppSettings value;

  @override
  AppSettings build() => value;
}

class _Store extends AssistantAvatarMediaStore {
  @override
  Future<AssistantAvatarMediaSet> load({String? personaId}) async =>
      const AssistantAvatarMediaSet(bundled: {AssistantActivity.idle});
}

FeedItem _item(String id, {String? image, bool liked = false}) => FeedItem(
  id: id,
  title: 'Title $id',
  body: 'Body of $id',
  url: 'https://www.example.com/$id',
  source: 'Example',
  imageUrl: image,
  icon: 'gamepad',
  at: DateTime.now().subtract(const Duration(hours: 3)),
  liked: liked,
);

void main() {
  late Directory cacheDir;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    cacheDir = Directory.systemTemp.createTempSync('musey_cache_test');
  });

  tearDown(() {
    if (cacheDir.existsSync()) cacheDir.deleteSync(recursive: true);
  });

  ProviderContainer makeContainer({
    MuseyFeedApi? api,
    int failures = 0,
    AssistantApproval? approval,
    AppSettings settings = const AppSettings(routinesServerUrl: ''),
    List<Override> extra = const [],
  }) {
    final container = ProviderContainer(
      overrides: [
        museyFeedApiProvider.overrideWithValue(api),
        museyCacheDirProvider.overrideWithValue(() async => cacheDir),
        chatMessagesProvider.overrideWith(_Messages.new),
        activeConversationProvider.overrideWith(_Active.new),
        assistantActionLogProvider.overrideWith(() => _Log(failures)),
        assistantApprovalProvider.overrideWithValue(approval),
        automationsAvailableProvider.overrideWithValue(false),
        appSettingsProvider.overrideWith(() => _Settings(settings)),
        ...extra,
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  Future<void> mountPage(
    WidgetTester tester,
    ProviderContainer container, {
    required AssistantSheetTab tab,
    Size size = const Size(393, 852),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // A fresh page each time, not the last one with another container.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.dark(TweakcnThemes.t3Chat),
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: AssistantAvatarSheet(
            store: _Store(),
            modelName: 'Assistant',
            initialTab: tab,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  group('parsing', () {
    test('the feed keeps what it can use and drops the rest', () {
      final feed = parseFeed({
        'enabled': true,
        'prompt': 'games',
        'items': [
          {'id': 'a', 'title': 'A', 'url': 'javascript:alert(1)', 'body': null},
          {'id': 'b', 'title': '  '},
          {'title': 'no id'},
          'junk',
          {'id': 'c', 'title': 'C', 'url': 'https://x.test/c', 'liked': true},
        ],
      })!;
      check(feed.prompt).equals('games');
      check(feed.items.map((i) => i.id).toList()).deepEquals(['a', 'c']);
      check(feed.items.first.url).isNull();
      check(feed.items.last.liked).isTrue();
      check(
        parseFeed({
          'enabled': false,
          'items': [
            {'id': 'a', 'title': 'A'},
          ],
        })!.items,
      ).isEmpty();
      check(parseFeed('nope')).isNull();
    });

    test('ideas parse and a disabled answer is empty', () {
      final ideas = parseIdeas({
        'enabled': true,
        'items': [
          {'id': 1, 'title': 'T', 'prompt': 'Do it', 'icon': 'x'},
          {'id': 'z'},
        ],
      })!;
      check(ideas.length).equals(1);
      check(ideas.single.sendText).equals('Do it');
      check(parseIdeas({'enabled': false})!).isEmpty();
      check(parseIdeas(null)).isNull();
    });

    test('Discuss text is the title and the link, as specified', () {
      check(_item('a').discussText)
          .equals("Let's discuss this: Title a\nhttps://www.example.com/a");
      check(_item('a').domain).equals('example.com');
    });
  });

  group('feed page', () {
    testWidgets('lays out like Muse at 393x852', (tester) async {
      final api = _FakeApi(
        bytes: _png,
        feed: FeedData(
          enabled: true,
          prompt: 'video games and game launches',
          items: [
            _item('a', image: '/musey/link-image?url=x'),
            _item('b'),
          ],
        ),
      );
      final container = makeContainer(api: api);
      await mountPage(tester, container, tab: AssistantSheetTab.feed);
      await tester.pump(const Duration(milliseconds: 100));

      check(tester.takeException()).isNull();
      final title = tester.getTopLeft(
        find.byKey(const ValueKey('assistant-page-title')),
      );
      check(title.dx).equals(16);
      check(
        tester
            .widget<Text>(find.byKey(const ValueKey('assistant-page-title')))
            .data,
      ).equals('Feed');
      // The prompt box is a rounded box with a 16 pt margin, under the title.
      final box = tester.getRect(
        find.byKey(const ValueKey('musey-feed-prompt')),
      );
      check(box.left).equals(16);
      check(box.right).equals(393 - 16);
      check(box.top).isGreaterThan(title.dy);
      check(find.text('video games and game launches').evaluate()).length
          .equals(1);
      // Items: the icon column at the 16 pt margin, bold title, source link.
      final first = find.byKey(const ValueKey('musey-feed-item-a'));
      check(tester.getRect(first).left).equals(16);
      check(find.text('Title a').evaluate()).length.equals(1);
      check(find.byKey(const ValueKey('musey-feed-link-a')).evaluate()).length
          .equals(1);
      check(find.byKey(const ValueKey('musey-feed-image-a')).evaluate()).length
          .equals(1);
      check(find.byKey(const ValueKey('musey-feed-image-b')).evaluate())
          .isEmpty();
      // The action row: heart, then Discuss at the left; time at the right.
      final heart = tester.getRect(
        find.byKey(const ValueKey('musey-feed-like-a')),
      );
      final discuss = tester.getRect(
        find.byKey(const ValueKey('musey-feed-discuss-a')),
      );
      final info = tester.getRect(
        find.byKey(const ValueKey('musey-feed-info-a')),
      );
      check(heart.right).isLessThan(discuss.left + 1);
      check(info.left).isGreaterThan(discuss.right);
      check(info.right).isLessThan(393 - 15);
      check(find.text('3h').evaluate()).length.equals(2);
      // The refresh button sits on the right of the top row.
      final refresh = tester.getRect(
        find.byKey(const ValueKey('musey-feed-refresh')),
      );
      check(refresh.right).isGreaterThan(393 - 16 - 50);
    });

    testWidgets('an erroring, empty or disabled relay says nothing here yet', (
      tester,
    ) async {
      for (final api in <MuseyFeedApi?>[
        null,
        _FakeApi(feed: null),
        _FakeApi(feed: const FeedData(enabled: false)),
        _FakeApi(feed: const FeedData(enabled: true)),
        _ThrowingApi(),
      ]) {
        final container = makeContainer(api: api);
        await mountPage(tester, container, tab: AssistantSheetTab.feed);
        await tester.pump(const Duration(milliseconds: 100));
        check(tester.takeException()).isNull();
        check(find.byKey(const ValueKey('musey-empty')).evaluate()).length
            .equals(1);
        check(find.text('Nothing here yet').evaluate()).length.equals(1);
        // One load, no retry loop.
        await tester.pump(const Duration(seconds: 5));
        if (api is _FakeApi && api is! _ThrowingApi) {
          check(api.calls.where((c) => c == 'feed').length).equals(1);
        }
      }
    });

    testWidgets(
      'the heart is optimistic and comes back when the relay refuses',
      (tester) async {
        final api = _FakeApi(
          feed: FeedData(enabled: true, items: [_item('a')]),
          likeOk: false,
        )..likeGate = Completer<void>();
        final container = makeContainer(api: api);
        await mountPage(tester, container, tab: AssistantSheetTab.feed);
        await tester.pump(const Duration(milliseconds: 100));

        await tester.tap(find.byKey(const ValueKey('musey-feed-like-a')));
        // At once, before the relay has answered: liked.
        check(container.read(feedProvider).items.single.liked).isTrue();
        api.likeGate!.complete();
        await tester.pump(const Duration(milliseconds: 50));
        // Refused: back to not liked.
        check(container.read(feedProvider).items.single.liked).isFalse();
        check(api.calls).contains('like:a:true');

        api
          ..likeOk = true
          ..likeGate = null;
        await tester.tap(find.byKey(const ValueKey('musey-feed-like-a')));
        await tester.pump(const Duration(milliseconds: 50));
        check(container.read(feedProvider).items.single.liked).isTrue();
      },
    );

    testWidgets('a throwing relay puts the heart back too', (tester) async {
      final api = _LikeThrowsApi(
        feed: FeedData(enabled: true, items: [_item('a')]),
      );
      final container = makeContainer(api: api);
      await mountPage(tester, container, tab: AssistantSheetTab.feed);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.byKey(const ValueKey('musey-feed-like-a')));
      await tester.pump(const Duration(milliseconds: 50));
      check(tester.takeException()).isNull();
      check(container.read(feedProvider).items.single.liked).isFalse();
    });

    testWidgets('Discuss goes to the chat with the exact text', (tester) async {
      final api = _FakeApi(feed: FeedData(enabled: true, items: [_item('a')]));
      final container = makeContainer(api: api);
      await mountPage(tester, container, tab: AssistantSheetTab.feed);
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.byKey(const ValueKey('musey-feed-discuss-a')));
      await tester.pump();
      final request = container.read(routineReplyProvider);
      check(request).isNotNull();
      check(request!.chatId).equals('omni-chat');
      check(request.text)
          .equals("Let's discuss this: Title a\nhttps://www.example.com/a");
    });

    testWidgets('info shows the source domain', (tester) async {
      final api = _FakeApi(feed: FeedData(enabled: true, items: [_item('a')]));
      final container = makeContainer(api: api);
      await mountPage(tester, container, tab: AssistantSheetTab.feed);
      await tester.pump(const Duration(milliseconds: 100));
      check(find.byKey(const ValueKey('musey-feed-info-text-a')).evaluate())
          .isEmpty();
      await tester.tap(find.byKey(const ValueKey('musey-feed-info-a')));
      await tester.pump();
      check(find.text('Source: example.com').evaluate()).length.equals(1);
    });

    testWidgets('an older relay without topics shows the prompt read only', (
      tester,
    ) async {
      final api = _FakeApi(feed: const FeedData(enabled: true, prompt: 'old'));
      final container = makeContainer(api: api);
      await mountPage(tester, container, tab: AssistantSheetTab.feed);
      await tester.pump(const Duration(milliseconds: 100));
      check(find.byKey(const ValueKey('musey-feed-prompt')).evaluate())
          .length
          .equals(1);
      check(find.text('old').evaluate()).length.equals(1);
      check(find.byKey(const ValueKey('musey-feed-topic-field')).evaluate())
          .isEmpty();
    });

    testWidgets('interests are chips: add and remove each save at once', (
      tester,
    ) async {
      final api = _FakeApi(
        feed: const FeedData(enabled: true, topics: ['AI tools', 'Games']),
      );
      final container = makeContainer(api: api);
      await mountPage(tester, container, tab: AssistantSheetTab.feed);
      await tester.pump(const Duration(milliseconds: 100));
      check(find.byKey(const ValueKey('musey-feed-topic-AI tools')).evaluate())
          .length
          .equals(1);

      await tester.enterText(
        find.descendant(
          of: find.byKey(const ValueKey('musey-feed-topic-field')),
          matching: find.byType(EditableText),
        ),
        '  Space  ',
      );
      await tester.tap(find.byKey(const ValueKey('musey-feed-topic-add')));
      await tester.pump(const Duration(milliseconds: 50));
      check(api.calls).contains('topics:AI tools|Games|Space');
      check(container.read(feedProvider).topics)
          .isNotNull()
          .deepEquals(['AI tools', 'Games', 'Space']);

      await tester.tap(find.byKey(const ValueKey('musey-feed-topic-Games')));
      await tester.pump(const Duration(milliseconds: 50));
      check(api.calls).contains('topics:AI tools|Space');
      check(find.byKey(const ValueKey('musey-feed-topic-Games')).evaluate())
          .isEmpty();
    });

    testWidgets('the relay list is the truth, a failure keeps the old list', (
      tester,
    ) async {
      final api = _FakeApi(
        feed: const FeedData(enabled: true, topics: ['A']),
      );
      final container = makeContainer(api: api);
      await mountPage(tester, container, tab: AssistantSheetTab.feed);
      await tester.pump(const Duration(milliseconds: 100));
      final notifier = container.read(feedProvider.notifier);

      api.topicsAnswer = const TopicsResult.saved(['A', 'B (kept by relay)']);
      await notifier.addTopic('B');
      check(container.read(feedProvider).topics)
          .isNotNull()
          .deepEquals(['A', 'B (kept by relay)']);

      api.topicsAnswer = const TopicsResult.failed('at most 6 interests');
      final outcome = await notifier.addTopic('C');
      check(outcome).equals(TopicOutcome.failed);
      check(container.read(feedProvider).topics)
          .isNotNull()
          .deepEquals(['A', 'B (kept by relay)']);
      check(container.read(feedProvider).savingTopics).isFalse();
    });

    testWidgets('no duplicate request while one is out, repeats are ignored', (
      tester,
    ) async {
      final api = _FakeApi(
        feed: const FeedData(enabled: true, topics: ['A']),
      );
      api.topicsGate = Completer<void>();
      final container = makeContainer(api: api);
      await mountPage(tester, container, tab: AssistantSheetTab.feed);
      await tester.pump(const Duration(milliseconds: 100));
      final notifier = container.read(feedProvider.notifier);

      final first = notifier.addTopic('B');
      final second = notifier.addTopic('C');
      check(await second).equals(TopicOutcome.busy);
      check(await notifier.addTopic('a')).equals(TopicOutcome.same);
      api.topicsGate!.complete();
      check(await first).equals(TopicOutcome.saved);
      check(api.calls.where((c) => c.startsWith('topics:')).length).equals(1);
    });

    testWidgets('at six the field is gone and the page says why', (
      tester,
    ) async {
      final api = _FakeApi(
        feed: const FeedData(
          enabled: true,
          topics: ['a', 'b', 'c', 'd', 'e', 'f'],
        ),
      );
      final container = makeContainer(api: api);
      await mountPage(tester, container, tab: AssistantSheetTab.feed);
      await tester.pump(const Duration(milliseconds: 100));
      check(find.byKey(const ValueKey('musey-feed-topic-field')).evaluate())
          .isEmpty();
      check(find.byKey(const ValueKey('musey-feed-topics-full')).evaluate())
          .length
          .equals(1);
      final outcome = await container
          .read(feedProvider.notifier)
          .addTopic('g');
      check(outcome).equals(TopicOutcome.full);
      check(api.calls.where((c) => c.startsWith('topics:'))).isEmpty();
    });

    testWidgets('swiping a card left removes it and tells the relay', (
      tester,
    ) async {
      final api = _FakeApi(
        feed: FeedData(enabled: true, items: [_item('a'), _item('b')]),
      );
      final container = makeContainer(api: api);
      await mountPage(tester, container, tab: AssistantSheetTab.feed);
      await tester.pump(const Duration(milliseconds: 100));

      await tester.fling(
        find.byKey(const ValueKey('musey-feed-item-a')),
        const Offset(-500, 0),
        1500,
      );
      await tester.pumpAndSettle();
      check(api.calls).contains('feed-dismiss:a');
      check(container.read(feedProvider).items.map((i) => i.id).toList())
          .deepEquals(['b']);

      // A swipe to the right does nothing.
      await tester.fling(
        find.byKey(const ValueKey('musey-feed-item-b')),
        const Offset(500, 0),
        1500,
      );
      await tester.pumpAndSettle();
      check(container.read(feedProvider).items.length).equals(1);
    });

    testWidgets('a vertical drag scrolls and does not dismiss', (tester) async {
      final api = _FakeApi(
        feed: FeedData(
          enabled: true,
          items: [for (var i = 0; i < 12; i++) _item('i$i')],
        ),
      );
      final container = makeContainer(api: api);
      await mountPage(tester, container, tab: AssistantSheetTab.feed);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.drag(
        find.byKey(const ValueKey('musey-feed-list')),
        const Offset(-40, -300),
      );
      await tester.pumpAndSettle();
      check(container.read(feedProvider).items.length).equals(12);
      check(api.calls.where((c) => c.startsWith('feed-dismiss'))).isEmpty();
    });

    testWidgets('a failed dismissal puts the card back and says so', (
      tester,
    ) async {
      final api = _FakeApi(
        feed: FeedData(enabled: true, items: [_item('a'), _item('b')]),
      )..dismissAnswer = DismissResult.failed;
      final container = makeContainer(api: api);
      await mountPage(tester, container, tab: AssistantSheetTab.feed);
      await tester.pump(const Duration(milliseconds: 100));

      await tester.fling(
        find.byKey(const ValueKey('musey-feed-item-a')),
        const Offset(-500, 0),
        1500,
      );
      await tester.pumpAndSettle();
      check(container.read(feedProvider).items.map((i) => i.id).toList())
          .deepEquals(['a', 'b']);
      check(find.text('Could not remove that, it is back').evaluate())
          .isNotEmpty();
    });

    testWidgets('a 404 on dismiss counts as gone', (tester) async {
      final api = _FakeApi(
        feed: FeedData(enabled: true, items: [_item('a')]),
      )..dismissAnswer = DismissResult.gone;
      final container = makeContainer(api: api);
      await mountPage(tester, container, tab: AssistantSheetTab.feed);
      await tester.pump(const Duration(milliseconds: 100));
      final stays = await container
          .read(feedProvider.notifier)
          .dismissItem('a');
      check(stays).isTrue();
      check(container.read(feedProvider).items).isEmpty();
    });

    testWidgets('the refresh button starts a run and the pull reloads only', (
      tester,
    ) async {
      final api = _FakeApi(feed: const FeedData(enabled: true));
      final container = makeContainer(api: api);
      await mountPage(tester, container, tab: AssistantSheetTab.feed);
      await tester.pump(const Duration(milliseconds: 100));
      api.calls.clear();

      await tester.tap(find.byKey(const ValueKey('musey-feed-refresh')));
      await tester.pump(const Duration(milliseconds: 100));
      check(api.calls).deepEquals(['refresh']);
      await tester.pump(const Duration(seconds: 5));

      api.calls.clear();
      await tester.fling(
        find.byKey(const ValueKey('musey-feed-list')),
        const Offset(0, 400),
        1000,
      );
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      check(api.calls).deepEquals(['feed']);
    });
  });

  group('ideas page', () {
    testWidgets('lays out, sends the prompt on tap, dismisses on long press', (
      tester,
    ) async {
      final api = _FakeApi(
        ideas: [
          const IdeaItem(
            id: 'i1',
            title: 'Plan the week',
            body: 'Line one of a long body\n2\n3\n4\n5\n6\n7',
            icon: 'calendar',
            prompt: 'Help me plan the week',
          ),
          const IdeaItem(id: 'i2', title: 'Second', icon: null),
        ],
      );
      final container = makeContainer(api: api);
      await mountPage(tester, container, tab: AssistantSheetTab.ideas);
      await tester.pump(const Duration(milliseconds: 100));

      check(
        tester
            .widget<Text>(find.byKey(const ValueKey('assistant-page-title')))
            .data,
      ).equals('Ideas');
      final row = tester.getRect(find.byKey(const ValueKey('musey-idea-i1')));
      check(row.left).equals(16);
      check(row.right).equals(393 - 16);
      // The icon is not on the relay: the built-in glyph stands in.
      check(find.byIcon(CupertinoIcons.lightbulb).evaluate().length)
          .isGreaterThan(0);
      final body = tester.widget<Text>(find.textContaining('Line one'));
      check(body.maxLines).equals(5);

      await tester.tap(find.byKey(const ValueKey('musey-idea-i1')));
      await tester.pump();
      check(container.read(routineReplyProvider)!.text)
          .equals('Help me plan the week');

      await tester.longPress(find.byKey(const ValueKey('musey-idea-i2')));
      await tester.pump();
      check(api.calls).contains('dismiss:i2');
      check(find.text('Second').evaluate()).isEmpty();
      check(container.read(ideasProvider).items.length).equals(1);
    });

    testWidgets('a swipe dismisses too', (tester) async {
      final api = _FakeApi(
        ideas: [const IdeaItem(id: 'i1', title: 'One')],
      );
      final container = makeContainer(api: api);
      await mountPage(tester, container, tab: AssistantSheetTab.ideas);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.drag(
        find.byKey(const ValueKey('musey-idea-i1')),
        const Offset(-300, 0),
      );
      await tester.pumpAndSettle();
      check(api.calls).contains('dismiss:i1');
    });

    testWidgets('failures and empty answers say nothing here yet', (
      tester,
    ) async {
      for (final api in <MuseyFeedApi?>[
        null,
        _FakeApi(ideas: null),
        _FakeApi(ideas: const []),
        _ThrowingApi(),
      ]) {
        final container = makeContainer(api: api);
        await mountPage(tester, container, tab: AssistantSheetTab.ideas);
        await tester.pump(const Duration(milliseconds: 100));
        check(tester.takeException()).isNull();
        check(find.text('Nothing here yet').evaluate()).length.equals(1);
      }
    });
  });

  group('icons and cache', () {
    test('an icon is fetched once and then read from disk', () async {
      final api = _FakeApi(bytes: _png);
      final one = makeContainer(api: api);
      final a = await one
          .read(museyAssetCacheProvider)
          .bytes('/musey/icons/x.png');
      check(a).isNotNull();
      check(api.byteFetches).equals(1);
      // A new session (a new cache object) finds it on disk.
      final two = makeContainer(api: api);
      final b = await two
          .read(museyAssetCacheProvider)
          .bytes('/musey/icons/x.png');
      check(b).isNotNull();
      check(api.byteFetches).equals(1);
    });

    test('a missing icon is not stored and returns null', () async {
      final api = _FakeApi(bytes: null);
      final c = makeContainer(api: api);
      check(await c.read(museyAssetCacheProvider).bytes('/musey/icons/n.png'))
          .isNull();
      check(cacheDir.listSync()).isEmpty();
    });
  });

  group('link cards', () {
    test('finds plain and markdown links, not tool output, code or images', () {
      check(extractPreviewUrls('See https://a.test/x. And (https://b.test/y).'))
          .deepEquals(['https://a.test/x', 'https://b.test/y']);
      check(extractPreviewUrls('[The page](https://c.test/p) is good'))
          .deepEquals(['https://c.test/p']);
      check(
        extractPreviewUrls(
          '<details type="tool_calls"><summary>Tool</summary>'
          'result https://tool.test/out</details> done',
        ),
      ).isEmpty();
      check(
        extractPreviewUrls('```\nhttps://code.test\n```\nand `https://i.test`'),
      ).isEmpty();
      check(extractPreviewUrls('![alt](https://img.test/a.png)')).isEmpty();
      check(extractPreviewUrls('ftp://x.test mailto:a@b.test javascript:x'))
          .isEmpty();
      check(extractPreviewUrls('https://a.test/x [again](https://a.test/x)'))
          .deepEquals(['https://a.test/x']);
      check(
        extractPreviewUrls(
          'https://1.test https://2.test https://3.test https://4.test',
        ),
      ).length.equals(3);
      check(extractPreviewUrls('no links here')).isEmpty();
    });

    testWidgets('a card shows image, title and domain, and is cached on disk', (
      tester,
    ) async {
      final api = _FakeApi(
        bytes: _png,
        preview: const LinkPreview(
          title: 'A Zelda page',
          domain: 'zelda.test',
          imageUrl: '/musey/link-image?url=x',
        ),
      );
      final container = makeContainer(api: api);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.dark(TweakcnThemes.t3Chat),
            home: const Scaffold(
              body: LinkPreviewCards(urls: ['https://zelda.test/p']),
            ),
          ),
        ),
      );
      for (var i = 0; i < 4; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
      check(find.text('A Zelda page').evaluate()).length.equals(1);
      check(find.text('zelda.test').evaluate()).length.equals(1);
      check(api.previewUrls).deepEquals(['https://zelda.test/p']);

      // A new session reads the card from disk.
      final again = makeContainer(api: api);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: again,
          child: MaterialApp(
            theme: AppTheme.dark(TweakcnThemes.t3Chat),
            home: const Scaffold(
              body: LinkPreviewCards(urls: ['https://zelda.test/p']),
            ),
          ),
        ),
      );
      for (var i = 0; i < 4; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
      check(find.text('A Zelda page').evaluate()).length.equals(1);
      check(api.previewUrls.length).equals(1);
    });

    testWidgets('an empty answer, a failure or no relay shows nothing', (
      tester,
    ) async {
      for (final api in <MuseyFeedApi?>[
        null,
        _FakeApi(preview: null),
        _ThrowingApi(),
      ]) {
        final container = makeContainer(api: api);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: AppTheme.dark(TweakcnThemes.t3Chat),
              home: const Scaffold(
                body: LinkPreviewCards(urls: ['https://q.test/p']),
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));
        check(tester.takeException()).isNull();
        check(find.byType(Text).evaluate()).isEmpty();
      }
    });

    test('the Dio client never asks about a non-http link', () async {
      // The route guard lives in the client: a non-http URL is refused before
      // any request is built.
      final api = DioMuseyFeedApi(makeContainer().read(_refProvider));
      check(await api.linkPreview('ftp://x.test/a')).isNull();
      check(await api.linkPreview('javascript:alert(1)')).isNull();
    });
  });

  group('routine posts', () {
    test('a post is an assistant message with no user turn before it', () {
      ChatMessage m(String role) => ChatMessage(
        id: role,
        role: role,
        content: 'x',
        timestamp: DateTime(2024),
      );
      final list = [m('assistant'), m('user'), m('assistant'), m('assistant')];
      check(isRoutinePostAt(list, 0)).isTrue();
      check(isRoutinePostAt(list, 1)).isFalse();
      check(isRoutinePostAt(list, 2)).isFalse();
      check(isRoutinePostAt(list, 3)).isTrue();
      check(isRoutinePostAt(list, 9)).isFalse();
    });

    test('Discuss sends the first line, without markdown marks', () {
      check(routinePostDiscussText('\n## **Morning brief**\nMore'))
          .equals("Let's discuss this: Morning brief");
      check(routinePostDiscussText('- one\n- two'))
          .equals("Let's discuss this: one");
    });

    testWidgets('the heart is kept per message id across a restart', (
      tester,
    ) async {
      String? discussed;
      Future<ProviderContainer> mount() async {
        final container = makeContainer();
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: AppTheme.dark(TweakcnThemes.t3Chat),
              localizationsDelegates: conduitLocalizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(
                body: RoutinePostActions(
                  messageId: 'post-1',
                  content: 'Check-in time\nbody',
                  onDiscuss: (t) => discussed = t,
                ),
              ),
            ),
          ),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
        return container;
      }

      var container = await mount();
      check(find.byIcon(CupertinoIcons.heart).evaluate()).length.equals(1);
      await tester.tap(find.byKey(const ValueKey('routine-post-heart')));
      await tester.pump();
      check(find.byIcon(CupertinoIcons.heart_fill).evaluate()).length.equals(1);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );

      await tester.tap(find.byKey(const ValueKey('routine-post-discuss')));
      check(discussed).equals("Let's discuss this: Check-in time");

      // A cold start: a new container reads the hearts back from disk.
      container.dispose();
      container = await mount();
      check(find.byIcon(CupertinoIcons.heart_fill).evaluate()).length.equals(1);
    });
  });

  group('more page and the round buttons', () {
    testWidgets('More lists the three pages and carries the badges', (
      tester,
    ) async {
      final container = makeContainer(failures: 2);
      await mountPage(tester, container, tab: AssistantSheetTab.more);
      check(find.byKey(const ValueKey('musey-more-activity')).evaluate()).length
          .equals(1);
      check(find.byKey(const ValueKey('musey-more-approvals')).evaluate())
          .length
          .equals(1);
      check(find.byKey(const ValueKey('musey-more-appearance')).evaluate())
          .length
          .equals(1);
      // The failure badge is on the More icon of the bar and on its row.
      check(find.byKey(const ValueKey('omni-tab-badge-more')).evaluate()).length
          .equals(1);
      check(find.byKey(const ValueKey('musey-more-badge-Activity')).evaluate())
          .length
          .equals(1);
      // Activity and Approvals are not bar buttons any more.
      check(find.byKey(const ValueKey('omni-tab-activity')).evaluate())
          .isEmpty();
      check(find.byKey(const ValueKey('omni-tab-approvals')).evaluate())
          .isEmpty();
    });

    testWidgets('the top-left button shows a visible hamburger on every page', (
      tester,
    ) async {
      final container = makeContainer(
        api: _FakeApi(),
        settings: const AppSettings(routinesServerUrl: 'https://r.test'),
      );
      for (final tab in [
        AssistantSheetTab.feed,
        AssistantSheetTab.ideas,
        AssistantSheetTab.routines,
        AssistantSheetTab.more,
        AssistantSheetTab.activity,
        AssistantSheetTab.approvals,
        AssistantSheetTab.appearance,
      ]) {
        await mountPage(tester, container, tab: tab);
        final icons = find.descendant(
          of: find.byKey(const ValueKey('assistant-page-menu')),
          matching: find.byType(Icon),
        );
        check(icons.evaluate()).isNotEmpty();
        final icon = tester.widget<Icon>(icons.first);
        check(icon.icon).isNotNull();
        check(icon.icon).equals(CupertinoIcons.line_horizontal_3);
      }
    });

    test('every symbol the bar and pages use has a glyph', () {
      for (final symbol in const [
        'bubble.left',
        'newspaper',
        'lightbulb',
        'alarm',
        'square.grid.2x2',
        'line.3.horizontal',
        'chevron.left',
        'chevron.right',
        'trash',
        'arrow.clockwise',
        'heart',
        'heart.fill',
        'info.circle',
        'list.bullet.rectangle',
        'checkmark.seal',
        'paintpalette',
      ]) {
        check(cupertinoIconForSFSymbol(symbol)).isNotNull();
      }
    });
  });

  group('appearance page', () {
    testWidgets('header, previews in each row, and an even 4 + 4 swatch grid', (
      tester,
    ) async {
      final container = makeContainer(
        settings: const AppSettings(
          routinesServerUrl: '',
          messageBubbles: true,
        ),
      );
      await mountPage(tester, container, tab: AssistantSheetTab.appearance);
      await tester.pump(const Duration(milliseconds: 200));

      check(
        find.byKey(const ValueKey('assistant-appearance-header')).evaluate(),
      ).length.equals(1);
      for (final state in const ['idle', 'working', 'making', 'done']) {
        check(
          find.byKey(ValueKey('assistant-avatar-preview-$state')).evaluate(),
        ).length.equals(1);
        final preview = tester.getRect(
          find.byKey(ValueKey('assistant-avatar-preview-$state')),
        );
        check(preview.left).equals(16);
        check(preview.width).equals(56);
        check(preview.height).equals(56);
        // Choose and Remove are still there.
        check(find.byKey(ValueKey('assistant-avatar-choose-$state')).evaluate())
            .length
            .equals(1);
      }

      // Eight swatches: two rows of four, each in an equal quarter of the
      // width between the 16 pt margins, labels centred.
      const ids = [
        'auto',
        'gray',
        'gold',
        'orange',
        'pink',
        'purple',
        'blue',
        'green',
      ];
      final centers = [
        for (final id in ids)
          tester.getCenter(find.byKey(ValueKey('bubble-color-$id'))),
      ];
      check(centers.map((c) => c.dy).toSet().length).equals(2);
      final width = 393 - 32;
      for (var i = 0; i < 8; i++) {
        final column = i % 4;
        final expected = 16 + width / 4 * (column + 0.5);
        check(centers[i].dx).isCloseTo(expected, 0.5);
        check(centers[i].dy).equals(i < 4 ? centers[0].dy : centers[4].dy);
      }
    });
  });
}

final _refProvider = Provider<Ref>((ref) => ref);
