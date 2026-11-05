import 'dart:io';
import 'dart:typed_data';

import 'package:conduit/features/chat/services/speech_take_recorder.dart';
import 'package:conduit/features/chat/services/speech_take_store.dart';
import 'package:conduit_core/ports/mp3_pieces.dart';
import 'package:conduit_core/ports/progressive_audio.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _frame(int fill) => Uint8List(192)
  ..fillRange(4, 192, fill)
  ..setAll(0, [0xff, 0xf3, 0x84, 0xc4]);

/// A clip as the speech server streams it: ID3 tag, placeholder, [n] frames.
Uint8List _clip(int fill, int n) {
  final b = BytesBuilder()
    ..add([0x49, 0x44, 0x33, 4, 0, 0, 0, 0, 0, 34, ...Uint8List(34)])
    ..add(
      Uint8List(192)
        ..setAll(0, [0xff, 0xf3, 0x84, 0xc4])
        ..setAll(13, 'LAME'.codeUnits),
    );
  for (var i = 0; i < n; i++) {
    b.add(_frame(fill + i));
  }
  return b.takeBytes();
}

/// A store that cannot save, for a failing disk.
final class _FailingStore extends SpeechTakeStore {
  _FailingStore(Directory dir) : super(supportDirectory: () async => dir);
  @override
  Future<SpeechTake> save({
    required String messageId,
    required String voiceKey,
    required String text,
    required File source,
    required String extension,
    String? chatId,
    String? keyOverride,
    List<int>? clipSizes,
  }) => throw const FileSystemException('disk full');
}

