import 'dart:async';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit/features/chat/services/native_tts_service.dart';
import 'package:conduit/features/chat/services/tts_manager.dart';
import 'package:conduit_core/conduit_core.dart';
import 'package:conduit_core/features/chat/server_speech/server_speech.dart';
import 'package:conduit_core/features/chat/voice_mode/voice_event_log.dart';
import 'package:flutter_test/flutter_test.dart';

/// A player that, like the native speech engine, reports when an item's audio
/// has finished playing, separately from index changes.
final class _EnginePlayer extends NullAudioPlayback
    implements AudioItemEndReporting {
  final indices = StreamController<int?>.broadcast();
  final ends = StreamController<int>.broadcast();
  int? gap;

  @override
  Stream<int?> get currentIndexChanges => indices.stream;
  @override
  Stream<int> get itemEnds => ends.stream;
  @override
  bool get endsAreNative => true;
  @override
  int? get lastStartGapMs => gap;
}

/// Streaming speech whose clips the test holds open.
final class _HeldSpeech implements StreamingServerSpeech {
  final List<ProgressiveAudio> clips = [];
  final List<String> requested = [];
  bool streaming = true;

  @override
  ServerSpeechSource get source => ServerSpeechSource.direct;
  @override
  bool get canTranscribe => true;
  @override
  bool get canSynthesize => true;
  @override
  bool get offersVoiceChoice => false;
  @override
  bool get streamsSpeech => streaming;

  @override
  Future<String> transcribe(
    Uint8List audio, {
    required String fileName,
    required String mimeType,
    String? language,
  }) async => '';

  @override
  Future<SynthesizedSpeech> synthesize(
    String text, {
    String? preferredVoice,
    double? speed,
  }) async => (bytes: Uint8List.fromList([1]), mimeType: 'audio/mpeg');

  @override
  Future<SpeechClip> synthesizeClip(
    String text, {
    String? preferredVoice,
    double? speed,
  }) async {
    requested.add(text);
    final clip = ProgressiveAudio(mimeType: 'audio/mpeg')..add([1, 2, 3]);
    clips.add(clip);
    return SpeechClip.progressive(clip);
  }
}

final class _Native extends NativeTtsService {
  @override
  bool get isSupportedPlatform => true;
  @override
  Future<bool> isAvailable() async => true;
  @override
  Stream<NativeTtsEvent> get events => const Stream.empty();
  @override
  Future<List<Map<String, dynamic>>> getVoices() async => const [];
  @override
  Future<bool> stop() async => true;
}


const _twoChunks =
    'Curious engineers optimize audio boundaries for smoother '
    'conversations. Another sentence follows to verify chunk '
    'merging behavior.';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final player = _EnginePlayer();
  AudioPlaybackPort.hostFactory = () => player;

  test('play-end follows the audio-finished event, not the feed end', () async {
    final posted = <Map<String, Object?>>[];
    final speech = _HeldSpeech();
    TtsManager.instance.setServerSpeech(speech);
    await TtsManager.instance.debugSetNativeTtsService(_Native());
    await TtsManager.instance.updateConfig(const TtsConfig(preferServer: true));
    VoiceEventLog.instance.start(
      sender: (body) async {
        posted.add(body);
        return true;
      },
    );
    List<String> kinds() {
      VoiceEventLog.instance.flush();
      return [
        for (final b in posted)
          for (final e in (b['events']! as List).cast<Map<String, Object?>>())
            '${e['kind']}${e.containsKey('part') ? ':${e['part']}' : ''}',
      ];
    }

    Map<String, Object?> event(String kind, int part) => [
      for (final b in posted)
        for (final e in (b['events']! as List).cast<Map<String, Object?>>())
          if (e['kind'] == kind && e['part'] == part) e,
    ].single;

    await TtsManager.instance.initialize();
    await TtsManager.instance.speak(_twoChunks);
    await pumpEventQueue();

    player.indices.add(0);
    await pumpEventQueue();
    // The feed for part 0 ends well before its audio does: no play-end yet.
    for (final clip in speech.clips) {
      clip.close();
    }
    await pumpEventQueue();
    check(kinds()).contains('play-start:0');
    check(kinds()).not((it) => it.contains('play-end:0'));

    player.ends.add(0);
    await pumpEventQueue();
    player.gap = 420;
    player.indices.add(1);
    await pumpEventQueue();

    final seq = kinds().where((k) => k.startsWith('play-')).toList();
    check(seq).deepEquals(['play-start:0', 'play-end:0', 'play-start:1']);
    check(event('play-start', 0).containsKey('gap-ms')).isFalse();
    check(event('play-start', 1)['gap-ms']).equals(420);

    VoiceEventLog.instance.stop();
    TtsManager.instance.setServerSpeech(null);
    await TtsManager.instance.reset();
    await TtsManager.instance.debugSetNativeTtsService(null);
  });
}
