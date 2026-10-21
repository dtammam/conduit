import 'package:checks/checks.dart';
import 'package:conduit/features/navigation/widgets/chat_swipe_to_delete.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit/features/navigation/widgets/responsive_drawer_layout.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/folder.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../../shared/widgets/responsive_drawer_layout_test_support.dart';
import 'sidebar_page_test_support.dart';

final _timestamp = DateTime(2024, 1, 1);

Conversation _chat(String id, String title) => Conversation(
  id: id,
  title: title,
  createdAt: _timestamp,
  updatedAt: _timestamp,
  lastReadAt: _timestamp,
  messages: const [],
);

Finder _chatTile(Conversation conversation) => find.byKey(
  ValueKey<String>('drawer-chat-${conversationScopedId(conversation)}'),
);

Finder _swipeRow(Conversation conversation) => find.byKey(
  ValueKey<String>('drawer-chat-swipe-${conversationScopedId(conversation)}'),
);

/// Swipes the swipe row [finder] right by [fraction] of its width, slowly
/// enough not to count as a fling.
Future<void> _swipeRight(
  WidgetTester tester,
  Finder finder,
  double fraction,
) async {
  final rect = tester.getRect(finder);
  final gesture = await tester.startGesture(
    rect.centerLeft + const Offset(20, 0),
  );
  const steps = 12;
  for (var step = 0; step < steps; step++) {
    await gesture.moveBy(Offset(rect.width * fraction / steps, 0));
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.pump(const Duration(milliseconds: 200));
  await gesture.up();
  await tester.pump();
}

void main() {
  tearDown(PlatformUiCapabilities.resetDebugOverrides);

  final chat = _chat('swiped-chat', 'Swiped Chat');
  final otherChat = _chat('other-chat', 'Other Chat');

  Future<SidebarTestSidebarApiService> pumpDrawer(
    WidgetTester tester, {
    AppSettings settings = const AppSettings(chatSwipeToDelete: true),
  }) async {
    final api = SidebarTestSidebarApiService();
    await tester.pumpWidget(
      sidebarTestBuildHarness(
        controllers: SidebarTestSidebarHarnessControllers(),
        apiService: api,
        folders: const [Folder(id: 'work', name: 'Work')],
        conversations: [chat, otherChat],
        settings: settings,
      ),
    );
    await tester.pumpAndSettle();
    return api;
  }

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets('a swipe past the threshold deletes after the undo window '
        '(${platform.name})', (tester) async {
      PlatformUiCapabilities.debugPlatformOverride = platform;
      final api = await pumpDrawer(tester);

      await _swipeRight(tester, _swipeRow(chat), 0.6);
      await tester.pump(const Duration(milliseconds: 300));

      check(_chatTile(chat).evaluate()).isEmpty();
      check(_chatTile(otherChat).evaluate()).length.equals(1);
      check(find.text('Chat deleted').evaluate()).length.equals(1);
      check(api.deletedConversationIds).isEmpty();

      await tester.pump(kChatSwipeDeleteUndoWindow);
      check(api.deletedConversationIds).isEmpty();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();

      check(api.deletedConversationIds).deepEquals(['swiped-chat']);
      // No confirmation dialog: Undo stands in for it.
      check(find.text('Delete Chat').evaluate()).isEmpty();
    });
  }

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets('Undo brings the chat back and never deletes it '
        '(${platform.name})', (tester) async {
      PlatformUiCapabilities.debugPlatformOverride = platform;
      final api = await pumpDrawer(tester);

      await _swipeRight(tester, _swipeRow(chat), 0.6);
      await tester.pump(const Duration(milliseconds: 300));
      check(_chatTile(chat).evaluate()).isEmpty();

      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.text('Undo'));
      await tester.pump();
      check(_chatTile(chat).evaluate()).length.equals(1);

      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
      check(api.deletedConversationIds).isEmpty();
      check(_chatTile(chat).evaluate()).length.equals(1);
    });
  }

  testWidgets('a held chat moved right drags instead of deleting', (
    tester,
  ) async {
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
    final api = await pumpDrawer(
      tester,
      settings: const AppSettings(
        chatSwipeToDelete: true,
        chatDragToFolder: true,
      ),
    );

    final rect = tester.getRect(_swipeRow(chat));
    final gesture = await tester.startGesture(rect.center);
    for (var frame = 0; frame < 44; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    for (var step = 0; step < 8; step++) {
      await gesture.moveBy(Offset(rect.width * 0.06, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    check(find.byKey(const ValueKey<String>('chat-drag-preview')).evaluate())
        .length
        .equals(1);
    await gesture.up();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 6));

    check(find.text('Chat deleted').evaluate()).isEmpty();
    check(api.deletedConversationIds).isEmpty();
    check(api.folderMoves).isEmpty();
  });

  testWidgets('a short swipe springs back without deleting', (tester) async {
    final api = await pumpDrawer(tester);

    await _swipeRight(tester, _swipeRow(chat), 0.2);
    await tester.pumpAndSettle();

    check(_chatTile(chat).evaluate()).length.equals(1);
    check(find.text('Chat deleted').evaluate()).isEmpty();
    await tester.pump(const Duration(seconds: 6));
    check(api.deletedConversationIds).isEmpty();
  });

  testWidgets('leaving the app during the undo window keeps the chat', (
    tester,
  ) async {
    final api = await pumpDrawer(tester);

    await _swipeRight(tester, _swipeRow(chat), 0.6);
    await tester.pump(const Duration(milliseconds: 300));
    check(_chatTile(chat).evaluate()).isEmpty();

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();

    check(_chatTile(chat).evaluate()).length.equals(1);
    check(api.deletedConversationIds).isEmpty();
  });

  group('inside the mobile drawer', () {
    Future<GlobalKey<ResponsiveDrawerLayoutState>> pumpRow(
      WidgetTester tester,
      List<String> deleted,
    ) async {
      final layoutKey = GlobalKey<ResponsiveDrawerLayoutState>();
      await tester.pumpWidget(
        drawerTestBuildHarness(
          size: drawerTestMobileSize,
          layoutKey: layoutKey,
          mobileOpenPanelYieldsRightwardDrags: true,
          drawer: ColoredBox(
            color: Colors.white,
            child: ListView(
              children: [
                ChatSwipeToDelete(
                  onDelete: () => deleted.add('row'),
                  child: const SizedBox(
                    key: ValueKey<String>('row'),
                    height: 56,
                    child: Text('Row'),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await drawerTestOpenDrawer(tester, layoutKey);
      check(layoutKey.currentState!.isOpen).isTrue();
      return layoutKey;
    }

    testWidgets('a right swipe on a row deletes and keeps the drawer open', (
      tester,
    ) async {
      final deleted = <String>[];
      final layoutKey = await pumpRow(tester, deleted);

      await _swipeRight(tester, find.byType(ChatSwipeToDelete), 0.6);
      await tester.pumpAndSettle();

      check(deleted).deepEquals(['row']);
      check(layoutKey.currentState!.isOpen).isTrue();
    });

    testWidgets('a left swipe on a row still closes the drawer', (
      tester,
    ) async {
      final deleted = <String>[];
      final layoutKey = await pumpRow(tester, deleted);

      await tester.drag(
        find.byKey(const ValueKey('row')),
        const Offset(-400, 0),
      );
      await tester.pumpAndSettle();

      check(layoutKey.currentState!.isOpen).isFalse();
      check(deleted).isEmpty();
    });
  });

  testWidgets('with the setting off a right swipe never deletes', (
    tester,
  ) async {
    final api = await pumpDrawer(tester, settings: const AppSettings());

    await _swipeRight(tester, _chatTile(chat), 0.6);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 6));

    check(_chatTile(chat).evaluate()).length.equals(1);
    check(find.text('Chat deleted').evaluate()).isEmpty();
    check(api.deletedConversationIds).isEmpty();
  });

  testWidgets('in RTL the delete background shows beside the moved row', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 300,
              child: ChatSwipeToDelete(
                onDelete: () {},
                child: const SizedBox(
                  width: double.infinity,
                  height: 56,
                  child: Text('Row'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final row = tester.getRect(find.byType(ChatSwipeToDelete));
    final gesture = await tester.startGesture(
      row.centerLeft + const Offset(20, 0),
    );
    for (var step = 0; step < 6; step++) {
      await gesture.moveBy(Offset(row.width * 0.05, 0));
      await tester.pump(const Duration(milliseconds: 50));
    }

    final icon = tester.getRect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('chat-swipe-delete-background')),
        matching: find.byType(Icon),
      ),
    );
    // The row has moved right by about a quarter of its width; the icon
    // sits in the strip it uncovered.
    check(icon.right).isLessThan(row.left + row.width * 0.2);

    await gesture.up();
    await tester.pumpAndSettle();
  });
}
