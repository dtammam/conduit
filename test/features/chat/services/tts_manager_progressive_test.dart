import 'dart:async';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit/features/chat/services/native_tts_service.dart';
import 'package:conduit/features/chat/services/tts_manager.dart';
import 'package:conduit_core/conduit_core.dart';
import 'package:conduit_core/features/chat/server_speech/server_speech.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records what the manager hands the player; plays nothing.
final class _RecordingPlayer extends NullAudioPlayback {
  final List<List<AudioClip>> queues = [];
  final List<AudioClip> appended = [];
  int stops = 0;

  List<AudioClip> get all => [...queues.expand((q) => q), ...appended];

  @override
  Future<void> setClips(
    List<AudioClip> clips, {
    int initialIndex = 0,
    Duration initialPosition = Duration.zero,
  }) async {
    queues.add(List.of(clips));
  }

  @override
  Future<void> addClip(AudioClip clip) async => appended.add(clip);

  @override
  Future<void> stop() async => stops++;
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
  final player = _RecordingPlayer();
  // The manager builds its player once, on first use.
  AudioPlaybackPort.hostFactory = () => player;

  late _HeldSpeech speech;

  setUp(() async {
    speech = _HeldSpeech();
    player.queues.clear();
    player.appended.clear();
    TtsManager.instance.setServerSpeech(speech);
    await TtsManager.instance.debugSetNativeTtsService(_Native());
    await TtsManager.instance.updateConfig(const TtsConfig(preferServer: true));
  });

  tearDown(() async {
    TtsManager.instance.setServerSpeech(null);
    await TtsManager.instance.reset();
    await TtsManager.instance.debugSetNativeTtsService(null);
  });

  test('queues the first sentence while its audio is still arriving', () async {
    await TtsManager.instance.speak(_twoChunks);
    await pumpEventQueue();

    final first = player.all.first;
    check(first.progressive).isNotNull();
    check(first.tag).equals(0);
    // Nothing has closed the body: playback began without waiting for it.
    check(speech.clips.first.isDone).isFalse();
  });

  test('keeps sentence order across streamed clips', () async {
    await TtsManager.instance.speak(_twoChunks);
    await pumpEventQueue();

    final tags = player.all.map((clip) => clip.tag).toList();
    check(tags).deepEquals([0, 1]);
    check(speech.requested.first).contains('Curious');
    check(speech.requested.last).contains('Another');
  });

  test('stopping cancels every stream still arriving', () async {
    await TtsManager.instance.speak(_twoChunks);
    await pumpEventQueue();
    check(speech.clips).isNotEmpty();
    check(speech.clips.every((clip) => clip.isCancelled)).isFalse();

    await TtsManager.instance.stop();

    check(speech.clips.every((clip) => clip.isCancelled)).isTrue();
  });

  test('a barge-in during a streaming session cancels its streams', () async {
    await TtsManager.instance.startStreaming(useServer: true);
    await TtsManager.instance.feedStreamingText(_twoChunks);
    await TtsManager.instance.finishStreaming(finalText: _twoChunks);
    await pumpEventQueue();
    check(speech.clips).isNotEmpty();

    await TtsManager.instance.stopStreaming();

    check(speech.clips.every((clip) => clip.isCancelled)).isTrue();
  });

  test('streaming off keeps the whole-clip path', () async {
    speech.streaming = false;
    // synthesize() answers with bytes, which are written to a temporary file;
    // no progressive clip is ever requested.
    try {
      await TtsManager.instance.speak('Hello there.');
    } catch (_) {}
    await pumpEventQueue();

    check(speech.clips).isEmpty();
    check(player.all.where((clip) => clip.progressive != null)).isEmpty();
  });
}
