import 'dart:async';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit_core/ports/ports.dart';
import 'package:test/test.dart';

/// One relay-style MP3 file: an ID3 tag, then [frames] MPEG 2 layer III
/// frames at 128 kbps, 24 kHz (384 bytes each), every byte after the header
/// set to [fill].
Uint8List _piece(int frames, {int fill = 0}) {
  const tagBody = 34;
  final out = BytesBuilder();
  out.add([0x49, 0x44, 0x33, 4, 0, 0, 0, 0, 0, tagBody]);
  out.add(List.filled(tagBody, 0));
  for (var i = 0; i < frames; i++) {
    final frame = Uint8List(384)..fillRange(4, 384, fill);
    frame.setAll(0, [0xff, 0xf3, 0xc4, 0xc4]);
    out.add(frame);
  }
  return out.takeBytes();
}

Uint8List _join(List<Uint8List> parts) {
  final b = BytesBuilder();
  parts.forEach(b.add);
  return b.takeBytes();
}

class _FakeQueue implements AudioSourceQueue {
  final sources = <QueueSource>[];
  final states = StreamController<AudioPlaybackState>.broadcast(sync: true);
  final indices = StreamController<int?>.broadcast(sync: true);
  final calls = <String>[];
  int? index;
  AudioProcessingState state = AudioProcessingState.idle;
  bool isPlaying = false;

  void emit(AudioProcessingState next) {
    state = next;
    states.add(AudioPlaybackState(playing: isPlaying, processingState: next));
  }

  /// The current item ends: the next plays, or the queue completes.
  void finishCurrent() {
    final i = index ?? 0;
    if (i + 1 < sources.length) {
      index = i + 1;
      indices.add(index);
    } else {
      emit(AudioProcessingState.completed);
    }
  }

  @override
  Stream<AudioPlaybackState> get stateChanges => states.stream;
  @override
  Stream<int?> get currentIndexChanges => indices.stream;
  @override
  int? get currentIndex => index;
  @override
  AudioProcessingState get processingState => state;
  @override
  bool get playing => isPlaying;

  @override
  Future<void> setSources(
    List<QueueSource> list, {
    int initialIndex = 0,
    Duration initialPosition = Duration.zero,
  }) async {
    sources
      ..clear()
      ..addAll(list);
    index = list.isEmpty ? null : initialIndex;
    calls.add('set ${list.length}');
  }

  @override
  Future<void> insertSource(int at, QueueSource source) async {
    sources.insert(at, source);
    calls.add('insert $at');
  }

  @override
  Future<void> clearSources() async => sources.clear();
  @override
  Future<void> play() async {
    isPlaying = true;
    index ??= sources.isEmpty ? null : 0;
    calls.add('play');
    emit(AudioProcessingState.ready);
  }

  @override
  Future<void> pause() async => isPlaying = false;
  @override
  Future<void> stop() async => isPlaying = false;
  @override
  Future<void> seek(Duration? position, {int? index}) async {
    if (index != null) {
      this.index = index;
      indices.add(index);
    }
    calls.add('seek $index');
  }

  @override
  Future<void> setSpeed(double speed) async {}
  @override
  Future<void> dispose() async {}
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  group('Mp3PieceSplitter', () {
    test('cuts a relay body into its files, however the bytes arrive', () {
      final a = _piece(3), b = _piece(2, fill: 0x49), c = _piece(4);
      final body = _join([a, b, c]);
      for (final step in [1, 7, 100, body.length]) {
        final splitter = Mp3PieceSplitter();
        final pieces = <Uint8List>[];
        for (var i = 0; i < body.length; i += step) {
          pieces.addAll(
            splitter.add(body.sublist(i, (i + step).clamp(0, body.length))),
          );
        }
        final rest = splitter.finish();
        check(pieces.map((p) => p.length)).deepEquals([a.length, b.length]);
        check(rest.length).equals(c.length);
        check(splitter.failed).isFalse();
      }
    });

    test('audio bytes that spell ID3 are not a boundary', () {
      // fill 0x49 puts "III..." in the frames; 0x44, 0x33 inside a frame:
      final tricky = _piece(2);
      tricky.setAll(10 + 34 + 100, [0x49, 0x44, 0x33]);
      final body = _join([tricky, _piece(1)]);
      final splitter = Mp3PieceSplitter();
      final pieces = splitter.add(body);
      check(pieces.single.length).equals(tricky.length);
    });

    test('a body that is not this MP3 comes back whole at the end', () {
      final splitter = Mp3PieceSplitter();
      check(splitter.add(List.filled(5000, 7))).isEmpty();
      check(splitter.failed).isTrue();
      check(splitter.finish().length).equals(5000);
    });

    test('reads the frame length of MPEG 1 and MPEG 2 headers', () {
      check(
        mp3FrameLength(Uint8List.fromList([0xff, 0xf3, 0xc4, 0xc4]), 0),
      ).equals(384);
      // MPEG 1, 128 kbps, 44.1 kHz, padded: 418.
      check(
        mp3FrameLength(Uint8List.fromList([0xff, 0xfb, 0x92, 0x00]), 0),
      ).equals(418);
      check(mp3FrameLength(Uint8List.fromList([0x00, 0, 0, 0]), 0)).isNull();
    });
  });

