import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:conduit_core/ports/progressive_audio.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:path/path.dart' as p;

import 'speech_take_join.dart';
import 'speech_take_store.dart';

/// Keeps the sentence clips of one spoken reply while it plays, so that if it
/// plays to the end they become one saved take.
///
/// It is a second reader: a streamed clip is read from its own first byte by
/// a listener that writes each piece to a file, and the player keeps reading
/// the clip as before. Nothing here waits on playback, and nothing here can
/// throw into it: every failure only means no take.
///
/// A recorder is for one play. [finish] says the whole reply played to its
/// end; [discard] says it did not (stop, barge-in, skip, error).
class SpeechTakeRecorder {
  SpeechTakeRecorder({
    required this.store,
    required this.voiceKey,
    required this.sessionName,
    this.messageId = '',
    this.chatId,
    this.text,
  });

  final SpeechTakeStore store;
  final String voiceKey;
  final String sessionName;

  /// The message this is the reply of; empty for a voice call, where the take
  /// is found later by its text and voice.
  final String messageId;
  final String? chatId;

  /// The text the reply was read from. A voice call only knows it at the end.
  String? text;

  final Map<int, _Tee> _tees = <int, _Tee>{};
  Future<Directory>? _directory;
  bool _closed = false;

  Future<Directory> _dir() =>
      _directory ??= store.workDirectory(sessionName);

  /// Starts keeping clip [index]: [progressive] while it arrives, else
  /// [bytes]. A later call for the same index replaces the earlier one (a
  /// clip fetched again).
  void addClip(
    int index, {
    ProgressiveAudio? progressive,
    Uint8List? bytes,
    required String mimeType,
  }) {
    if (_closed) return;
    try {
      _tees.remove(index)?.abandon();
      final tee = _Tee(progressive: progressive, mimeType: mimeType);
      _tees[index] = tee;
      tee.done = _write(index, tee, bytes);
    } catch (error) {
      _log('speech-take-add-failed', error);
    }
  }

  Future<void> _write(int index, _Tee tee, Uint8List? bytes) async {
    try {
      final dir = await _dir();
      final file = File(p.join(dir.path, 'clip_$index.part'));
      tee.file = file;
      final progressive = tee.progressive;
      if (progressive == null) {
        if (bytes == null || bytes.isEmpty) {
          tee.failed = true;
          return;
        }
        await file.writeAsBytes(bytes, flush: true);
        return;
      }
      final sink = file.openWrite();
      final finished = tee.finished;
      tee.subscription = progressive.read().listen(
        (piece) {
          if (!tee.abandoned) sink.add(piece);
        },
        onError: (Object _) {
          tee.failed = true;
        },
        onDone: () {
          if (!finished.isCompleted) finished.complete();
        },
        cancelOnError: true,
      );
      await finished.future;
      await sink.flush();
      await sink.close();
    } catch (error) {
      tee.failed = true;
      _log('speech-take-write-failed', error);
    }
  }

  /// The reply played to its end: join the [clipCount] clips and keep them as
  /// the take. Returns the take, or null when it could not be kept (a clip
  /// missing, cut short or cancelled, an unjoinable mix, a failed write).
  Future<SpeechTake?> finish({required int clipCount, String? finalText}) async {
    if (_closed) return null;
    _closed = true;
    // Judged now, before the manager tears the streams down (which marks even
    // a finished stream cancelled).
    var valid = clipCount > 0;
    final ordered = <_Tee>[];
    for (var i = 0; i < clipCount && valid; i++) {
      final tee = _tees[i];
      final progressive = tee?.progressive;
      if (tee == null ||
          tee.failed ||
          (progressive != null &&
              (!progressive.isDone ||
                  progressive.isCancelled ||
                  progressive.error != null))) {
        valid = false;
      } else {
        ordered.add(tee);
      }
    }
    final keepText = finalText ?? text;
    try {
      if (!valid || keepText == null || keepText.trim().isEmpty) {
        return null;
      }
      await Future.wait(ordered.map((t) => t.done ?? Future<void>.value()));
      if (ordered.any((t) => t.failed || t.file == null)) return null;
      final dir = await _dir();
      final outBase = p.join(dir.path, 'joined');
      final paths = [for (final t in ordered) t.file!.path];
      final kinds = [for (final t in ordered) SpeechTakeJoin.kindOf(t.mimeType)];
      final joined = await Isolate.run(
        () => joinClipFiles(paths, kinds, outBase),
      );
      final extension = joined?.extension;
      if (joined == null || extension == null) {
        DebugLogger.info(
          'speech-take-unjoinable',
          scope: 'chat/take',
          data: {'clips': clipCount, 'kinds': kinds.toSet().toList()},
        );
        return null;
      }
      return await store.save(
        messageId: messageId,
        voiceKey: voiceKey,
        text: keepText,
        source: File('$outBase.$extension'),
        extension: extension,
        chatId: chatId,
        clipSizes: joined.clipSizes,
      );
    } catch (error) {
      _log('speech-take-save-failed', error);
      return null;
    } finally {
      unawaited(_cleanUp());
    }
  }

  /// The reply did not play to its end: keep nothing.
  void discard() {
    if (_closed) return;
    _closed = true;
    for (final tee in _tees.values) {
      tee.abandon();
    }
    unawaited(_cleanUp());
  }

  Future<void> _cleanUp() async {
    try {
      for (final tee in _tees.values) {
        await tee.subscription?.cancel();
      }
      final directory = _directory;
      if (directory != null) {
        final dir = await directory;
        if (await dir.exists()) await dir.delete(recursive: true);
      }
    } catch (_) {}
  }

  void _log(String event, Object error) {
    DebugLogger.warning(
      event,
      scope: 'chat/take',
      data: {'error': error.toString()},
    );
  }
}

class _Tee {
  _Tee({required this.progressive, required this.mimeType});

  final ProgressiveAudio? progressive;
  final String mimeType;
  File? file;
  Future<void>? done;
  StreamSubscription<List<int>>? subscription;
  final Completer<void> finished = Completer<void>();
  bool failed = false;
  bool abandoned = false;

  void abandon() {
    abandoned = true;
    failed = true;
    unawaited(subscription?.cancel());
    if (!finished.isCompleted) finished.complete();
  }
}

/// Joins the clip files at [paths] into `<outBase>.<ext>`; returns the
/// extension and each clip's byte share (mp3), or null when they cannot be joined. Runs in an isolate.
({String extension, List<int>? clipSizes})? joinClipFiles(
  List<String> paths,
  List<String?> kinds,
  String outBase,
) {
  final clips = [for (final path in paths) File(path).readAsBytesSync()];
  final joined = SpeechTakeJoin.join(clips, kinds);
  if (joined == null) return null;
  File('$outBase.${joined.extension}').writeAsBytesSync(
    joined.bytes,
    flush: true,
  );
  return (extension: joined.extension, clipSizes: joined.clipSizes);
}
