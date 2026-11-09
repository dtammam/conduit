/// The soft loop played in a voice call while a tool turn runs on the Open
/// WebUI path (the realtime socket answered route "owui" and closed). It
/// starts at the hand-off, or after the spoken ack has ended, and stops at the
/// first speech of the reply, when the turn ends or fails, when the user
/// speaks, and when the call ends. It never plays under Bobby's speech, and
/// stays silent while the call is muted.
library;

import 'dart:async';

import 'package:riverpod/riverpod.dart';

/// Plays and stops the bundled loop. The host implements it (iOS and Android
/// through `just_audio`, without taking over the call's audio session).
abstract interface class VoiceWorkingSoundPlayer {
  Future<void> start();
  Future<void> stop();
}

/// The host's loop player. Null (the default) keeps tool turns silent; tests
/// override it with a fake.
final voiceWorkingSoundPlayerProvider = Provider<VoiceWorkingSoundPlayer?>(
  (ref) => null,
);

enum _Phase { idle, waitingForAck, waiting }

final class VoiceWorkingSound {
  VoiceWorkingSound(this._player);

  final VoiceWorkingSoundPlayer? _player;
  var _phase = _Phase.idle;
  var _muted = false;
  var _audible = false;
  Future<void> _chain = Future<void>.value();

  /// A tool turn is being waited on and the loop is wanted (it may be silent
  /// while the ack speaks or the call is muted).
  bool get isActive => _phase != _Phase.idle;

  /// The loop is sounding now (as far as the last command to the player).
  bool get isAudible => _audible;

  /// The socket handed the turn to the Open WebUI path. With [ackSpoken] the
  /// loop waits for the ack's speech to end.
  void handoff({
    required bool enabled,
    required bool muted,
    bool ackSpoken = false,
  }) {
    if (!enabled || _player == null) return;
    _muted = muted;
    _phase = ackSpoken ? _Phase.waitingForAck : _Phase.waiting;
    _sync();
  }

  /// A clip of speech started. The reply's first audio ends the loop; the
  /// ack's own start is not the reply.
  void speechStarted() {
    if (_phase == _Phase.waiting) stop('speech');
  }

  /// The speech queue ran dry: after an ack, the wait for the tool begins.
  void speechEnded() {
    if (_phase != _Phase.waitingForAck) return;
    _phase = _Phase.waiting;
    _sync();
  }

  void mute(bool muted) {
    if (_muted == muted) return;
    _muted = muted;
    _sync();
  }

  void stop([String reason = 'stop']) {
    if (_phase == _Phase.idle && !_audible) return;
    _phase = _Phase.idle;
    _sync();
  }

  void _sync() {
    _chain = _chain.then((_) async {
      final want = _phase == _Phase.waiting && !_muted;
      final player = _player;
      if (player == null || want == _audible) return;
      _audible = want;
      try {
        if (want) {
          await player.start();
        } else {
          await player.stop();
        }
      } catch (_) {
        // A loop that cannot play is only a missing nicety.
      }
    });
  }
}
