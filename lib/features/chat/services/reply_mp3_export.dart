import 'dart:io';

import 'package:conduit_core/utils/debug_logger.dart';
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
  ///
  /// [background] marks a render nobody is waiting for (preparing a reply's
  /// audio ahead): the relay ranks it below live speech and below a Share or
  /// Try again, which send no priority header.
  static Future<Mp3ExportTicket?> startWith(
    Dio dio,
    String text, {
    bool background = false,
  }) async {
    try {
      final response = await dio.post<Object?>(
        'audio/export',
        data: {'text': text, 'wait': false},
        options: Options(
          sendTimeout: const Duration(seconds: 20),
          // The relay answers at once with a link; generous in case it is busy.
          receiveTimeout: const Duration(seconds: 60),
          headers: {if (background) priorityHeader: 'background'},
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

  /// The header that ranks a render below live speech and a pressed Share.
  static const String priorityHeader = 'x-audio-export-priority';

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

  /// Copies a saved take into the share folder under a name from the reply's
  /// first words, ready for the share sheet. The take itself stays where it
  /// is; this copy is swept after a day like any other shared file.
  Future<({File file, String mimeType})> stage(
    File take,
    String text,
    String mimeType,
  ) async {
    final dir = await _tempDirectory();
    final shared = Directory('${dir.path}/shared-audio');
    await sweep(shared);
    final folder = Directory(
      '${shared.path}/${DateTime.now().millisecondsSinceEpoch}',
    );
    await folder.create(recursive: true);
    final file = File(
      '${folder.path}/${fileNameFor(text, extensionFor(mimeType))}',
    );
    await take.copy(file.path);
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

  /// Makes an .mp4 next to [mp3] whose sound is the MP3 and whose picture is
  /// [clipPath] (a video file, or a bundled asset key with [clipIsAsset])
  /// looped to the audio's length, or [imagePath] held still. iOS only.
  static Future<File> makeVideo(
    File mp3, {
    String? clipPath,
    bool clipIsAsset = false,
    String? imagePath,
  }) async {
    final name = mp3.uri.pathSegments.last.replaceFirst(
      RegExp(r'\.[A-Za-z0-9]+$'),
      '',
    );
    final out = File('${mp3.parent.path}/$name.mp4');
    final path = await _channel.invokeMethod<String>('makeReplyVideo', {
      'audio': mp3.path,
      'out': out.path,
      'clip': ?clipPath,
      'clipIsAsset': clipIsAsset,
      'image': ?imagePath,
    });
    if (path == null) throw StateError('The video was not made');
    return File(path);
  }

  /// Save to Files (iOS export picker with a copy). Returns whether a place
  /// was picked; false where there is no native picker.
  static Future<bool> saveToFiles(File file) async {
    if (!Platform.isIOS) return false;
    try {
      final done = await _channel.invokeMethod<bool>('saveAudioFile', {
        'path': file.path,
      });
      return done ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Converts the rendered MP3 to an AAC .m4a (iOS, AVAssetExportPresetAppleM4A,
  /// staged in tmp/share/). Discord attaches an m4a shared as a plain file and
  /// does not attach an MP3 (2026-11-01); iMessage takes m4a. Elsewhere, or on
  /// an older native side, the MP3 comes back unchanged.
  static Future<File> toM4a(File file) async {
    if (!Platform.isIOS) return file;
    try {
      final path = await _channel.invokeMethod<String>('exportM4a', {
        'path': file.path,
      });
      return path == null ? file : File(path);
    } on MissingPluginException {
      return file;
    }
  }

  /// Opens the share sheet with [file] as a plain file (iOS: a file URL only,
  /// which Discord's extension reads; elsewhere share_plus). Logs what iOS
  /// reported (activityType, completed). Returns whether it was shared.
  static Future<bool> shareFile(
    File file, {
    required String mimeType,
    String? title,
    Rect? origin,
  }) async {
    if (Platform.isIOS) {
      try {
        final done = await _channel.invokeMapMethod<String, Object?>(
          'shareAudioFile',
          {
            'path': file.path,
            'title': ?title,
            if (origin != null) ...{
              'x': origin.left,
              'y': origin.top,
              'w': origin.width,
              'h': origin.height,
            },
          },
        );
        final completed = done?['completed'] == true;
        DebugLogger.info(
          'share-result',
          scope: 'chat/share',
          data: {
            'completed': completed,
            'activityType': done?['activityType'] ?? '',
            'file': file.uri.pathSegments.last,
          },
        );
        return completed;
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
        sharePositionOrigin: origin,
      ),
    );
    return result.status == ShareResultStatus.success;
  }
}
