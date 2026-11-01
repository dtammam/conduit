import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit_core/ports/ports.dart';
import 'package:test/test.dart';

/// ID3 tag (34 bytes of body), then one MPEG 2 layer III mono frame
/// (64 kbps, 24 kHz: 192 bytes) whose Xing/Info tag position holds [tag]
/// (or audio-like bytes when null).
Uint8List _body({String? tag, bool zeros = false, int frames = 3}) {
  final out = BytesBuilder()
    ..add([0x49, 0x44, 0x33, 4, 0, 0, 0, 0, 0, 34])
    ..add(Uint8List(34));
  for (var i = 0; i < frames; i++) {
    final frame = Uint8List(192)
      ..fillRange(4, 192, zeros ? 0 : 0x5a)
      ..setAll(0, [0xff, 0xf3, 0x84, 0xc4]);
    if (i == 0 && tag != null) frame.setAll(13, tag.codeUnits);
    out.add(frame);
  }
  return out.takeBytes();
}

void main() {
  group('classifyMp3Body', () {
    test('a first frame of audio is one continuous body', () {
      check(classifyMp3Body(_body())).equals(Mp3BodyKind.continuous);
    });

    test('an Info or Xing frame is one continuous body', () {
      check(classifyMp3Body(_body(tag: 'Info', zeros: true)))
          .equals(Mp3BodyKind.continuous);
      check(classifyMp3Body(_body(tag: 'Xing', zeros: true)))
          .equals(Mp3BodyKind.continuous);
    });

    test('a pipe-written placeholder frame is a file of several', () {
      check(classifyMp3Body(_body(tag: 'LAME3.9', zeros: true)))
          .equals(Mp3BodyKind.pieces);
      check(classifyMp3Body(_body(zeros: true))).equals(Mp3BodyKind.pieces);
    });

    test('too few bytes wait, unless the body ended', () {
      final body = _body();
      check(classifyMp3Body(body.sublist(0, 5))).equals(Mp3BodyKind.undecided);
      check(classifyMp3Body(body.sublist(0, 50))).equals(Mp3BodyKind.undecided);
      check(classifyMp3Body(body.sublist(0, 50), ended: true))
          .equals(Mp3BodyKind.pieces);
    });

    test('something that is not MP3 is left to the file path', () {
      check(classifyMp3Body(Uint8List(64))).equals(Mp3BodyKind.pieces);
    });
  });

  group('Mp3StreamRouter', () {
    test('a continuous body is passed on whole, in the order it came', () {
      final router = Mp3StreamRouter();
      final body = _body(frames: 20);
      final sent = BytesBuilder();
      for (var at = 0; at < body.length;) {
        final end = (at + 7).clamp(0, body.length);
        for (final route in router.add(body.sublist(at, end))) {
          check(route).isA<Mp3ContinuousBytes>();
          sent.add(route.bytes);
        }
        at = end;
      }
      check(router.finish()).isEmpty();
      check(router.continuous).isTrue();
      check(sent.takeBytes()).deepEquals(body);
    });

    test('files back to back are cut at their tags', () {
      final router = Mp3StreamRouter();
      final a = _body(tag: 'LAME3.9', zeros: true, frames: 2);
      final b = _body(tag: 'LAME3.9', zeros: true, frames: 3);
      final routes = [...router.add(a), ...router.add(b), ...router.finish()];
      check(routes.map((r) => r.runtimeType))
          .every((it) => it.equals(Mp3FilePiece));
      check(routes.map((r) => r.bytes.length)).deepEquals([a.length, b.length]);
      check(router.continuous).isFalse();
    });

    test('a body too short to classify comes back whole at the end', () {
      final router = Mp3StreamRouter();
      check(router.add([1, 2, 3])).isEmpty();
      final rest = router.finish();
      check(rest.single).isA<Mp3FilePiece>();
      check(rest.single.bytes).deepEquals([1, 2, 3]);
    });
  });
}
