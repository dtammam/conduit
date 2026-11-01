import 'dart:async';
import 'dart:typed_data';

import 'progressive_audio.dart';

/// Cuts a streamed MP3 body into the separately playable files it is made of.
///
/// A speech server that streams MP3 encodes each interval (about half a
/// second) as a file of its own, an ID3 tag followed by MPEG frames, and sends
/// them back to back. iOS's player will not start a body of unknown length
/// until it has all of it, but each of those files plays at once, so the host
/// queues them one by one.
///
/// [add] takes bytes as they arrive and returns every file that is now
/// complete: a file ends where the next ID3 tag begins, found by walking the
/// MPEG frame headers (never by searching for the letters, which audio data
/// can contain). [finish] returns the rest. A body that is not MP3 as
/// described yields nothing until [finish], which returns it whole, so the
/// caller falls back to playing the finished clip.
final class Mp3PieceSplitter {
  final BytesBuilder _buffer = BytesBuilder(copy: false);
  Uint8List _data = Uint8List(0);

  /// Where the frame walk of the current file stands, from its start.
  int _cursor = 0;

  /// Set once the body turned out not to be the expected MP3; everything is
  /// then kept for [finish].
  bool _failed = false;

  /// Whether the body could not be cut and comes back whole from [finish].
  bool get failed => _failed;

  List<Uint8List> add(List<int> bytes) {
    if (bytes.isEmpty) return const [];
    _buffer.add(bytes);
    _data = _concat(_data, _buffer.takeBytes());
    if (_failed) return const [];
    final pieces = <Uint8List>[];
    while (true) {
      final end = _nextBoundary();
      if (end == null) break;
      pieces.add(Uint8List.sublistView(_data, 0, end));
      _data = Uint8List.sublistView(_data, end);
      _cursor = 0;
    }
    return pieces;
  }

  /// The bytes not yet returned, as one last file (empty when none).
  Uint8List finish() {
    final rest = _data;
    _data = Uint8List(0);
    _cursor = 0;
    return rest;
  }

  /// The end of the first complete file in [_data], or null while it is not
  /// complete (or the body cannot be cut).
  int? _nextBoundary() {
    final d = _data;
    if (_cursor == 0) {
      if (d.length < 10) return null;
      final tag = _id3Length(d, 0);
      if (tag == null) {
        _failed = true;
        return null;
      }
      _cursor = tag;
    }
    while (true) {
      if (_cursor + 4 > d.length) return null;
      if (_cursor > 0 && _isId3(d, _cursor)) return _cursor;
      final frame = mp3FrameLength(d, _cursor);
      if (frame == null) {
        _failed = true;
        return null;
      }
      _cursor += frame;
    }
  }

  static bool _isId3(Uint8List d, int at) =>
      at + 3 <= d.length &&
      d[at] == 0x49 &&
      d[at + 1] == 0x44 &&
      d[at + 2] == 0x33;

  /// The full length of the ID3v2 tag at [at] (header, body and footer).
  static int? _id3Length(Uint8List d, int at) {
    if (!_isId3(d, at) || at + 10 > d.length) return null;
    final size =
        (d[at + 6] & 0x7f) << 21 |
        (d[at + 7] & 0x7f) << 14 |
        (d[at + 8] & 0x7f) << 7 |
        (d[at + 9] & 0x7f);
    final footer = (d[at + 5] & 0x10) != 0 ? 10 : 0;
    return 10 + size + footer;
  }

  static Uint8List _concat(Uint8List a, Uint8List b) {
    if (a.isEmpty) return b;
    final out = Uint8List(a.length + b.length)
      ..setRange(0, a.length, a)
      ..setRange(a.length, a.length + b.length, b);
    return out;
  }
}

const _bitratesV1L3 = [
  0,
  32,
  40,
  48,
  56,
  64,
  80,
  96,
  112,
  128,
  160,
  192,
  224,
  256,
  320,
];
const _bitratesV2L3 = [
  0,
  8,
  16,
  24,
  32,
  40,
  48,
  56,
  64,
  80,
  96,
  112,
  128,
  144,
  160,
];
const _sampleRatesV1 = [44100, 48000, 32000];

/// The length of the MPEG audio layer III frame whose header starts at [at],
/// or null when no such header is there.
int? mp3FrameLength(Uint8List d, int at) {
  if (at + 4 > d.length) return null;
  final b1 = d[at + 1], b2 = d[at + 2];
  if (d[at] != 0xff || (b1 & 0xe0) != 0xe0) return null;
  final version = (b1 >> 3) & 0x03; // 3: MPEG 1, 2: MPEG 2, 0: MPEG 2.5
  final layer = (b1 >> 1) & 0x03; // 1: layer III
  if (version == 1 || layer != 1) return null;
  final bitrateIndex = (b2 >> 4) & 0x0f;
  final rateIndex = (b2 >> 2) & 0x03;
  if (bitrateIndex == 0 || bitrateIndex == 15 || rateIndex == 3) return null;
  final padding = (b2 >> 1) & 0x01;
  final v1 = version == 3;
  final bitrate = (v1 ? _bitratesV1L3 : _bitratesV2L3)[bitrateIndex] * 1000;
  final sampleRate =
      _sampleRatesV1[rateIndex] ~/ (v1 ? 1 : (version == 2 ? 2 : 4));
  return (v1 ? 144 : 72) * bitrate ~/ sampleRate + padding;
}

/// What an MP3 body is, as far as its first bytes show.
enum Mp3BodyKind {
  /// Not enough bytes yet.
  undecided,

