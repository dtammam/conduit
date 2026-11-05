import 'dart:async';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit/features/chat/services/native_tts_service.dart';
import 'package:conduit/features/chat/services/speech_take_store.dart';
import 'package:conduit/features/chat/services/tts_manager.dart';
import 'package:conduit_core/conduit_core.dart';
import 'package:conduit_core/features/chat/server_speech/server_speech.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _frame(int fill) => Uint8List(192)
  ..fillRange(4, 192, fill)
  ..setAll(0, [0xff, 0xf3, 0x84, 0xc4]);

Uint8List _audio(int fill, int n) =>
    Uint8List.fromList([for (var i = 0; i < n; i++) ..._frame(fill + i)]);

/// A player the test can finish: it reports "completed" at the last clip.
final class _Player extends NullAudioPlayback {
  final _states = StreamController<AudioPlaybackState>.broadcast();
  int clips = 0;
  AudioProcessingState state = AudioProcessingState.idle;

  @override
  Stream<AudioPlaybackState> get stateChanges => _states.stream;
  @override
  AudioProcessingState get processingState => state;
  @override
  int? get currentIndex => clips - 1;
  @override
  Future<void> setClips(
    List<AudioClip> list, {
    int initialIndex = 0,
    Duration initialPosition = Duration.zero,
  }) async => clips = list.length;
  @override
  Future<void> addClip(AudioClip clip) async => clips++;

  void playToEnd() {
    state = AudioProcessingState.completed;
    _states.add(
      const AudioPlaybackState(
        playing: false,
        processingState: AudioProcessingState.completed,
      ),
    );
  }
}

final class _Speech implements StreamingServerSpeech, SpeechVoiceIdentity {
  String voice = 'direct|m|alloy';
  bool streaming = true;
  final List<ProgressiveAudio> clips = [];
  int rendered = 0;

