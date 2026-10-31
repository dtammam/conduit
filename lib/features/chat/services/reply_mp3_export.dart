import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'tts_manager.dart';

/// "Share as MP3" for an assistant reply (Dean, 2026-10-31): the whole reply
/// rendered as one speech file in the current voice, staged in the temp
/// folder for the share sheet.
///
/// The render is one speech request for the whole text through the voice
/// server's whole-clip path (not streamed, so the server returns one file).
/// The speech relay's dedicated export endpoint replaces [render] when it
/// lands; the button and the file handling stay the same.
class ReplyMp3Export {
  ReplyMp3Export({
    Future<({Uint8List bytes, String mimeType})> Function(String text)? render,
    Future<Directory> Function()? tempDirectory,
  }) : _render = render ?? TtsManager.instance.synthesizeChunk,
       _tempDirectory = tempDirectory ?? getTemporaryDirectory;

  final Future<({Uint8List bytes, String mimeType})> Function(String text)
  _render;
  final Future<Directory> Function() _tempDirectory;

  /// Whether the voice server can render speech at all.
  static bool get available => TtsManager.instance.serverAvailable;

  /// A short file name from the reply's first words: "Heres your day.mp3".
  static String fileNameFor(String text, String extension) {
    final words = text
        .replaceAll(RegExp(r"[^A-Za-z0-9 ]+"), ' ')
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .take(6)
        .join(' ');
    final base = words.isEmpty ? 'Reply' : words;
    return '$base.$extension';
  }

  static String extensionFor(String mimeType) {
    final type = mimeType.toLowerCase();
    if (type.contains('wav')) return 'wav';
    if (type.contains('mp4') || type.contains('m4a') || type.contains('aac')) {
      return 'm4a';
    }
    return 'mp3';
  }

  /// Renders [text] and writes it to a temp file; returns the file and its
  /// mime type.
  Future<({File file, String mimeType})> export(String text) async {
    final clean = text.trim();
    if (clean.isEmpty) {
      throw ArgumentError('Nothing to read aloud in this reply');
    }
    final audio = await _render(clean);
    if (audio.bytes.isEmpty) {
      throw StateError('The voice server returned no audio');
    }
    final ext = extensionFor(audio.mimeType);
    final dir = await _tempDirectory();
    final folder = Directory(
      '${dir.path}/reply-audio-${DateTime.now().millisecondsSinceEpoch}',
    );
    await folder.create(recursive: true);
    final file = File('${folder.path}/${fileNameFor(clean, ext)}');
    await file.writeAsBytes(audio.bytes, flush: true);
    return (file: file, mimeType: audio.mimeType);
  }
}
