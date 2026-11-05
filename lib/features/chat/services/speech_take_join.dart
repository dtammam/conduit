import 'dart:typed_data';

import 'package:conduit_core/ports/mp3_pieces.dart';

/// Joins the sentence clips of one reply into a single file, byte for byte,
/// without decoding anything.
///
/// MP3 clips are cut to bare audio frames and laid end to end: every ID3 tag
/// is dropped, and so is the metadata frame a clip opens with (an Xing/Info
/// frame, or the silent placeholder frame an encoder writes to a pipe), which
/// a decoder would play as a short gap of silence between sentences. What is
/// left is only audio frames, so the joined file decodes as one continuous
/// stream. WAV clips that share one format are joined as PCM under a new
/// header. A set that cannot be joined this way (mixed kinds, odd bytes,
/// differing WAV formats) returns null, and the caller keeps no take.
class SpeechTakeJoin {
  const SpeechTakeJoin._();

  /// The extension for a clip of [mimeType]: `mp3`, `wav` or null for a kind
  /// that cannot be joined.
  static String? kindOf(String mimeType) {
    final type = mimeType.toLowerCase();
    if (type.contains('mpeg') || type.contains('mp3')) return 'mp3';
    if (type.contains('wav') || type.contains('wave')) return 'wav';
    return null;
  }

  /// Joins [clips] (in order) given their [kinds] (from [kindOf]); null when
  /// they cannot be joined cleanly.
  static ({Uint8List bytes, String extension, List<int>? clipSizes})? join(
    List<Uint8List> clips,
    List<String?> kinds,
  ) {
    if (clips.isEmpty || clips.length != kinds.length) return null;
    final kind = kinds.first;
    if (kind == null || kinds.any((k) => k != kind)) return null;
    if (kind == 'mp3') {
      // Each clip's share of the joined bytes, so the take can be played back
      // one sentence at a time, cut at frame boundaries.
      final sizes = <int>[];
      final out = BytesBuilder(copy: false);
      for (final clip in clips) {
        final audio = mp3AudioFrames(clip);
        if (audio == null) return null;
        sizes.add(audio.length);
        out.add(audio);
      }
      final bytes = out.takeBytes();
      return bytes.isEmpty
          ? null
          : (bytes: bytes, extension: kind, clipSizes: sizes);
    }
    final bytes = _joinWav(clips);
    if (bytes == null || bytes.isEmpty) return null;
    return (bytes: bytes, extension: kind, clipSizes: null);
  }

  // ---------------------------------------------------------------- MP3

  /// Only the audio frames of an MP3 body that is one clip, or many files
  /// back to back: no ID3 tag, no metadata frame. Null when the bytes are not
  /// whole frames of layer III audio.
  static Uint8List? mp3AudioFrames(Uint8List d) {
    final out = BytesBuilder(copy: false);
    var at = 0;
    // True at the start of the body and after each ID3 tag: the next frame
    // may be the metadata frame of a new file.
    var fileStart = true;
    var audioFrames = 0;
    while (at < d.length) {
      final tag = _id3Length(d, at);
      if (tag != null) {
        if (at + tag > d.length) return null;
        at += tag;
        fileStart = true;
        continue;
      }
      // A 128 byte ID3v1 tag closes a file.
      if (d.length - at == 128 && _isId3v1(d, at)) break;
      final length = mp3FrameLength(d, at);
      if (length == null || at + length > d.length) return null;
      if (fileStart && _isMetadataFrame(d, at, length)) {
        at += length;
        fileStart = false;
        continue;
      }
      fileStart = false;
      out.add(Uint8List.sublistView(d, at, at + length));
      audioFrames++;
      at += length;
    }
    if (audioFrames == 0) return null;
    return out.takeBytes();
  }

  static bool _isId3v1(Uint8List d, int at) =>
      d[at] == 0x54 && d[at + 1] == 0x41 && d[at + 2] == 0x47;

