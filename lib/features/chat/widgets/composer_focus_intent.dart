import 'package:flutter_riverpod/flutter_riverpod.dart';

/// An explicit ask to type: a share into the chat, a Siri or shortcut ask, a
/// quick action, a home-widget attachment. The composer serves it once it is
/// on screen and the launch has settled, with the cursor at the end of any
/// text that was filled in. A cold launch, a resume, a plain open, the Omni
/// launch and a notification open never raise it, so they leave the keyboard
/// down (Dean, 2026-11-05).
final composerFocusIntentProvider = NotifierProvider<ComposerFocusIntent, bool>(
  ComposerFocusIntent.new,
);

class ComposerFocusIntent extends Notifier<bool> {
  @override
  bool build() => false;

  /// Asks the composer to take focus when it can.
  void request() => state = true;

  /// True once, when an ask was waiting.
  bool consume() {
    if (!state) return false;
    state = false;
    return true;
  }
}
