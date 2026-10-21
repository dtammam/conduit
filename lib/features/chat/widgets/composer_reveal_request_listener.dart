import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:conduit_core/features/chat/providers/chat_providers.dart';

import '../../../shared/widgets/sidebar_layout_contract.dart';

/// Brings the chat composer on screen when an external entry point asks.
///
/// The share sheet fills the new-chat composer from outside the widget tree.
/// On phones the chats drawer covers the whole chat page, so a share received
/// while the drawer was open landed in a composer nobody could see. This
/// listener consumes [composerRevealRequestProvider], closes an overlay drawer
/// and re-enables composer autofocus (the drawer turns it off when it opens)
/// so the pending focus request reaches the input.
class ComposerRevealRequestListener extends ConsumerStatefulWidget {
  const ComposerRevealRequestListener({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<ComposerRevealRequestListener> createState() =>
      _ComposerRevealRequestListenerState();
}

class _ComposerRevealRequestListenerState
    extends ConsumerState<ComposerRevealRequestListener> {
  ProviderSubscription<bool>? _subscription;

  @override
  void initState() {
    super.initState();
    // Fire immediately: on a cold start the request can be raised before the
    // chat page is first built.
    _subscription = ref.listenManual<bool>(composerRevealRequestProvider, (
      _,
      requested,
    ) {
      if (!requested) return;
      WidgetsBinding.instance.addPostFrameCallback((_) => _reveal());
    }, fireImmediately: true);
  }

  void _reveal() {
    if (!mounted) return;
    final notifier = ref.read(composerRevealRequestProvider.notifier);
    if (!notifier.consume()) return;
    closeSidebarDrawerIfOverlay(context);
    ref.read(composerAutofocusEnabledProvider.notifier).set(true);
    ref.read(inputFocusTriggerProvider.notifier).increment();
  }

  @override
  void dispose() {
    _subscription?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
