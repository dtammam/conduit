import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'musey_feed_api.dart';

/// How often the foreground state is repeated, so the relay can tell a phone
/// that was killed or lost its network from one that is still open.
const Duration kPresencePing = Duration(seconds: 60);

/// Tells the relay when the app is in front and when it is away, so a finished
/// reply becomes a push only while he is away. "foreground" on resume and
/// every [kPresencePing] while in front; "background" the moment the app goes
/// inactive or paused (the call goes out first, before iOS suspends the app).
final museyPresenceProvider = Provider<void>((ref) {
  final presence = MuseyPresence((state) {
    unawaited(ref.read(museyFeedApiProvider)?.presence(state));
  });
  presence.start();
  ref.onDispose(presence.dispose);
});

class MuseyPresence with WidgetsBindingObserver {
  MuseyPresence(this._send);

  final void Function(String state) _send;
  Timer? _timer;
  bool _foreground = false;

  void start() {
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    if (state == null || state == AppLifecycleState.resumed) _enter();
  }

  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _timer = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _enter();
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        _leave();
      case AppLifecycleState.detached:
        break;
    }
  }

  void _enter() {
    _timer?.cancel();
    _foreground = true;
    _safeSend('foreground');
    _timer = Timer.periodic(kPresencePing, (_) {
      if (_foreground) _safeSend('foreground');
    });
  }

  void _leave() {
    _timer?.cancel();
    _timer = null;
    // inactive then paused arrive in a row; one background call is enough.
    if (!_foreground) return;
    _foreground = false;
    _safeSend('background');
  }

  void _safeSend(String state) {
    try {
      _send(state);
    } catch (_) {}
  }
}
