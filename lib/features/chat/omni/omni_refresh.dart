import 'dart:async';

import 'package:conduit_core/database/local_conversation_loader.dart';
import 'package:conduit_core/features/chat/omni/omni_chat.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/services/socket_service.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// How long after a posted message arrives the chat is fetched, so a burst of
/// events becomes one fetch.
const Duration kOmniRefreshDebounce = Duration(milliseconds: 800);

/// Whether [event] is a message the server posted into chat [omniChatId]
/// (Open WebUI's `chat:message` event), as a routine's reply is.
bool isOmniPostEvent(Map<String, dynamic> event, String? omniChatId) {
  if (omniChatId == null || omniChatId.isEmpty) return false;
  if (event['chat_id']?.toString() != omniChatId) return false;
  final envelope = event['data'];
  return envelope is Map && envelope['type'] == 'chat:message';
}

/// Keeps the Omni chat current: a routine posts its reply into the chat on
/// the server, and the app fetches the chat when it comes to the foreground
/// and when that post's event arrives, so the message shows up without
/// leaving and re-entering the chat.
final omniRefreshProvider = NotifierProvider<OmniRefresh, void>(
  OmniRefresh.new,
);

class OmniRefresh extends Notifier<void> with WidgetsBindingObserver {
  SocketEventSubscription? _subscription;
  Timer? _debounce;

  @override
  void build() {
    WidgetsBinding.instance.addObserver(this);
    ref.onDispose(() {
      WidgetsBinding.instance.removeObserver(this);
      _subscription?.dispose();
      _debounce?.cancel();
    });
    _bind(ref.read(socketServiceProvider));
    ref.listen<SocketService?>(socketServiceProvider, (_, next) => _bind(next));
  }

  void _bind(SocketService? socket) {
    _subscription?.dispose();
    _subscription = socket?.addChatEventHandler(
      requireFocus: false,
      handler: (event, _) => _onEvent(event),
    );
  }

  void _onEvent(Map<String, dynamic> event) {
    if (!isOmniPostEvent(event, storedOmniChatId())) return;
    _debounce?.cancel();
    _debounce = Timer(kOmniRefreshDebounce, refresh);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) refresh();
  }

  /// Fetches the Omni chat from the server. The open chat adopts the result
  /// through its database watch.
  void refresh() {
    if (!ref.mounted || !ref.read(appSettingsProvider).omniChatEnabled) return;
    final id = storedOmniChatId();
    if (id == null || id.isEmpty) return;
    // The reply being written right now is this app's own; fetching the chat
    // under it would only race it.
    if (ref.read(activeConversationProvider)?.id == id &&
        ref.read(chatMessagesProvider).any((m) => m.isStreaming)) {
      return;
    }
    schedulePullChatNow(ref, id);
  }
}