  group('PieceQueuePlayback', () {
    late _FakeQueue host;
    late PieceQueuePlayback playback;
    setUp(() {
      host = _FakeQueue();
      playback = PieceQueuePlayback(host);
    });

    test('whole clips pass through one to one', () async {
      await playback.setClips([
        AudioClip(uri: Uri.parse('file:///a.mp3')),
        AudioClip(uri: Uri.parse('file:///b.mp3')),
      ]);
      check(host.sources).length.equals(2);
      check(host.calls).deepEquals(['set 2']);
    });

    test('a streamed clip plays its first piece while the rest arrives, '
        'and callers see one clip', () async {
      final audio = ProgressiveAudio(mimeType: 'audio/mp3');
      final indices = <int?>[];
      playback.currentIndexChanges.listen(indices.add);
      audio.add(_join([_piece(2), _piece(1).sublist(0, 20)]));
      await playback.setClips([
        AudioClip(uri: Uri.parse('conduit-tts://1/0'), progressive: audio),
      ]);
      check(host.sources).length.equals(1);
      await playback.play();
      check(playback.currentIndex).equals(0);

      audio
        ..add(_join([_piece(1).sublist(20), _piece(2)]))
        ..close();
      await _settle();
      await _settle();
      check(host.sources).length.equals(3);
      host.finishCurrent();
      host.finishCurrent();
      await _settle();
      check(playback.currentIndex).equals(0);
      check(indices).deepEquals([0]);
    });

    test('running out of pieces mid-clip buffers, then resumes', () async {
      final audio = ProgressiveAudio(mimeType: 'audio/mpeg');
      final states = <AudioProcessingState>[];
      playback.stateChanges.listen((s) => states.add(s.processingState));
      audio.add(_join([_piece(1), _piece(1).sublist(0, 4)]));
      await playback.setClips([
        AudioClip(uri: Uri.parse('x:'), progressive: audio),
      ]);
      await playback.play();
      host.finishCurrent();
      await _settle();
      check(states.last).equals(AudioProcessingState.buffering);
      check(playback.processingState).equals(AudioProcessingState.buffering);

      audio.add(_piece(1).sublist(4));
      audio.add(_piece(1));
      await _settle();
      await _settle();
      check(host.calls).contains('seek 1');
      check(host.index).equals(1);

      audio.close();
      await _settle();
      await _settle();
      host.finishCurrent();
      host.finishCurrent();
      await _settle();
      check(states.last).equals(AudioProcessingState.completed);
    });

    test('the next clip waits for the pieces of the one before it', () async {
      final first = ProgressiveAudio(mimeType: 'audio/mpeg');
      final second = ProgressiveAudio(mimeType: 'audio/mpeg');
      first.add(_join([_piece(1), _piece(1)]));
      await playback.setClips([
        AudioClip(uri: Uri.parse('x:0'), tag: 0, progressive: first),
      ]);
      second
        ..add(_piece(1))
        ..close();
      final added = playback.addClip(
        AudioClip(uri: Uri.parse('x:1'), tag: 1, progressive: second),
      );
      await _settle();
      check(host.sources.map((s) => s.tag)).deepEquals([0]);
      first
        ..add(_piece(1))
        ..close();
      await added;
      await _settle();
      check(host.sources.map((s) => s.tag)).deepEquals([0, 0, 0, 1]);
      await playback.seek(Duration.zero, index: 1);
      check(host.index).equals(3);
      check(playback.currentIndex).equals(1);
    });

    test('a clip that is not MP3 plays once whole', () async {
      final audio = ProgressiveAudio(mimeType: 'audio/wav');
      final done = playback.setClips([
        AudioClip(uri: Uri.parse('x:'), progressive: audio),
      ]);
      audio
        ..add([1, 2, 3])
        ..close();
      await done;
      check(host.sources.single.bytes).isNotNull().deepEquals([1, 2, 3]);
    });
  });
}
