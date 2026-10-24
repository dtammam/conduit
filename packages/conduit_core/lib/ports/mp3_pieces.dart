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
