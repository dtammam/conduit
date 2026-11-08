import 'package:checks/checks.dart';
import 'package:conduit/features/chat/musey/musey_presence.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('presence follows the lifecycle and pings every 60 s', (
    tester,
  ) async {
    final sent = <String>[];
    final presence = MuseyPresence(sent.add)..start();

    // Starts in front: one foreground call at once.
    check(sent).deepEquals(['foreground']);

    await tester.pump(kPresencePing);
    check(sent).deepEquals(['foreground', 'foreground']);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    check(sent.last).equals('background');
    // paused right after inactive adds nothing, and the ping stops.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    final afterBackground = sent.length;
    check(afterBackground).equals(3);
    await tester.pump(kPresencePing * 3);
    check(sent.length).equals(afterBackground);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    check(sent.length).equals(afterBackground + 1);
    check(sent.last).equals('foreground');
    await tester.pump(kPresencePing);
    check(sent.length).equals(afterBackground + 2);
    check(sent.last).equals('foreground');
    presence.dispose();
  });

  testWidgets('a failing send never throws', (tester) async {
    final presence = MuseyPresence((_) => throw StateError('offline'))
      ..start();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    presence.dispose();
  });
}
