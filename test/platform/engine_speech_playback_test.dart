import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit/platform/engine_speech_playback.dart';
import 'package:conduit_core/conduit_core.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// A relay-style MP3 file: ID3 tag, then [frames] 384-byte frames.
Uint8List _piece(int frames) {
  final out = BytesBuilder()
    ..add([0x49, 0x44, 0x33, 4, 0, 0, 0, 0, 0, 0]);
  for (var i = 0; i < frames; i++) {
    out.add(Uint8List(384)..setAll(0, [0xff, 0xf3, 0xc4, 0xc4]));
  }
  return out.takeBytes();
}

class _Files implements AudioPlaybackPort {
  final calls = <String>[];
  List<AudioClip> lastClips = const [];
  @override
  Stream<AudioPlaybackState> get stateChanges => const Stream.empty();
  @override
  Stream<int?> get currentIndexChanges => const Stream.empty();
  @override
  int? get currentIndex => null;
  @override
  AudioProcessingState get processingState => AudioProcessingState.idle;
  @override
  Future<void> setClips(
    List<AudioClip> clips, {
    int initialIndex = 0,
    Duration initialPosition = Duration.zero,
  }) async {
    lastClips = clips;
    calls.add('setClips ${clips.length}');
  }
  @override
  Future<void> addClip(AudioClip clip) async => calls.add('addClip');
  @override
  Future<void> clearClips() async {}
  @override
  Future<void> play() async => calls.add('play');
  @override
  Future<void> pause() async {}
  @override
  Future<void> stop() async => calls.add('stop');
  @override
  Future<void> seek(Duration? position, {int? index}) async {}
  @override
  Future<void> setSpeed(double speed) async {}
  @override
  Future<void> dispose() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(EngineSpeechPlayback.channelName);
  late List<String> calls;

  setUp(() {
    calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          final args = call.arguments as Map?;
          calls.add(switch (call.method) {
            'appendPiece' =>
              'append ${args!['item']} ${(args['bytes'] as Uint8List).length}'
                  '${args['trim'] == true ? ' trim' : ''}',
            'finishItem' => 'finish ${args!['item']}',
            'seek' => 'seek ${args!['item']}',
            _ => call.method,
          });
          return true;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<void> engineEvent(Map<String, Object?> event) =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            channel.name,
            channel.codec.encodeMethodCall(MethodCall('event', event)),
            (_) {},
          );

  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 5));

  test('a streamed clip goes to the engine piece by piece, trimmed', () async {
    final engine = EngineSpeechPlayback();
    final audio = ProgressiveAudio(mimeType: 'audio/mp3');
    await engine.setClips([
      AudioClip(uri: Uri.parse('x:0'), progressive: audio),
    ]);
    audio
      ..add(_piece(2))
      ..add(_piece(1))
      ..close();
    await settle();
    final a = _piece(2).length, b = _piece(1).length;
    check(calls).deepEquals([
      'reset',
      'append 0 $a trim',
      'append 0 $b trim',
      'finish 0',
    ]);
  });

  test('engine events become the clip index and the queue state', () async {
    final engine = EngineSpeechPlayback();
    final indices = <int?>[];
    final states = <AudioProcessingState>[];
    engine.currentIndexChanges.listen(indices.add);
    engine.stateChanges.listen((s) => states.add(s.processingState));
    await engine.setClips(const []);
    await engine.play();
    await engineEvent({'type': 'started', 'item': 0});
    await engineEvent({'type': 'starved'});
    await engineEvent({'type': 'started', 'item': 1});
    await engineEvent({'type': 'drained'});
    await settle();
    check(indices).deepEquals([0, 1]);
    check(states.last).equals(AudioProcessingState.completed);
    check(states).contains(AudioProcessingState.buffering);
    // The engine already moved on to clip 1; seeking there would restart it.
    calls.clear();
    await engine.seek(Duration.zero, index: 1);
    check(calls).isEmpty();
  });

  test('an engine failure moves the queue to just_audio as whole clips', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          if (call.method == 'play') {
            throw PlatformException(code: 'speech_engine', message: 'probe');
          }
          return true;
        });
    final files = _Files();
    final hybrid = HybridSpeechPlayback(files: files);
    final audio = ProgressiveAudio(mimeType: 'audio/mp3')
      ..add(_piece(2))
      ..close();
    await hybrid.setClips([
      AudioClip(uri: Uri.parse('x:0'), progressive: audio),
    ]);
    await hybrid.play();
    await settle();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    // just_audio was stopped when the engine took the queue, then got it
    // back as a whole file and went on playing.
    check(files.calls).deepEquals(['stop', 'setClips 1', 'play']);
    check(files.lastClips.single.progressive).isNull();
    check(files.lastClips.single.uri.scheme).equals('file');

    // From then on streamed clips go to just_audio whole.
    final next = ProgressiveAudio(mimeType: 'audio/mp3')
      ..add(_piece(1))
      ..close();
    await hybrid.setClips([
      AudioClip(uri: Uri.parse('x:1'), progressive: next),
    ]);
    check(files.lastClips.single.progressive).isNull();
  });

  test('the hybrid player picks the engine only for streamed queues', () async {
    final files = _Files();
    final hybrid = HybridSpeechPlayback(files: files);
    await hybrid.setClips([AudioClip(uri: Uri.parse('file:///a.mp3'))]);
    await hybrid.play();
    check(files.calls).deepEquals(['setClips 1', 'play']);
    check(calls).isEmpty();

    final audio = ProgressiveAudio(mimeType: 'audio/mpeg')..close();
    await hybrid.setClips([
      AudioClip(uri: Uri.parse('x:0'), progressive: audio),
    ]);
    await hybrid.play();
    await settle();
    check(files.calls.last).equals('stop');
    check(calls).contains('reset');
    check(calls).contains('play');
  });
}
