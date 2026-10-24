import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit_core/ports/progressive_audio.dart';
import 'package:test/test.dart';

void main() {
  test('a reader gets bytes before the body has ended', () async {
    final audio = ProgressiveAudio(mimeType: 'audio/mpeg');
    final seen = <List<int>>[];
    final done = Completer<void>();
    audio.read().listen(seen.add, onDone: done.complete);

    audio.add([1, 2]);
    await pumpEventQueue();
    check(seen).deepEquals([
      [1, 2],
    ]);
    check(done.isCompleted).isFalse();

    audio
      ..add([3])
      ..close();
    await done.future;
    check(seen).deepEquals([
      [1, 2],
      [3],
    ]);
  });

  test('a second read starts again from the first byte', () async {
    final audio = ProgressiveAudio(mimeType: 'audio/mpeg')
      ..add([1])
      ..add([2, 3]);
    final first = audio.read().toList();
    audio.close();
    check(await first).deepEquals([
      [1],
      [2, 3],
    ]);
    check(await audio.read().expand((piece) => piece).toList())
        .deepEquals([1, 2, 3]);
  });

  test('complete audio reads whole', () async {
    final audio = ProgressiveAudio.complete([9, 8], 'audio/wav');
    check(audio.isDone).isTrue();
    check(audio.length).equals(2);
    check(await audio.read().expand((piece) => piece).toList())
        .deepEquals([9, 8]);
  });

  test('cancel stops the producer and ends the readers', () async {
    var cancelled = 0;
    final audio = ProgressiveAudio(
      mimeType: 'audio/mpeg',
      onCancel: () => cancelled++,
    );
    final read = audio.read().toList();
    audio.add([1]);
    audio.cancel();
    audio.cancel();
    audio.add([2]);

    check(await read).deepEquals([
      [1],
    ]);
    check(cancelled).equals(1);
    check(audio.isCancelled).isTrue();
    check(audio.isDone).isTrue();
  });

  test('an error keeps the bytes that arrived', () async {
    final audio = ProgressiveAudio(mimeType: 'audio/mpeg')
      ..add([1])
      ..close(StateError('cut'));
    check(await audio.read().toList()).deepEquals([
      [1],
    ]);
    check(audio.error).isA<StateError>();
  });
}
