import 'dart:typed_data';

import 'package:conduit/features/chat/services/speech_take_join.dart';
import 'package:conduit_core/ports/mp3_pieces.dart';
import 'package:flutter_test/flutter_test.dart';

/// A 24 kHz mono MPEG 2 layer III frame at 64 kbps: 192 bytes, [fill] as audio.
Uint8List _frame(int fill, {String? tag, bool zeros = false}) {
  final f = Uint8List(192)
    ..fillRange(4, 192, zeros ? 0 : fill)
    ..setAll(0, [0xff, 0xf3, 0x84, 0xc4]);
  if (tag != null) f.setAll(13, tag.codeUnits);
  return f;
}

Uint8List _id3() =>
    Uint8List.fromList([0x49, 0x44, 0x33, 4, 0, 0, 0, 0, 0, 34, ...Uint8List(34)]);

/// One streamed file: an ID3 tag, the placeholder frame, then audio frames.
Uint8List _piece(int fill, int frames) {
  final out = BytesBuilder()
    ..add(_id3())
    ..add(_frame(0, tag: 'LAME', zeros: true));
  for (var i = 0; i < frames; i++) {
    out.add(_frame(fill + i));
  }
  return out.takeBytes();
}

/// Frames in a body, walking it the way a decoder would.
List<Uint8List> _frames(Uint8List d) {
  final out = <Uint8List>[];
  var at = 0;
  while (at < d.length) {
    final length = mp3FrameLength(d, at);
    expect(length, isNotNull, reason: 'a frame header at $at');
    out.add(Uint8List.sublistView(d, at, at + length!));
    at += length;
  }
  expect(at, d.length);
  return out;
}