  static int? _id3Length(Uint8List d, int at) {
    if (at + 10 > d.length) return null;
    if (d[at] != 0x49 || d[at + 1] != 0x44 || d[at + 2] != 0x33) return null;
    final size =
        (d[at + 6] & 0x7f) << 21 |
        (d[at + 7] & 0x7f) << 14 |
        (d[at + 8] & 0x7f) << 7 |
        (d[at + 9] & 0x7f);
    return 10 + size + ((d[at + 5] & 0x10) != 0 ? 10 : 0);
  }

  /// Whether the frame at [at] carries no audio: an Xing/Info/LAME/Lavf/Lavc
  /// tag where a header would be, or a payload of nothing but zeros.
  static bool _isMetadataFrame(Uint8List d, int at, int length) {
    final v1 = ((d[at + 1] >> 3) & 3) == 3;
    final mono = ((d[at + 3] >> 6) & 3) == 3;
    final crc = (d[at + 1] & 1) == 0 ? 2 : 0;
    final side = v1 ? (mono ? 17 : 32) : (mono ? 9 : 17);
    final tag = at + 4 + crc + side;
    if (tag + 4 <= at + length) {
      final name = String.fromCharCodes(d.sublist(tag, tag + 4));
      if (name == 'Xing' ||
          name == 'Info' ||
          name == 'LAME' ||
          name == 'Lavf' ||
          name == 'Lavc') {
        return true;
      }
    }
    for (var i = at + 4 + crc; i < at + length; i++) {
      if (d[i] != 0) return false;
    }
    return true;
  }

  // ---------------------------------------------------------------- WAV

  static Uint8List? _joinWav(List<Uint8List> clips) {
    Uint8List? format;
    final pcm = BytesBuilder(copy: false);
    for (final clip in clips) {
      final parsed = _parseWav(clip);
      if (parsed == null) return null;
      if (format == null) {
        format = parsed.format;
      } else if (!_sameBytes(format, parsed.format)) {
        return null;
      }
      pcm.add(parsed.data);
    }
    if (format == null) return null;
    final data = pcm.takeBytes();
    final header = BytesBuilder(copy: false)
      ..add('RIFF'.codeUnits)
      ..add(_le32(4 + 8 + format.length + 8 + data.length))
      ..add('WAVE'.codeUnits)
      ..add('fmt '.codeUnits)
      ..add(_le32(format.length))
      ..add(format)
      ..add('data'.codeUnits)
      ..add(_le32(data.length))
      ..add(data);
    return header.takeBytes();
  }

  static ({Uint8List format, Uint8List data})? _parseWav(Uint8List d) {
    if (d.length < 12) return null;
    if (String.fromCharCodes(d.sublist(0, 4)) != 'RIFF' ||
        String.fromCharCodes(d.sublist(8, 12)) != 'WAVE') {
      return null;
    }
    final view = ByteData.sublistView(d);
    Uint8List? format;
    var at = 12;
    while (at + 8 <= d.length) {
      final id = String.fromCharCodes(d.sublist(at, at + 4));
      var size = view.getUint32(at + 4, Endian.little);
      final body = at + 8;
      if (id == 'data') {
        // A streamed header has no real size: take the rest of the bytes.
        if (size == 0 || size == 0xffffffff || body + size > d.length) {
          size = d.length - body;
        }
        if (format == null || size <= 0) return null;
        return (format: format, data: Uint8List.sublistView(d, body, body + size));
      }
      if (body + size > d.length) return null;
      if (id == 'fmt ') format = Uint8List.sublistView(d, body, body + size);
      at = body + size + (size.isOdd ? 1 : 0);
    }
    return null;
  }

  static List<int> _le32(int v) => [
    v & 0xff,
    (v >> 8) & 0xff,
    (v >> 16) & 0xff,
    (v >> 24) & 0xff,
  ];

  static bool _sameBytes(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
