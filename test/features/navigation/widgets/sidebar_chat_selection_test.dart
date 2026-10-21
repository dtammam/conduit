import 'package:checks/checks.dart';
import 'package:conduit/features/navigation/widgets/sidebar_page.dart';
import 'package:conduit_core/features/navigation/models/sidebar_navigation_model.dart';
import 'package:conduit_core/features/navigation/providers/sidebar_active_tab_provider.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/folder.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'sidebar_page_test_support.dart';

final _timestamp = DateTime(2024, 1, 1);

Conversation _chat(String id, String title, {String? folderId}) => Conversation(
  id: id,
  title: title,
  createdAt: _timestamp,
  updatedAt: _timestamp,
  lastReadAt: _timestamp,
  folderId: folderId,
  messages: const [],
);

Finder _chatTile(Conversation conversation) => find.byKey(
  ValueKey<String>('drawer-chat-${conversationScopedId(conversation)}'),
);

Finder _chosen(Conversation conversation) => find.byKey(
  ValueKey<String>('drawer-chat-chosen-${conversationScopedId(conversation)}'),
);

Finder _unchosen(Conversation conversation) => find.byKey(
  ValueKey<String>(
    'drawer-chat-unchosen-${conversationScopedId(conversation)}',
  ),
);

const _bar = ValueKey<String>('chats-selection-bar');