void main() {
  group('mp3', () {
    test('a clip of streamed pieces becomes bare audio frames', () {
      final clip = BytesBuilder()
        ..add(_piece(10, 3))
        ..add(_piece(20, 2));
      final joined = SpeechTakeJoin.join([clip.takeBytes()], ['mp3'])!;
      final frames = _frames(joined.bytes);
      expect(joined.extension, 'mp3');
      expect(frames.length, 5);
      // Audio only: no ID3 tag, no placeholder frame between the pieces.
      expect(
        frames.map((f) => f[10]).toList(),
        [10, 11, 12, 20, 21],
      );
    });

    test('clips are laid end to end with every frame kept in order', () {
      final a = _piece(1, 4);
      final b = BytesBuilder()
        ..add(_id3())
        ..add(_frame(0, tag: 'Info'))
        ..add(_frame(50))
        ..add(_frame(51));
      final c = _piece(100, 2);
      final joined = SpeechTakeJoin.join(
        [a, b.takeBytes(), c],
        ['mp3', 'mp3', 'mp3'],
      )!;
      final frames = _frames(joined.bytes);
      expect(frames.map((f) => f[10]).toList(), [1, 2, 3, 4, 50, 51, 100, 101]);
      // Whole-frame arithmetic: 8 frames of 192 bytes, nothing added.
      expect(joined.bytes.length, 8 * 192);
      expect(joined.bytes.length % 192, 0);
    });

    test('a bare clip with no tag keeps all of its frames', () {
      final clip = BytesBuilder()
        ..add(_frame(7))
        ..add(_frame(8));
      final joined = SpeechTakeJoin.join([clip.takeBytes()], ['mp3'])!;
      expect(_frames(joined.bytes).length, 2);
    });

    test('a cut-short frame is not joined', () {
      final bad = Uint8List.sublistView(_piece(1, 3), 0, _piece(1, 3).length - 40);
      expect(SpeechTakeJoin.join([bad], ['mp3']), isNull);
    });

    test('bytes that are not MP3 frames are not joined', () {
      expect(
        SpeechTakeJoin.join([Uint8List.fromList(List.filled(500, 3))], ['mp3']),
        isNull,
      );
    });
  });

  group('wav', () {
    Uint8List wav(List<int> pcm, {int rate = 24000, bool streamed = false}) {
      final b = BytesBuilder();
      void le32(int v) =>
          b.add([v & 255, (v >> 8) & 255, (v >> 16) & 255, (v >> 24) & 255]);
      b.add('RIFF'.codeUnits);
      le32(streamed ? 0xffffffff : 36 + pcm.length);
      b.add('WAVEfmt '.codeUnits);
      le32(16);
      b.add([1, 0, 1, 0]);
      le32(rate);
      le32(rate * 2);
      b.add([2, 0, 16, 0]);
      b.add('data'.codeUnits);
      le32(streamed ? 0xffffffff : pcm.length);
      b.add(pcm);
      return b.takeBytes();
    }

    test('same-format clips join as one file with a fresh header', () {
      final joined = SpeechTakeJoin.join(
        [wav([1, 2, 3, 4]), wav([5, 6], streamed: true), wav([7, 8])],
        ['wav', 'wav', 'wav'],
      )!;
      expect(joined.extension, 'wav');
      final d = joined.bytes;
      expect(String.fromCharCodes(d.sublist(0, 4)), 'RIFF');
      expect(d.sublist(44).toList(), [1, 2, 3, 4, 5, 6, 7, 8]);
      final size = ByteData.sublistView(d).getUint32(40, Endian.little);
      expect(size, 8);
    });

    test('different formats are not joined', () {
      expect(
        SpeechTakeJoin.join(
          [wav([1, 2]), wav([3, 4], rate: 16000)],
          ['wav', 'wav'],
        ),
        isNull,
      );
    });
  });

  test('a mix of kinds is not joined', () {
    expect(
      SpeechTakeJoin.join([_piece(1, 2), Uint8List(60)], ['mp3', 'wav']),
      isNull,
    );
    expect(SpeechTakeJoin.kindOf('audio/ogg'), isNull);
    expect(SpeechTakeJoin.kindOf('audio/mpeg'), 'mp3');
    expect(SpeechTakeJoin.kindOf('audio/x-wav'), 'wav');
  });

  group('silence units', () {
    Uint8List audio() => _frame(7);
    Uint8List quiet() => Uint8List(96)..setAll(0, [0xff, 0xf3, 0x44, 0xc4]);

    Uint8List body(List<(bool, int)> runs) {
      final b = BytesBuilder();
      for (final (isQuiet, n) in runs) {
        for (var i = 0; i < n; i++) {
          b.add(isQuiet ? quiet() : audio());
        }
      }
      return b.takeBytes();
    }

    test('cuts at the middle of each silent gap and names the sentences', () {
      final mp3 = body([(false, 40), (true, 8), (false, 40), (true, 8), (false, 40)]);
      final units = SpeechTakeJoin.silenceUnits(
        mp3,
        ['First sentence here.', 'Second sentence here.', 'Third sentence here.'],
      )!;
      expect(units.starts, [0, 1, 2]);
      expect(units.sizes.fold<int>(0, (a, b) => a + b), mp3.length);
      // Every cut is a frame boundary inside a silent run.
      var at = 0;
      for (final size in units.sizes.take(2)) {
        at += size;
        expect(mp3FrameLength(mp3, at), isNotNull);
        expect(mp3FrameLength(mp3, at), 96, reason: 'cut sits in the silence');
      }
      // Each unit decodes as whole frames.
      for (final size in units.sizes) {
        expect(size > 0, isTrue);
      }
    });

    test('a gap is matched to the sentence boundary nearest its share of time', () {
      // One long first sentence, two short ones: the gap near 2/3 of the audio.
      final mp3 = body([(false, 60), (true, 8), (false, 30)]);
      final units = SpeechTakeJoin.silenceUnits(mp3, [
        'A very long first sentence that goes on and on for a while here.',
        'Short one.',
        'Short two.',
      ])!;
      expect(units.starts.first, 0);
      expect(units.starts.length, 2);
      expect(units.starts[1], anyOf(1, 2));
    });

    test('no gap, one sentence, or ends-only silence means no units', () {
      expect(SpeechTakeJoin.silenceUnits(body([(false, 60)]), ['A.', 'B.']), isNull);
      expect(SpeechTakeJoin.silenceUnits(body([(false, 60), (true, 9)]), ['A.', 'B.']), isNull);
      expect(SpeechTakeJoin.silenceUnits(body([(false, 60), (true, 9), (false, 60)]), ['Only one.']), isNull);
      // A short pause (under six frames) is not a cut.
      expect(SpeechTakeJoin.silenceUnits(body([(false, 60), (true, 3), (false, 60)]), ['A.', 'B.']), isNull);
    });
  });
}
