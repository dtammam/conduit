import 'package:checks/checks.dart';
import 'package:conduit/features/navigation/widgets/chat_swipe_to_delete.dart';
import 'package:conduit/features/navigation/widgets/omni_chat_row.dart';
import 'package:conduit_core/features/chat/omni/omni_chat.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/providers/app_providers.dart'
    show conversationScopedId;
import 'package:conduit_core/services/settings_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'sidebar_page_test_support.dart';

final _timestamp = DateTime(2024, 1, 1);

Conversation _chat(String id, String title, {bool pinned = false}) =>
    Conversation(
      id: id,
      title: title,
      createdAt: _timestamp,
      updatedAt: _timestamp,
      lastReadAt: _timestamp,
      pinned: pinned,
      messages: const [],
    );

ValueKey<String> _tileKey(Conversation c) =>
    ValueKey<String>('drawer-chat-${conversationScopedId(c)}');

void main() {
  final omni = _chat('omni-chat', 'Omni');
  final pinnedChat = _chat('pinned-chat', 'Pinned Chat', pinned: true);
  final recentChat = _chat('recent-chat', 'Recent Chat');

  Future<void> pumpDrawer(
    WidgetTester tester, {
    required bool omniOn,
    List<Conversation>? conversations,
  }) async {
    await tester.pumpWidget(
      sidebarTestBuildHarness(
        controllers: SidebarTestSidebarHarnessControllers(),
        conversations: conversations ?? [omni, pinnedChat, recentChat],
        settings: AppSettings(omniChatEnabled: omniOn, chatSwipeToDelete: true),
        extraOverrides: [
          omniChatProvider.overrideWith((ref) async => omniOn ? omni : null),
        ],
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the Omni chat is pinned above every other row', (tester) async {
    await pumpDrawer(tester, omniOn: true);

    final row = find.byKey(const ValueKey<String>('drawer-omni-chat'));
    check(row.evaluate()).length.equals(1);
    check(find.byType(OmniChatRow).evaluate()).length.equals(1);
    final omniTop = tester.getTopLeft(row).dy;
    final pinnedTop = tester.getTopLeft(find.byKey(_tileKey(pinnedChat))).dy;
    final recentTop = tester.getTopLeft(find.byKey(_tileKey(recentChat))).dy;
    check(omniTop).isLessThan(pinnedTop);
    check(omniTop).isLessThan(recentTop);
  });

  testWidgets('the Omni chat is not listed a second time', (tester) async {
    await pumpDrawer(tester, omniOn: true);

    check(find.byKey(_tileKey(omni)).evaluate()).isEmpty();
  });

  testWidgets('the pinned row cannot be swiped away', (tester) async {
    await pumpDrawer(tester, omniOn: true);

    final row = find.byKey(const ValueKey<String>('drawer-omni-chat'));
    check(
      find
          .descendant(of: row, matching: find.byType(ChatSwipeToDelete))
          .evaluate(),
    ).isEmpty();
    check(
      find
          .ancestor(of: row, matching: find.byType(ChatSwipeToDelete))
          .evaluate(),
    ).isEmpty();
  });

  testWidgets('with the setting off there is no Omni row', (tester) async {
    await pumpDrawer(
      tester,
      omniOn: false,
      conversations: [omni, pinnedChat, recentChat],
    );

    check(find.byKey(const ValueKey<String>('drawer-omni-chat')).evaluate())
        .isEmpty();
    // Off means an ordinary chat again.
    check(find.byKey(_tileKey(omni)).evaluate()).length.equals(1);
  });
}