  @override
  String get voiceKey => voice;
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
  }) async => (bytes: _audio(10 + rendered++ * 10, 2), mimeType: 'audio/mpeg');
  @override
  Future<SpeechClip> synthesizeClip(
    String text, {
    String? preferredVoice,
    double? speed,
  }) async {
    final bytes = _audio(10 + rendered++ * 10, 2);
    final clip = ProgressiveAudio(mimeType: 'audio/mpeg')
      ..add(bytes.sublist(0, 50));
    // The rest arrives a moment later, while the clip already plays.
    unawaited(
      Future<void>(() {
        clip
          ..add(bytes.sublist(50))
          ..close();
      }),
    );
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

const _text =
    'Curious engineers optimize audio boundaries for smoother '
    'conversations. Another sentence follows to verify chunk '
    'merging behavior.';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final player = _Player();
  AudioPlaybackPort.hostFactory = () => player;
  late Directory tmp;
  late SpeechTakeStore store;
  late _Speech speech;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tts_take_');
    // Whole clips are staged in the temporary folder.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => tmp.path,
        );
    store = SpeechTakeStore(
      supportDirectory: () async => tmp,
      excludeFromBackup: (_) async {},
    );
    TtsManager.instance.takeStoreForTesting = store;
    speech = _Speech();
    TtsManager.instance.lastTakeSave = null;
    player
      ..clips = 0
      ..state = AudioProcessingState.idle;
    TtsManager.instance.setServerSpeech(speech);
    await TtsManager.instance.debugSetNativeTtsService(_Native());
    await TtsManager.instance.updateConfig(const TtsConfig(preferServer: true));
    await TtsManager.instance.initialize();
  });

  tearDown(() async {
    TtsManager.instance.setServerSpeech(null);
    await TtsManager.instance.reset();
    await TtsManager.instance.debugSetNativeTtsService(null);
    await tmp.delete(recursive: true);
  });

  Future<SpeechTake?> find({String id = 'm1', String? voice}) => store.find(
    messageId: id,
    voiceKey: voice ?? 'direct|m|alloy',
    text: _text,
  );

  /// The player reports the end of the queue; waits for the save to settle.
  Future<SpeechTake?> finish() async {
    player.playToEnd();
    await pumpEventQueue();
    return TtsManager.instance.lastTakeSave;
  }

  Future<void> listen({String id = 'm1'}) async {
    await TtsManager.instance.speak(
      _text,
      take: SpeechTakeTarget(messageId: id, text: _text),
    );
    await pumpEventQueue();
  }

  test('a reply played to its end is kept as the take', () async {
    await listen();
    check(await find()).isNull();
    final saved = await finish();
    check(saved).isNotNull();
    final take = await find();
    check(take).isNotNull();
    // Two sentences of two frames each, laid end to end.
    check(take!.bytes).equals(4 * 192);
    check(take.file.path).contains('speech_takes');
  });

  test('stopping before the end keeps nothing', () async {
    await listen();
    await TtsManager.instance.stop();
    player.playToEnd();
    await pumpEventQueue();
    check(await find()).isNull();
    check(TtsManager.instance.lastTakeSave).isNull();
  });

  test('a replay that completes replaces the take', () async {
    await listen();
    await finish();
    final first = (await find())!;
    final firstBytes = await first.file.readAsBytes();

    player.state = AudioProcessingState.idle;
    await listen();
    await finish();
    final second = (await find())!;
    check(await second.file.readAsBytes()).not((it) => it.deepEquals(firstBytes));
  });

  test('an interrupted replay leaves the earlier take alone', () async {
    await listen();
    await finish();
    final before = await (await find())!.file.readAsBytes();

    player.state = AudioProcessingState.idle;
    await listen();
    await TtsManager.instance.stop();
    final after = await (await find())!.file.readAsBytes();
    check(after).deepEquals(before);
  });

  test('a reply read in another voice is another take', () async {
    await listen();
    await finish();
    check(await find(voice: 'direct|m|nova')).isNull();
    check(await find()).isNotNull();
  });

  test('a changed text no longer finds the take', () async {
    await listen();
    await finish();
    check(
      await store.find(
        messageId: 'm1',
        voiceKey: 'direct|m|alloy',
        text: '$_text And one more word.',
      ),
    ).isNull();
  });

  test('a read that sets no target keeps nothing (a skip, a snippet)', () async {
    await TtsManager.instance.speak(_text);
    await pumpEventQueue();
    player.playToEnd();
    await pumpEventQueue();
    check(TtsManager.instance.lastTakeSave).isNull();
  });

  test('whole clips (stream speech off) are kept too', () async {
    speech.streaming = false;
    await listen();
    await finish();
    check((await find())!.bytes).equals(4 * 192);
  });

  test('a failing save leaves playback alone', () async {
    // The support folder is gone: nothing can be written.
    await tmp.delete(recursive: true);
    TtsManager.instance.takeStoreForTesting = SpeechTakeStore(
      supportDirectory: () async => Directory('/nonexistent/readonly/x'),
      excludeFromBackup: (_) async {},
    );
    final events = <TtsEvent>[];
    final sub = TtsManager.instance.events.listen(events.add);
    await listen();
    final saved = await finish();
    await sub.cancel();
    check(saved).isNull();
    check(events.whereType<TtsCompleted>()).isNotEmpty();
    check(events.whereType<TtsError>()).isEmpty();
    tmp = await Directory.systemTemp.createTemp('tts_take_');
  });

  group('voice call', () {
    test('a streamed voice reply is kept by its text and voice', () async {
      await TtsManager.instance.startStreaming(useServer: true);
      await TtsManager.instance.feedStreamingText(_text);
      await TtsManager.instance.finishStreaming(finalText: _text);
      await pumpEventQueue();
      final saved = await finish();
      check(saved).isNotNull();
      // Found when the share asks for it by the message that now has it.
      final take = await find(id: 'assistant-9');
      check(take).isNotNull();
      check(take!.bytes).equals(4 * 192);
    });

    test('a barge-in keeps nothing', () async {
      await TtsManager.instance.startStreaming(useServer: true);
      await TtsManager.instance.feedStreamingText(_text);
      await TtsManager.instance.finishStreaming(finalText: _text);
      await pumpEventQueue();
      await TtsManager.instance.stopStreaming();
      player.playToEnd();
      await pumpEventQueue();
      check(await find(id: 'assistant-9')).isNull();
    });
  });
}
