import 'package:checks/checks.dart';
import 'package:conduit_core/features/chat/voice_mode/voice_working_sound.dart';
import 'package:test/test.dart';

final class _FakePlayer implements VoiceWorkingSoundPlayer {
  final log = <String>[];
  var playing = false;

  @override
  Future<void> start() async {
    log.add('start');
    playing = true;
  }

  @override
  Future<void> stop() async {
    log.add('stop');
    playing = false;
  }
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  late _FakePlayer player;
  late VoiceWorkingSound sound;

  setUp(() {
    player = _FakePlayer();
    sound = VoiceWorkingSound(player);
  });

  test('a tool turn handed to Open WebUI starts the loop', () async {
    sound.handoff(enabled: true, muted: false);
    await _settle();
    check(player.playing).isTrue();
    check(player.log).deepEquals(['start']);
  });

  test('the first speech of the reply stops it', () async {
    sound.handoff(enabled: true, muted: false);
    await _settle();
    sound.speechStarted();
    await _settle();
    check(player.playing).isFalse();
    check(player.log).deepEquals(['start', 'stop']);
    // later speech does nothing more
    sound.speechStarted();
    sound.speechEnded();
    await _settle();
    check(player.log).deepEquals(['start', 'stop']);
  });

  test('turn end, failure, barge-in and call end stop it', () async {
    for (final reason in ['done', 'failed', 'barge-in', 'call-end']) {
      player.log.clear();
      sound.handoff(enabled: true, muted: false);
      await _settle();
      check(player.playing).isTrue();
      sound.stop(reason);
      await _settle();
      check(player.playing).isFalse();
      check(sound.isActive).isFalse();
      // a second stop is harmless
      sound.stop(reason);
      await _settle();
      check(player.log).deepEquals(['start', 'stop']);
    }
  });

  test('muted: silent, and back when unmuted while still waiting', () async {
    sound.handoff(enabled: true, muted: true);
    await _settle();
    check(player.log).isEmpty();
    sound.mute(false);
    await _settle();
    check(player.playing).isTrue();
    sound.mute(true);
    await _settle();
    check(player.playing).isFalse();
    sound.mute(false);
    await _settle();
    check(player.playing).isTrue();
    sound.stop('done');
    sound.mute(false);
    await _settle();
    check(player.playing).isFalse();
  });

  test('the setting off keeps it silent', () async {
    sound.handoff(enabled: false, muted: false);
    await _settle();
    check(player.log).isEmpty();
    check(sound.isActive).isFalse();
  });

  test('a spoken ack plays first, the loop starts after it ends', () async {
    sound.handoff(enabled: true, muted: false, ackSpoken: true);
    await _settle();
    check(player.log).isEmpty();
    // the ack's own speech starting is not the reply
    sound.speechStarted();
    await _settle();
    check(player.log).isEmpty();
    check(sound.isActive).isTrue();
    sound.speechEnded();
    await _settle();
    check(player.playing).isTrue();
    // the reply's first audio stops it
    sound.speechStarted();
    await _settle();
    check(player.playing).isFalse();
  });

  test('an ack that runs into the reply never starts the loop', () async {
    sound.handoff(enabled: true, muted: false, ackSpoken: true);
    sound.speechStarted();
    await _settle();
    sound.stop('done');
    await _settle();
    check(player.log).isEmpty();
  });

  test('a player that throws never breaks the call', () async {
    final broken = VoiceWorkingSound(_ThrowingPlayer());
    broken.handoff(enabled: true, muted: false);
    await _settle();
    broken.stop('done');
    await _settle();
    check(broken.isActive).isFalse();
  });

  test('no player (a host without one) is silent', () async {
    final none = VoiceWorkingSound(null);
    none.handoff(enabled: true, muted: false);
    check(none.isActive).isFalse();
  });
}

final class _ThrowingPlayer implements VoiceWorkingSoundPlayer {
  @override
  Future<void> start() async => throw StateError('no audio');
  @override
  Future<void> stop() async => throw StateError('no audio');
}