void main() {
  late Directory tmp;
  late SpeechTakeStore store;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('take_rec_');
    store = SpeechTakeStore(
      supportDirectory: () async => tmp,
      excludeFromBackup: (_) async {},
    );
  });
  tearDown(() async => tmp.delete(recursive: true));

  SpeechTakeRecorder recorder({SpeechTakeStore? s, String id = 'm1'}) =>
      SpeechTakeRecorder(
        store: s ?? store,
        voiceKey: 'v',
        sessionName: 'tts-${DateTime.now().microsecondsSinceEpoch}',
        messageId: id,
        text: 'First sentence. Second sentence.',
      );

  test('the tee leaves the bytes the player reads untouched', () async {
    final clip = ProgressiveAudio(mimeType: 'audio/mpeg');
    final r = recorder()..addClip(0, progressive: clip, mimeType: 'audio/mpeg');
    final played = <int>[];
    final reading = clip.read().listen(played.addAll);
    final bytes = _clip(1, 5);
    // Arrives in uneven pieces, with the player reading all along.
    clip.add(bytes.sublist(0, 100));
    await pumpEventQueue();
    clip.add(bytes.sublist(100, 777));
    await pumpEventQueue();
    clip.add(bytes.sublist(777));
    clip.close();
    await reading.asFuture<void>();
    expect(Uint8List.fromList(played), bytes);
    final take = await r.finish(clipCount: 1);
    expect(take, isNotNull);
    // The take is the same audio frames the player was given.
    expect(take!.bytes, 5 * 192);
    r.discard();
  });

  test('a reply that played to its end is kept as one take', () async {
    final r = recorder();
    final a = ProgressiveAudio.complete(_clip(1, 3), 'audio/mpeg');
    final b = ProgressiveAudio.complete(_clip(50, 2), 'audio/mpeg');
    r
      ..addClip(0, progressive: a, mimeType: 'audio/mpeg')
      ..addClip(1, progressive: b, mimeType: 'audio/mpeg');
    final take = await r.finish(clipCount: 2);
    expect(take, isNotNull);
    final bytes = await take!.file.readAsBytes();
    expect(bytes.length, 5 * 192);
    expect(bytes.length % 192, 0);
    expect(mp3FrameLength(bytes, 0), 192);
    expect(
      (await store.find(
        messageId: 'm1',
        voiceKey: 'v',
        text: 'First sentence. Second sentence.',
      ))!.file.path,
      take.file.path,
    );
    // The work folder is gone, and the take is outside the temp folder.
    await pumpEventQueue();
    expect(Directory('${tmp.path}/speech_takes/_work/tts-x').existsSync(), isFalse);
  });

  test('whole clips (stream speech off) are kept the same way', () async {
    final r = recorder()
      ..addClip(0, bytes: _clip(1, 2), mimeType: 'audio/mpeg')
      ..addClip(1, bytes: _clip(9, 2), mimeType: 'audio/mpeg');
    final take = await r.finish(clipCount: 2);
    expect(take!.bytes, 4 * 192);
  });

  test('an interrupted play keeps nothing', () async {
    final r = recorder()
      ..addClip(
        0,
        progressive: ProgressiveAudio.complete(_clip(1, 3), 'audio/mpeg'),
        mimeType: 'audio/mpeg',
      );
    r.discard();
    await pumpEventQueue();
    expect(
      await store.find(
        messageId: 'm1',
        voiceKey: 'v',
        text: 'First sentence. Second sentence.',
      ),
      isNull,
    );
    expect(await r.finish(clipCount: 1), isNull);
  });

  test('a missing sentence is not a take', () async {
    final r = recorder()
      ..addClip(
        0,
        progressive: ProgressiveAudio.complete(_clip(1, 3), 'audio/mpeg'),
        mimeType: 'audio/mpeg',
      );
    expect(await r.finish(clipCount: 2), isNull);
  });

  test('a clip cut short or cancelled is not a take', () async {
    final cut = ProgressiveAudio(mimeType: 'audio/mpeg')
      ..add(_clip(1, 3))
      ..close(StateError('stream cut'));
    final r1 = recorder()..addClip(0, progressive: cut, mimeType: 'audio/mpeg');
    expect(await r1.finish(clipCount: 1), isNull);

    final cancelled = ProgressiveAudio(mimeType: 'audio/mpeg')
      ..add(_clip(1, 3))
      ..cancel();
    final r2 = recorder()
      ..addClip(0, progressive: cancelled, mimeType: 'audio/mpeg');
    expect(await r2.finish(clipCount: 1), isNull);
  });

  test('a replay that completes replaces the take with the newest', () async {
    final first = recorder()
      ..addClip(0, bytes: _clip(1, 2), mimeType: 'audio/mpeg');
    await first.finish(clipCount: 1);
    final second = recorder()
      ..addClip(0, bytes: _clip(7, 4), mimeType: 'audio/mpeg');
    final take = await second.finish(clipCount: 1);
    final found = await store.find(
      messageId: 'm1',
      voiceKey: 'v',
      text: 'First sentence. Second sentence.',
    );
    expect(found!.bytes, 4 * 192);
    expect(found.file.path, take!.file.path);
    // An interrupted replay leaves that take where it is.
    final third = recorder()
      ..addClip(0, bytes: _clip(3, 9), mimeType: 'audio/mpeg');
    third.discard();
    final still = await store.find(
      messageId: 'm1',
      voiceKey: 'v',
      text: 'First sentence. Second sentence.',
    );
    expect(still!.bytes, 4 * 192);
  });

  test('a failing save is no take and throws nothing into playback', () async {
    final r = recorder(s: _FailingStore(tmp))
      ..addClip(0, bytes: _clip(1, 2), mimeType: 'audio/mpeg');
    expect(await r.finish(clipCount: 1), isNull);
  });

  test('clips that cannot be joined are no take', () async {
    final r = recorder()
      ..addClip(0, bytes: _clip(1, 2), mimeType: 'audio/mpeg')
      ..addClip(1, bytes: Uint8List(80), mimeType: 'audio/wav');
    expect(await r.finish(clipCount: 2), isNull);
  });

  test('no text, no take', () async {
    final r = SpeechTakeRecorder(
      store: store,
      voiceKey: 'v',
      sessionName: 'tts-notext',
    )..addClip(0, bytes: _clip(1, 2), mimeType: 'audio/mpeg');
    expect(await r.finish(clipCount: 1), isNull);
  });
}
