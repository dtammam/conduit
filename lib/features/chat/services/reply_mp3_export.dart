import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'tts_manager.dart';

/// A render the speech relay accepted (`POST audio/export`, `wait: false`):
/// the signed link to fetch and the relay's own time estimate.
class Mp3ExportTicket {
  const Mp3ExportTicket({
    required this.url,
    this.audioSeconds,
    this.renderSeconds,
  });

  final String url;
  final double? audioSeconds;
  final double? renderSeconds;

  /// Reads the relay's 202 answer; null when it has no link.
  static Mp3ExportTicket? fromJson(Object? json) {
    if (json is! Map) return null;
    final url = json['url'];
    if (url is! String || url.isEmpty) return null;
    final estimate = json['estimate'];
    double? number(Object? v) => v is num ? v.toDouble() : null;
    return Mp3ExportTicket(
      url: url,
      audioSeconds: estimate is Map ? number(estimate['audio_s']) : null,
      renderSeconds: estimate is Map ? number(estimate['render_s']) : null,
    );
  }
}

/// "Share as MP3" for an assistant reply (Dean, 2026-10-31): the whole reply
/// rendered as one speech file in the current voice, staged in the temp
/// folder for the share sheet.
///
/// The speech relay's export (`POST audio/export` on the Voice provider, then
/// a GET of its signed link, which waits until the file is made) renders a
/// reply of any length in chunks. An older relay without it answers 404, and
/// then the reply goes through one plain speech request, which a relay cuts
/// off after about two minutes of audio.
class ReplyMp3Export {
  ReplyMp3Export({
    Future<Mp3ExportTicket?> Function(String text)? startRelayExport,
    Future<Uint8List> Function(String url)? download,
    Future<({Uint8List bytes, String mimeType})> Function(String text)? render,
    Future<Directory> Function()? tempDirectory,
  }) : _startRelayExport = startRelayExport,
       _download = download ?? downloadSigned,
       _render = render ?? TtsManager.instance.synthesizeChunk,
       _tempDirectory = tempDirectory ?? getApplicationCacheDirectory;

  final Future<Mp3ExportTicket?> Function(String text)? _startRelayExport;
  final Future<Uint8List> Function(String url) _download;
  final Future<({Uint8List bytes, String mimeType})> Function(String text)
  _render;
  final Future<Directory> Function() _tempDirectory;

  /// Whether the voice server can render speech right now.
  static bool get available => TtsManager.instance.serverAvailable;

  /// Starts the relay's export with the Voice provider's client ([dio] has the
  /// provider's base address and key). Null when the relay has no export
  /// (404), so the caller falls back.
  static Future<Mp3ExportTicket?> startWith(Dio dio, String text) async {
    try {
      final response = await dio.post<Object?>(
        'audio/export',
        data: {'text': text, 'wait': false},
        options: Options(
          sendTimeout: const Duration(seconds: 20),
          receiveTimeout: const Duration(seconds: 30),
        ),
      );
      final ticket = Mp3ExportTicket.fromJson(response.data);
      if (ticket == null) {
        throw StateError('The voice server sent no link for the MP3');
      }
      return ticket;
    } on DioException catch (error) {
      if (error.response?.statusCode == 404) return null;
      rethrow;
    }
  }

  /// Fetches a signed export link; the relay holds the request until the
  /// file is ready (up to 10 minutes).
  static Future<Uint8List> downloadSigned(String url) async {
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 20),
        receiveTimeout: const Duration(minutes: 11),
        responseType: ResponseType.bytes,
      ),
    );
    try {
      final response = await dio.get<List<int>>(url);
      final bytes = response.data;
      if (bytes == null || bytes.isEmpty) {
        throw StateError('The MP3 came back empty');
      }
      return Uint8List.fromList(bytes);
    } finally {
      dio.close();
    }
  }

  /// "about 40 s", "about 2 min"; empty without an estimate.
  static String etaWords(double? seconds) {
    if (seconds == null || seconds <= 0) return '';
    if (seconds < 60) return 'about ${seconds.round()} s';
    return 'about ${(seconds / 60).round()} min';
  }

  /// A short file name from the reply's first words, no spaces or marks that
  /// a share extension might trip on: "Heres-your-day.mp3".
  static String fileNameFor(String text, String extension) {
    final words = text
        .replaceAll("'", '')
        .replaceAll('’', '')
        .replaceAll(RegExp(r'[^A-Za-z0-9 ]+'), ' ')
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .take(6)
        .join('-');
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
  /// mime type. [onEstimate] gets the relay's estimate as soon as the export
  /// starts.
  Future<({File file, String mimeType})> export(
    String text, {
    void Function(Mp3ExportTicket ticket)? onEstimate,
  }) async {
    final clean = text.trim();
    if (clean.isEmpty) {
      throw ArgumentError('Nothing to read aloud in this reply');
    }
    Uint8List bytes;
    String mimeType;
    final start = _startRelayExport;
    final ticket = start == null ? null : await start(clean);
    if (ticket != null) {
      onEstimate?.call(ticket);
      bytes = await _download(ticket.url);
      mimeType = 'audio/mpeg';
    } else {
      final audio = await _render(clean);
      if (audio.bytes.isEmpty) {
        throw StateError('The voice server returned no audio');
      }
      bytes = audio.bytes;
      mimeType = audio.mimeType;
    }
    final ext = extensionFor(mimeType);
    final dir = await _tempDirectory();
    final shared = Directory('${dir.path}/shared-audio');
    await sweep(shared);
    final folder = Directory(
      '${shared.path}/${DateTime.now().millisecondsSinceEpoch}',
    );
    await folder.create(recursive: true);
    final file = File('${folder.path}/${fileNameFor(clean, ext)}');
    await file.writeAsBytes(bytes, flush: true);
    return (file: file, mimeType: mimeType);
  }

  /// Removes shared files older than a day: a file must outlive the share
  /// sheet (an extension may read it after the sheet closes), so nothing is
  /// deleted right after sharing.
  static Future<void> sweep(Directory shared, {DateTime? now}) async {
    try {
      if (!await shared.exists()) return;
      final cutoff = (now ?? DateTime.now()).subtract(
        const Duration(hours: 24),
      );
      await for (final entry in shared.list()) {
        final stat = await entry.stat();
        if (stat.modified.isBefore(cutoff)) {
          await entry.delete(recursive: true);
        }
      }
    } catch (_) {
      // Cleanup is best effort.
    }
  }

  static const _channel = MethodChannel('app.cogwheel.conduit/speech_engine');

  /// Opens the share sheet with [file] as a real .mp3 file (iOS: an item
  /// provider with the file's type and name, which Discord's extension reads;
  /// elsewhere share_plus). Returns whether it was shared.
  static Future<bool> shareFile(
    File file, {
    required String mimeType,
    String? title,
    Rect? origin,
  }) async {
    if (Platform.isIOS) {
      try {
        final done = await _channel.invokeMethod<bool>('shareAudioFile', {
          'path': file.path,
          'title': ?title,
          if (origin != null) ...{
            'x': origin.left,
            'y': origin.top,
            'w': origin.width,
            'h': origin.height,
          },
        });
        return done ?? false;
      } on MissingPluginException {
        // An older native side: share_plus below.
      }
    }
    final result = await SharePlus.instance.share(
      ShareParams(
        files: [
          XFile(
            file.path,
            name: file.uri.pathSegments.last,
            mimeType: mimeType,
          ),
        ],
        title: title,
        subject: title,
        sharePositionOrigin: origin,
      ),
    );
    return result.status == ShareResultStatus.success;
  }
}