  /// One continuous MP3 (an ffmpeg stream): decoded as it arrives.
  continuous,

  /// Files back to back, each with an ID3 tag of its own and, for a file
  /// written to a pipe, a placeholder where the Xing/Info header would be:
  /// cut at the tags ([Mp3PieceSplitter]).
  pieces,
}

/// Tells a continuous MP3 body from back-to-back files by its first frame.
///
/// A file an encoder wrote to a pipe opens with a placeholder frame: silent,
/// with "LAME..." (or nothing) where an Xing/Info tag would be. A real Info
/// or Xing frame, or a first frame of audio, is the start of one continuous
/// body. [ended] says no more bytes will come; a body that stops before it
/// can be told apart is [Mp3BodyKind.pieces], as it always was.
Mp3BodyKind classifyMp3Body(List<int> head, {bool ended = false}) {
  final fallback = ended ? Mp3BodyKind.pieces : Mp3BodyKind.undecided;
  var at = 0;
  if (head.length >= 3 &&
      head[0] == 0x49 &&
      head[1] == 0x44 &&
      head[2] == 0x33) {
    if (head.length < 10) return fallback;
    final size =
        (head[6] & 0x7f) << 21 |
        (head[7] & 0x7f) << 14 |
        (head[8] & 0x7f) << 7 |
        (head[9] & 0x7f);
    at = 10 + size + ((head[5] & 0x10) != 0 ? 10 : 0);
  }
  if (head.length < at + 4) return fallback;
  if (head[at] != 0xff || (head[at + 1] & 0xe0) != 0xe0) {
    return Mp3BodyKind.pieces;
  }
  final v1 = ((head[at + 1] >> 3) & 3) == 3;
  final mono = ((head[at + 3] >> 6) & 3) == 3;
  final crc = (head[at + 1] & 1) == 0 ? 2 : 0;
  final side = v1 ? (mono ? 17 : 32) : (mono ? 9 : 17);
  final tag = at + 4 + crc + side;
  if (head.length < tag + 4) return fallback;
  final name = String.fromCharCodes(head.sublist(tag, tag + 4));
  if (name == 'Xing' || name == 'Info') return Mp3BodyKind.continuous;
  if (name == 'LAME' || name == 'Lavf' || name == 'Lavc') {
    return Mp3BodyKind.pieces;
  }
  if (head[tag] == 0 &&
      head[tag + 1] == 0 &&
      head[tag + 2] == 0 &&
      head[tag + 3] == 0) {
    return Mp3BodyKind.pieces;
  }
  return Mp3BodyKind.continuous;
}

/// A part of a streamed MP3 body, ready for the player.
sealed class Mp3Route {
  const Mp3Route(this.bytes);
  final Uint8List bytes;
}

/// Bytes of one continuous body, to decode as they come.
final class Mp3ContinuousBytes extends Mp3Route {
  const Mp3ContinuousBytes(super.bytes);
}

/// One whole file out of a body made of files.
final class Mp3FilePiece extends Mp3Route {
  const Mp3FilePiece(super.bytes);
}

/// Sends each part of a streamed MP3 body down the path that suits it: a
/// continuous body's bytes straight through, a body of files cut into its
/// files. The first bytes decide; they are held until they can.
final class Mp3StreamRouter {
  final BytesBuilder _head = BytesBuilder(copy: true);
  final Mp3PieceSplitter _splitter = Mp3PieceSplitter();
  Mp3BodyKind _kind = Mp3BodyKind.undecided;

  Mp3BodyKind get kind => _kind;

  /// Whether the body turned out to be one continuous MP3.
  bool get continuous => _kind == Mp3BodyKind.continuous;

  List<Mp3Route> add(List<int> bytes) {
    if (bytes.isEmpty) return const [];
    if (_kind == Mp3BodyKind.undecided) {
      _head.add(bytes);
      final held = _head.toBytes();
      _kind = classifyMp3Body(held);
      if (_kind == Mp3BodyKind.undecided) return const [];
      _head.clear();
      return _route(held);
    }
    return _route(bytes);
  }

  /// What is left when the body has ended: for a body of files its last
  /// file; for a body too short to classify, all of it as one file.
  List<Mp3Route> finish() {
    if (_kind == Mp3BodyKind.undecided) {
      final held = _head.takeBytes();
      _kind = Mp3BodyKind.pieces;
      if (held.isEmpty) return const [];
      return [Mp3FilePiece(held)];
    }
    if (_kind == Mp3BodyKind.continuous) return const [];
    final rest = _splitter.finish();
    return rest.isEmpty ? const [] : [Mp3FilePiece(rest)];
  }

  List<Mp3Route> _route(List<int> bytes) {
    if (_kind == Mp3BodyKind.continuous) {
      return [
        Mp3ContinuousBytes(
          bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
        ),
      ];
    }
    return [for (final piece in _splitter.add(bytes)) Mp3FilePiece(piece)];
  }
}

/// The files of [audio] (an MP3 body) as each completes; the whole body as
/// one when it cannot be cut. Ends when the body does, and with its error.
Stream<Uint8List> mp3Pieces(ProgressiveAudio audio) async* {
  final splitter = Mp3PieceSplitter();
  await for (final bytes in audio.read()) {
    for (final piece in splitter.add(bytes)) {
      yield piece;
    }
  }
  final rest = splitter.finish();
  if (rest.isNotEmpty) yield rest;
}

/// Whether [mimeType] names MP3, the one format [mp3Pieces] can cut.
bool isMp3MimeType(String mimeType) {
  final m = mimeType.toLowerCase();
  return m.contains('mpeg') || m.contains('mp3');
}
