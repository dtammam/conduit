import 'package:conduit_core/features/chat/voice_mode/voice_working_sound.dart';
import 'package:just_audio/just_audio.dart';

/// The soft loop for tool turns in a voice call (`assets/sounds/working_loop.wav`,
/// one seamless period at 24 kHz mono), played through `just_audio` at about
/// -18 dB. The player does not touch the call's audio session: the call owns
/// its category, voice processing and routing.
class JustAudioWorkingSound implements VoiceWorkingSoundPlayer {
  JustAudioWorkingSound({AudioPlayer? player})
    : _player =
          player ??
          AudioPlayer(
            handleInterruptions: false,
            handleAudioSessionActivation: false,
          );

  /// 10^(-18/20): the loop sits about 18 dB under the file's own level.
  static const double gain = 0.126;
  static const String asset = 'assets/sounds/working_loop.wav';

  final AudioPlayer _player;
  Future<void>? _loaded;

  Future<void> _load() => _loaded ??= () async {
    await _player.setAsset(asset);
    await _player.setLoopMode(LoopMode.one);
    await _player.setVolume(gain);
  }();

  @override
  Future<void> start() async {
    try {
      await _load();
    } catch (_) {
      _loaded = null;
      rethrow;
    }
    await _player.seek(Duration.zero);
    // `play` completes when playback ends; a loop only ends at `pause`.
    _player.play().ignore();
  }

  @override
  Future<void> stop() async {
    await _player.pause();
  }
}
