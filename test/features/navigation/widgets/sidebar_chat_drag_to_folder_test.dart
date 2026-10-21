import 'package:checks/checks.dart';
import 'package:conduit/features/navigation/widgets/sidebar_page.dart';
import 'package:conduit/shared/utils/conversation_context_menu.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/features/navigation/providers/drawer_section_notifiers.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/folder.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:flutter/gestures.dart' show kLongPressTimeout;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'sidebar_page_test_support.dart';

final _timestamp = DateTime(2024, 1, 1);

Conversation _chat(String id, String title, {String? folderId}) {
  return Conversation(
    id: id,
    title: title,
    createdAt: _timestamp,
    updatedAt: _timestamp,
    lastReadAt: _timestamp,
    folderId: folderId,
    messages: const [],
  );
}

Finder _chatTile(Conversation conversation) => find.byKey(
  ValueKey<String>('drawer-chat-${conversationScopedId(conversation)}'),
);

Finder _folderRow(String folderId) =>
    find.byKey(ValueKey<String>('folder-open-$folderId'));

const _preview = ValueKey<String>('chat-drag-preview');

/// Pumps frame by frame, as a device would, so menu animations keep time.
Future<void> _pumpFrames(WidgetTester tester, Duration duration) async {
  const frame = Duration(milliseconds: 16);
  var elapsed = Duration.zero;
  while (elapsed < duration) {
    await tester.pump(frame);
    elapsed += frame;
  }
}

/// Holds [from] into the drag window (after the hold delay, before the menu
/// opens), then drags to [to] in small steps.
Future<TestGesture> _holdAndDrag(
  WidgetTester tester,
  Offset from,
  Offset to,
) async {
  final gesture = await tester.startGesture(from);
  await _pumpFrames(
    tester,
    kConduitContextMenuHoldDragDelay + const Duration(milliseconds: 100),
  );
  const steps = 8;
  for (var step = 1; step <= steps; step++) {
    await gesture.moveTo(Offset.lerp(from, to, step / steps)!);
    await tester.pump(const Duration(milliseconds: 16));
  }
  return gesture;
}

