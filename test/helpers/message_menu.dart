import 'package:conduit/features/chat/widgets/message_action_menu.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Holds a press on the first message past the menu's 400 ms threshold.
Future<void> openMessageMenu(WidgetTester tester, {Finder? on}) async {
  final target = on ?? find.byType(MessageMenuLongPress).first;
  final gesture = await tester.startGesture(tester.getCenter(target));
  await tester.pump(const Duration(milliseconds: 450));
  await gesture.up();
  await tester.pumpAndSettle();
}

/// The menu's action button with this id (reply, copy, tts, share, more,
/// regenerate, retry, delete, edit, usage, fork, merge, view-actions).
Finder menuAction(String id) =>
    find.byKey(ValueKey<String>('message-menu-$id'));

/// Taps an action of the open menu, going through More when it is not on the
/// first row, and lets the menu close.
Future<void> tapMenuAction(WidgetTester tester, String id) async {
  if (menuAction(id).evaluate().isEmpty) {
    await tester.tap(menuAction('more'));
    await tester.pumpAndSettle();
  }
  await tester.tap(menuAction(id));
  await tester.pumpAndSettle();
}

/// Opens the menu and taps [id].
Future<void> chooseFromMessageMenu(
  WidgetTester tester,
  String id, {
  Finder? on,
}) async {
  await openMessageMenu(tester, on: on);
  await tapMenuAction(tester, id);
}
