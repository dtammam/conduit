import 'package:checks/checks.dart';
import 'package:conduit/features/chat/widgets/composer_reveal_request_listener.dart';
import 'package:conduit/features/navigation/widgets/responsive_drawer_layout.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../../shared/widgets/responsive_drawer_layout_test_support.dart';

void main() {
  Widget harness(
    ProviderContainer container,
    GlobalKey<ResponsiveDrawerLayoutState> layoutKey, {
    Size size = drawerTestMobileSize,
  }) {
    return UncontrolledProviderScope(
      container: container,
      child: drawerTestBuildHarness(
        size: size,
        layoutKey: layoutKey,
        // Mirrors DrawerShellPage: opening the drawer turns autofocus off.
        onOpenStart: () => container
            .read(composerAutofocusEnabledProvider.notifier)
            .set(false),
        child: const ComposerRevealRequestListener(
          child: SizedBox.expand(key: ValueKey('chat-page')),
        ),
      ),
    );
  }

  testWidgets('a share received behind the open drawer closes it and focuses '
      'the composer', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final layoutKey = GlobalKey<ResponsiveDrawerLayoutState>();

    await tester.pumpWidget(harness(container, layoutKey));
    layoutKey.currentState!.open();
    await tester.pumpAndSettle();
    check(layoutKey.currentState!.isOpen).isTrue();
    check(container.read(composerAutofocusEnabledProvider)).isFalse();
    final focusTickBefore = container.read(inputFocusTriggerProvider);

    container.read(composerRevealRequestProvider.notifier).request();
    await tester.pumpAndSettle();

    check(layoutKey.currentState!.isOpen).isFalse();
    check(container.read(composerRevealRequestProvider)).isFalse();
    check(container.read(composerAutofocusEnabledProvider)).isTrue();
    check(container.read(inputFocusTriggerProvider))
        .isGreaterThan(focusTickBefore);
  });

  testWidgets('a request raised before the chat page mounts is honored', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final layoutKey = GlobalKey<ResponsiveDrawerLayoutState>();

    // Cold start: the share is processed before the chat page first builds.
    container.read(composerRevealRequestProvider.notifier).request();
    final focusTickBefore = container.read(inputFocusTriggerProvider);

    await tester.pumpWidget(harness(container, layoutKey));
    await tester.pumpAndSettle();

    check(container.read(composerRevealRequestProvider)).isFalse();
    check(layoutKey.currentState!.isOpen).isFalse();
    check(container.read(inputFocusTriggerProvider))
        .isGreaterThan(focusTickBefore);
  });

  testWidgets('the persistent tablet sidebar stays docked', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final layoutKey = GlobalKey<ResponsiveDrawerLayoutState>();

    await tester.pumpWidget(
      harness(container, layoutKey, size: drawerTestTabletSize),
    );
    await tester.pumpAndSettle();
    check(layoutKey.currentState!.isOpen).isTrue();

    container.read(composerRevealRequestProvider.notifier).request();
    await tester.pumpAndSettle();

    check(layoutKey.currentState!.isOpen).isTrue();
    check(container.read(composerRevealRequestProvider)).isFalse();
  });
}