void main() {
  tearDown(PlatformUiCapabilities.resetDebugOverrides);

  final looseChat = _chat('loose-chat', 'Loose Chat');
  const workFolder = Folder(id: 'work', name: 'Work', isExpanded: false);

  Future<SidebarTestSidebarApiService> pumpDrawer(
    WidgetTester tester, {
    List<Conversation>? conversations,
    List<Folder> folders = const [workFolder],
    bool dragToFolder = true,
  }) async {
    final api = SidebarTestSidebarApiService();
    await tester.pumpWidget(
      sidebarTestBuildHarness(
        controllers: SidebarTestSidebarHarnessControllers(),
        apiService: api,
        folders: folders,
        conversations: conversations ?? [looseChat],
        settings: AppSettings(chatDragToFolder: dragToFolder),
      ),
    );
    await tester.pumpAndSettle();
    return api;
  }

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets(
      'dropping a held chat on a folder moves it through the move path '
      '(${platform.name})',
      (tester) async {
        PlatformUiCapabilities.debugPlatformOverride = platform;
        final api = await pumpDrawer(tester);

        final gesture = await _holdAndDrag(
          tester,
          tester.getCenter(_chatTile(looseChat)),
          tester.getCenter(_folderRow('work')),
        );

        check(find.byKey(_preview).evaluate()).length.equals(1);
        check(
          find
              .byKey(const ValueKey<String>('chat-drop-highlight-work'))
              .evaluate(),
        ).length.equals(1);

        await gesture.up();
        await tester.pumpAndSettle();

        check(api.folderMoves).deepEquals([('loose-chat', 'work')]);
        check(find.byKey(_preview).evaluate()).isEmpty();
        // The menu the hold began to open is gone.
        check(find.text('Rename').evaluate()).isEmpty();
      },
    );
  }

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets('moving after the menu opened never drags (${platform.name})', (
      tester,
    ) async {
      PlatformUiCapabilities.debugPlatformOverride = platform;
      final api = await pumpDrawer(tester);

      final from = tester.getCenter(_chatTile(looseChat));
      final gesture = await tester.startGesture(from);
      await _pumpFrames(tester, const Duration(milliseconds: 1300));
      check(find.text('Rename').evaluate()).length.equals(1);

      // Opening the menu pushed a route, which cancels the held pointer.
      await gesture.moveBy(const Offset(0, 80));
      await tester.pump();
      check(find.byKey(_preview).evaluate()).isEmpty();
      await gesture.up();
      await tester.pumpAndSettle();

      check(find.byKey(_preview).evaluate()).isEmpty();
      check(api.folderMoves).isEmpty();
    });
  }

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets('holding a chat still opens the menu (${platform.name})', (
      tester,
    ) async {
      PlatformUiCapabilities.debugPlatformOverride = platform;
      final api = await pumpDrawer(tester);

      final gesture = await tester.startGesture(
        tester.getCenter(_chatTile(looseChat)),
      );
      await _pumpFrames(tester, const Duration(milliseconds: 1300));
      await gesture.up();
      await tester.pumpAndSettle();

      check(find.text('Rename').evaluate()).length.equals(1);
      check(find.byKey(_preview).evaluate()).isEmpty();
      check(api.folderMoves).isEmpty();
    });
  }

  testWidgets('lifting a recognized long press opens the menu at once', (
    tester,
  ) async {
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.android;
    final api = await pumpDrawer(tester);

    final gesture = await tester.startGesture(
      tester.getCenter(_chatTile(looseChat)),
    );
    await _pumpFrames(tester, const Duration(milliseconds: 600));
    check(find.text('Rename').evaluate()).isEmpty();
    await gesture.up();
    await tester.pumpAndSettle();

    check(find.text('Rename').evaluate()).length.equals(1);
    check(api.folderMoves).isEmpty();
  });

  testWidgets('a quick vertical drag scrolls and never starts a chat drag', (
    tester,
  ) async {
    final chats = [
      for (var index = 0; index < 30; index++)
        _chat('chat-$index', 'Chat $index'),
    ];
    final api = await pumpDrawer(tester, conversations: chats);
    final scrollable = find
        .descendant(
          of: find.byType(SidebarPage),
          matching: find.byType(Scrollable),
        )
        .first;
    final position = tester.state<ScrollableState>(scrollable).position;
    check(position.pixels).equals(0);

    final gesture = await tester.startGesture(
      tester.getCenter(_chatTile(chats[5])),
    );
    for (var step = 0; step < 10; step++) {
      await gesture.moveBy(const Offset(0, -20));
      await tester.pump(const Duration(milliseconds: 16));
    }
    // Resting after the scroll took the pointer must not turn into a drag.
    await tester.pump(const Duration(milliseconds: 700));
    await gesture.moveBy(const Offset(0, -40));
    await tester.pump();
    check(find.byKey(_preview).evaluate()).isEmpty();
    await gesture.up();
    await tester.pumpAndSettle();

    check(position.pixels).isGreaterThan(0);
    check(api.folderMoves).isEmpty();
  });

  testWidgets('dropping on Recent takes a chat out of its folder', (
    tester,
  ) async {
    final folderedChat = _chat('filed-chat', 'Filed Chat', folderId: 'work');
    final api = await pumpDrawer(
      tester,
      conversations: [looseChat, folderedChat],
      folders: const [Folder(id: 'work', name: 'Work', isExpanded: true)],
    );

    final gesture = await _holdAndDrag(
      tester,
      tester.getCenter(_chatTile(folderedChat)),
      tester.getCenter(find.text('Recent')),
    );
    check(
      find
          .byKey(const ValueKey<String>('chat-drop-highlight-top-level'))
          .evaluate(),
    ).length.equals(1);
    await gesture.up();
    await tester.pumpAndSettle();

    check(api.folderMoves).deepEquals([('filed-chat', null)]);
  });

  testWidgets('dropping away from a target changes nothing', (tester) async {
    final api = await pumpDrawer(tester);

    final gesture = await _holdAndDrag(
      tester,
      tester.getCenter(_chatTile(looseChat)),
      tester.getCenter(find.text('Folders')),
    );
    check(find.byKey(_preview).evaluate()).length.equals(1);
    await gesture.up();
    await tester.pumpAndSettle();

    check(api.folderMoves).isEmpty();
    check(find.byKey(_preview).evaluate()).isEmpty();
  });

  testWidgets('resting on a collapsed folder expands it', (tester) async {
    await pumpDrawer(tester);

    final gesture = await _holdAndDrag(
      tester,
      tester.getCenter(_chatTile(looseChat)),
      tester.getCenter(_folderRow('work')),
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(SidebarPage)),
      listen: false,
    );
    check(container.read(expandedFoldersProvider)['work'])
        .not((it) => it.equals(true));
    await tester.pump(const Duration(milliseconds: 700));
    check(container.read(expandedFoldersProvider)['work']).equals(true);

    await gesture.cancel();
    await tester.pumpAndSettle();
  });

  testWidgets('a chat held near the bottom edge scrolls the list', (
    tester,
  ) async {
    final chats = [
      for (var index = 0; index < 30; index++)
        _chat('chat-$index', 'Chat $index'),
    ];
    await pumpDrawer(tester, conversations: chats);
    final scrollable = find
        .descendant(
          of: find.byType(SidebarPage),
          matching: find.byType(Scrollable),
        )
        .first;
    final position = tester.state<ScrollableState>(scrollable).position;
    final viewport = tester.getRect(scrollable);

    final gesture = await _holdAndDrag(
      tester,
      tester.getCenter(_chatTile(chats[3])),
      Offset(viewport.center.dx, viewport.bottom - 4),
    );
    for (var frame = 0; frame < 20; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    check(position.pixels).isGreaterThan(0);

    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('with the setting off the Android menu opens without delay', (
    tester,
  ) async {
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.android;
    final api = await pumpDrawer(tester, dragToFolder: false);

    final gesture = await tester.startGesture(
      tester.getCenter(_chatTile(looseChat)),
    );
    await _pumpFrames(
      tester,
      kLongPressTimeout + const Duration(milliseconds: 100),
    );
    check(find.text('Rename').evaluate()).length.equals(1);
    await gesture.up();
    await tester.pumpAndSettle();

    check(api.folderMoves).isEmpty();
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets(
      'with the setting off a held chat never drags (${platform.name})',
      (tester) async {
        PlatformUiCapabilities.debugPlatformOverride = platform;
        final api = await pumpDrawer(tester, dragToFolder: false);

        final gesture = await _holdAndDrag(
          tester,
          tester.getCenter(_chatTile(looseChat)),
          tester.getCenter(_folderRow('work')),
        );
        check(find.byKey(_preview).evaluate()).isEmpty();
        await gesture.up();
        await tester.pumpAndSettle();

        check(api.folderMoves).isEmpty();
      },
    );
  }
}