void main() {
  final first = _chat('first-chat', 'First Chat');
  final second = _chat('second-chat', 'Second Chat');
  final third = _chat('third-chat', 'Third Chat');

  late SidebarTestSidebarHarnessControllers controllers;

  Future<SidebarTestSidebarApiService> pumpDrawer(
    WidgetTester tester, {
    AppSettings settings = const AppSettings(
      chatMultiSelect: true,
      chatSwipeToDelete: true,
    ),
    Set<String> failing = const <String>{},
  }) async {
    controllers = SidebarTestSidebarHarnessControllers();
    final api = SidebarTestSidebarApiService()
      ..failingConversationIds.addAll(failing);
    await tester.pumpWidget(
      sidebarTestBuildHarness(
        controllers: controllers,
        apiService: api,
        folders: const [Folder(id: 'work', name: 'Work')],
        conversations: [first, second, third],
        settings: settings,
      ),
    );
    await tester.pumpAndSettle();
    return api;
  }

  Future<void> startSelecting(WidgetTester tester, Conversation from) async {
    await tester.longPress(_chatTile(from));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Select'));
    await tester.pumpAndSettle();
  }

  testWidgets('Select in the menu starts selecting with that chat', (
    tester,
  ) async {
    await pumpDrawer(tester);
    check(find.byKey(_bar).evaluate()).isEmpty();

    await startSelecting(tester, second);

    check(find.byKey(_bar).evaluate()).length.equals(1);
    check(find.text('1 selected').evaluate()).length.equals(1);
    check(_chosen(second).evaluate()).length.equals(1);
    check(_unchosen(first).evaluate()).length.equals(1);
    check(_unchosen(third).evaluate()).length.equals(1);
  });

  testWidgets('tapping rows toggles them and updates the count', (
    tester,
  ) async {
    await pumpDrawer(tester);
    await startSelecting(tester, first);

    await tester.tap(_chatTile(third));
    await tester.pump();
    check(find.text('2 selected').evaluate()).length.equals(1);
    check(_chosen(third).evaluate()).length.equals(1);

    await tester.tap(_chatTile(first));
    await tester.pump();
    check(find.text('1 selected').evaluate()).length.equals(1);
    check(_unchosen(first).evaluate()).length.equals(1);

    // A tap selects; it does not open the chat.
    check(container(tester).read(activeConversationProvider)).isNull();
  });

  testWidgets('Move to folder moves every selected chat via the move path', (
    tester,
  ) async {
    final api = await pumpDrawer(tester);
    await startSelecting(tester, first);
    await tester.tap(_chatTile(second));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('chats-selection-move')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Work').last);
    await tester.pumpAndSettle();

    check(api.folderMoves)
        .deepEquals([('first-chat', 'work'), ('second-chat', 'work')]);
    check(find.byKey(_bar).evaluate()).isEmpty();
  });

  testWidgets('Delete asks once for all selected chats, then deletes each', (
    tester,
  ) async {
    final api = await pumpDrawer(tester);
    await startSelecting(tester, first);
    await tester.tap(_chatTile(third));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('chats-selection-delete')));
    await tester.pumpAndSettle();
    check(find.text('Delete 2 chats?').evaluate()).length.equals(1);
    check(api.deletedConversationIds).isEmpty();

    await tester.tap(find.text('Delete').last);
    await tester.pumpAndSettle();

    check(api.deletedConversationIds).deepEquals(['first-chat', 'third-chat']);
    check(find.byKey(_bar).evaluate()).isEmpty();
  });

  testWidgets('Cancel ends selecting and swiping is off meanwhile', (
    tester,
  ) async {
    final api = await pumpDrawer(tester);
    await startSelecting(tester, first);

    final rect = tester.getRect(_chatTile(second));
    final gesture = await tester.startGesture(
      rect.centerLeft + const Offset(40, 0),
    );
    for (var step = 0; step < 12; step++) {
      await gesture.moveBy(Offset(rect.width * 0.05, 0));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await gesture.up();
    await tester.pumpAndSettle();
    check(find.text('Chat deleted').evaluate()).isEmpty();
    check(_chatTile(second).evaluate()).length.equals(1);

    await tester.tap(find.byKey(const ValueKey('chats-selection-cancel')));
    await tester.pumpAndSettle();
    check(find.byKey(_bar).evaluate()).isEmpty();
    check(_unchosen(first).evaluate()).isEmpty();
    await tester.pump(const Duration(seconds: 6));
    check(api.deletedConversationIds).isEmpty();
  });

  testWidgets('switching sidebar tabs ends selecting', (tester) async {
    await pumpDrawer(tester);
    await startSelecting(tester, first);

    container(tester)
        .read(sidebarActiveTabProvider.notifier)
        .set(SidebarTabId.notes);
    await tester.pump();
    container(tester)
        .read(sidebarActiveTabProvider.notifier)
        .set(SidebarTabId.chats);
    await tester.pumpAndSettle();

    check(find.byKey(_bar).evaluate()).isEmpty();
  });

  testWidgets('with the setting off the chat menu has no Select', (
    tester,
  ) async {
    await pumpDrawer(tester, settings: const AppSettings());

    await tester.longPress(_chatTile(first));
    await tester.pumpAndSettle();

    check(find.text('Rename').evaluate()).length.equals(1);
    check(find.text('Select').evaluate()).isEmpty();
  });

  testWidgets('failed deletes are reported together in one dialog', (
    tester,
  ) async {
    final api = await pumpDrawer(
      tester,
      failing: const {'first-chat', 'third-chat'},
    );
    await startSelecting(tester, first);
    await tester.tap(_chatTile(second));
    await tester.tap(_chatTile(third));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('chats-selection-delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete').last);
    await tester.pumpAndSettle();

    check(api.deletedConversationIds).deepEquals(['second-chat']);
    check(find.text('Failed to delete 2 chats').evaluate()).length.equals(1);
    check(find.text('Failed to delete chat').evaluate()).isEmpty();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    check(find.text('Failed to delete 2 chats').evaluate()).isEmpty();
  });

  testWidgets('failed moves are reported together in one dialog', (
    tester,
  ) async {
    final api = await pumpDrawer(
      tester,
      failing: const {'first-chat', 'second-chat'},
    );
    await startSelecting(tester, first);
    await tester.tap(_chatTile(second));
    await tester.tap(_chatTile(third));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('chats-selection-move')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Work').last);
    await tester.pumpAndSettle();

    check(api.folderMoves).deepEquals([('third-chat', 'work')]);
    check(find.text('Failed to move 2 chats').evaluate()).length.equals(1);
    check(find.text('Failed to move chat').evaluate()).isEmpty();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    check(find.text('Failed to move 2 chats').evaluate()).isEmpty();
  });
}

ProviderContainer container(WidgetTester tester) => ProviderScope.containerOf(
  tester.element(find.byType(SidebarPage)),
  listen: false,
);
