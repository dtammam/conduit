import 'dart:async';

import 'package:flutter/widgets.dart';

import 'package:conduit_core/features/chat/omni/omni_chat.dart';
import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/utils/debug_logger.dart';

/// Keeps the native launch screen (the Musey logo) up on a cold start with the
/// Omni chat on, until that chat is open.
///
/// Without it a cold start painted an empty new chat, then its "Hello Dean"
/// greeting, then switched to the Omni chat a second later. The first frame is
/// held back ([WidgetsBinding.deferFirstFrame]) and let go once the Omni chat
/// is selected, once startup decides not to open it (signed out, offline, a
/// shared payload or notification took the launch), or after [cap] at most.
/// A first-ever launch (no Omni chat stored yet) is not held: there is nothing
/// to wait for that would be quick.
class OmniLaunchGate {
  OmniLaunchGate._();

  static bool _held = false;
  static Timer? _cap;
  static final Stopwatch _clock = Stopwatch();

  /// Whether the first frame is being held right now.
  static bool get isHeld => _held;

  /// Holds the first frame when the Omni chat setting is on and a chat is
  /// stored. Call once, before runApp, after preferences are ready.
  static void holdIfOmni({
    Duration cap = const Duration(milliseconds: 3000),
    WidgetsBinding? binding,
  }) {
    if (_held || !PreferencesStore.isReady) return;
    final enabled =
        PreferencesStore.getBool(PreferenceKeys.omniChatEnabled) ?? true;
    if (!enabled || storedOmniChatId() == null) return;
    _held = true;
    _clock
      ..reset()
      ..start();
    (binding ?? WidgetsBinding.instance).deferFirstFrame();
    _cap = Timer(cap, () => release('cap', binding: binding));
  }

  /// Lets the first frame through. Safe to call any number of times.
  static void release(String reason, {WidgetsBinding? binding}) {
    if (!_held) return;
    _held = false;
    _cap?.cancel();
    _cap = null;
    (binding ?? WidgetsBinding.instance).allowFirstFrame();
    DebugLogger.log(
      'omni-launch-gate',
      scope: 'startup',
      data: {'reason': reason, 'ms': _clock.elapsedMilliseconds},
    );
  }
}
