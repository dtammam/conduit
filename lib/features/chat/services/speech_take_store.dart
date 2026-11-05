import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:conduit_core/utils/debug_logger.dart';
import 'package:conduit_markdown/conduit_markdown.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// A reply's audio as it was heard (or last previewed): one file on the
/// phone, for one voice and one text.
class SpeechTake {
  const SpeechTake({
    required this.file,
    required this.extension,
    required this.created,
    required this.bytes,
    required this.messageId,
    required this.voiceKey,
  });

  final File file;
  final String extension;
  final DateTime created;
  final int bytes;
  final String messageId;
  final String voiceKey;

  String get mimeType => extension == 'wav' ? 'audio/wav' : 'audio/mpeg';
}

/// The saved takes: `speech_takes/<message id>/<voice>.<ext>` in the app's
/// support folder (kept out of backups), each with a small `.json` beside it
/// that says which text and voice it is.
///
/// Breeze renders differently every time, so the take Dean heard is the one
/// worth keeping. One take per message and voice; saving a newer one replaces
/// it. A take is only handed back for the same text it was made from. Nothing
/// here ever leaves the phone: sharing copies a take out on request.
class SpeechTakeStore {
  SpeechTakeStore({
    Future<Directory> Function()? supportDirectory,
    DateTime Function()? now,
    Future<void> Function(Directory directory)? excludeFromBackup,
  }) : _support = supportDirectory ?? getApplicationSupportDirectory,
       _now = now ?? DateTime.now,
       _exclude = excludeFromBackup ?? _excludeNatively;

  static final SpeechTakeStore instance = SpeechTakeStore();

  /// Takes older than this are removed at launch.
  static const Duration maxAge = Duration(days: 30);

  /// Past this many bytes in all, the oldest takes are removed first.
  static const int maxBytes = 500 * 1024 * 1024;

  static const _folder = 'speech_takes';
  static const _unclaimed = '_unclaimed';
  static const _work = '_work';
  static const _channel = MethodChannel('app.cogwheel.conduit/speech_engine');

  final Future<Directory> Function() _support;
  final DateTime Function() _now;
  final Future<void> Function(Directory directory) _exclude;
  Directory? _root;

  /// The text as a key: what is spoken, without markup, case or spacing, so
  /// the text a reply was read from and the text the share offers compare
  /// equal while an edit that changes a word does not.
  static String textKey(String text) {
    final spoken = ConduitMarkdownPreprocessor.cleanText(text);
    final letters = spoken
        .toLowerCase()
        .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), '');
    return sha1.convert(utf8.encode(letters)).toString();
  }

  static String _voiceName(String voiceKey) =>
      sha1.convert(utf8.encode(voiceKey)).toString().substring(0, 16);

  static String _safe(String id) {
    final clean = id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return clean.length > 80 ? clean.substring(0, 80) : clean;
  }

  Future<Directory> _rootDirectory() async {
    final cached = _root;
    if (cached != null) return cached;
    final support = await _support();
    final root = Directory(p.join(support.path, _folder));
    if (!await root.exists()) {
      await root.create(recursive: true);
    }
    try {
      await _exclude(root);
    } catch (_) {
      // Best effort: the files are small and only on this phone either way.
    }
    return _root = root;
  }

  /// A fresh folder for a recording in progress (not a take yet).
  Future<Directory> workDirectory(String name) async {
    final root = await _rootDirectory();
    final dir = Directory(p.join(root.path, _work, _safe(name)));
    await dir.create(recursive: true);
    return dir;
  }

  /// The take for [messageId] in [voiceKey] when it was made from [text];
  /// null when there is none or the text has changed since.
  ///
  /// A take heard in a voice call has no message yet. It is found by its
  /// text and voice and then filed under [messageId] (and [chatId]).
  Future<SpeechTake?> find({
    required String messageId,
    required String voiceKey,
    required String text,
    String? chatId,
  }) async {
    try {
      final root = await _rootDirectory();
      final key = textKey(text);
      final name = _voiceName(voiceKey);
      final own = await _read(
        Directory(p.join(root.path, _safe(messageId))),
        name,
      );
      if (own != null) {
        if (own.textKey == key) return own.take;
        // The text moved on: this take is no longer this reply's.
        await _delete(own);
        return null;
      }
      final loose = await _read(
        Directory(p.join(root.path, _unclaimed)),
        '$key-$name',
      );
      if (loose != null && loose.textKey == key) {
        return await _file(loose, messageId, chatId);
      }
    } catch (error) {
      DebugLogger.warning(
        'speech-take-find-failed',
        scope: 'chat/take',
        data: {'error': error.toString()},
      );
    }
    return null;
  }

  /// Keeps [source] (copied) as the take for [messageId] in [voiceKey],
  /// replacing the one there. An empty [messageId] keeps it unclaimed, to be
  /// found by text and voice. Throws if it cannot be written.
  Future<SpeechTake> save({
    required String messageId,
    required String voiceKey,
    required String text,
    required File source,
    required String extension,
    String? chatId,
    String? keyOverride,
  }) async {
    final root = await _rootDirectory();
    final key = keyOverride ?? textKey(text);
    final name = _voiceName(voiceKey);
    final claimed = messageId.isNotEmpty;
    final dir = Directory(
      p.join(root.path, claimed ? _safe(messageId) : _unclaimed),
    );
    await dir.create(recursive: true);
    final base = claimed ? name : '$key-$name';
    // Written under a temporary name and renamed, so a half-written file is
    // never mistaken for a take.
    // A replaced take may have another extension.
    await _deleteStem(dir, base);
    final partial = File(p.join(dir.path, '$base.partial'));
    await source.copy(partial.path);
    final target = File(p.join(dir.path, '$base.$extension'));
    await partial.rename(target.path);
    final bytes = await target.length();
    final created = _now();
    await File(p.join(dir.path, '$base.json')).writeAsString(
      jsonEncode({
        'messageId': messageId,
        'chatId': ?chatId,
        'voice': voiceKey,
        'textKey': key,
        'created': created.toIso8601String(),
        'ext': extension,
        'bytes': bytes,
      }),
      flush: true,
    );
    return SpeechTake(
      file: target,
      extension: extension,
      created: created,
      bytes: bytes,
      messageId: messageId,
      voiceKey: voiceKey,
    );
  }

  /// Removes every take of these messages.
  Future<void> removeMessages(Iterable<String> messageIds) async {
    try {
      final root = await _rootDirectory();
      for (final id in messageIds) {
        final dir = Directory(p.join(root.path, _safe(id)));
        if (await dir.exists()) await dir.delete(recursive: true);
      }
    } catch (_) {}
  }

  /// Removes every take that belongs to a chat (a deleted chat).
  Future<void> removeChat(String chatId) async {
    try {
      final root = await _rootDirectory();
      await for (final entry in root.list()) {
        if (entry is! Directory) continue;
        final name = p.basename(entry.path);
        if (name == _work) continue;
        var remaining = 0;
        await for (final f in entry.list()) {
          if (!f.path.endsWith('.json')) continue;
          Map<String, Object?>? meta;
          try {
            meta = (jsonDecode(await File(f.path).readAsString()) as Map)
                .cast<String, Object?>();
          } catch (_) {}
          if (meta != null && meta['chatId'] == chatId) {
            await _deleteStem(entry, p.basenameWithoutExtension(f.path));
          } else {
            remaining++;
          }
        }
        if (remaining == 0 && await entry.exists()) {
          await entry.delete(recursive: true);
        }
      }
    } catch (_) {}
  }

  /// Removes takes past [maxAge], then the oldest past [maxBytes], and any
  /// recording a crash left behind. Runs in another isolate.
  Future<void> sweep({Duration? age, int? cap}) async {
    try {
      final root = await _rootDirectory();
      final path = root.path;
      final nowMs = _now().millisecondsSinceEpoch;
      final ageMs = (age ?? maxAge).inMilliseconds;
      final capBytes = cap ?? maxBytes;
      await Isolate.run(() => sweepSync(path, nowMs, ageMs, capBytes));
    } catch (error) {
      DebugLogger.warning(
        'speech-take-sweep-failed',
        scope: 'chat/take',
        data: {'error': error.toString()},
      );
    }
  }

  /// The sweep itself, on plain synchronous file calls. Public for tests.
  static void sweepSync(String root, int nowMs, int maxAgeMs, int capBytes) {
    final dir = Directory(root);
    if (!dir.existsSync()) return;
    final work = Directory(p.join(root, _work));
    if (work.existsSync()) work.deleteSync(recursive: true);
    final takes = <({File file, File? meta, int created, int bytes})>[];
    for (final folder in dir.listSync().whereType<Directory>()) {
      for (final f in folder.listSync().whereType<File>()) {
        final path = f.path;
        if (path.endsWith('.json')) continue;
        final stem = p.withoutExtension(path);
        final meta = File('$stem.json');
        var created = f.statSync().modified.millisecondsSinceEpoch;
        if (path.endsWith('.partial')) {
          f.deleteSync();
          continue;
        }
        if (meta.existsSync()) {
          try {
            final decoded = jsonDecode(meta.readAsStringSync());
            final when = DateTime.tryParse(
              (decoded as Map)['created'] as String? ?? '',
            );
            if (when != null) created = when.millisecondsSinceEpoch;
          } catch (_) {}
        }
        takes.add((
          file: f,
          meta: meta.existsSync() ? meta : null,
          created: created,
          bytes: f.lengthSync(),
        ));
      }
    }
    void drop(({File file, File? meta, int created, int bytes}) t) {
      try {
        t.file.deleteSync();
      } catch (_) {}
      try {
        t.meta?.deleteSync();
      } catch (_) {}
    }

    var kept = <({File file, File? meta, int created, int bytes})>[];
    for (final t in takes) {
      if (nowMs - t.created > maxAgeMs) {
        drop(t);
      } else {
        kept.add(t);
      }
    }
    var total = kept.fold<int>(0, (sum, t) => sum + t.bytes);
    if (total > capBytes) {
      kept.sort((a, b) => a.created.compareTo(b.created));
      final left = <({File file, File? meta, int created, int bytes})>[];
      for (final t in kept) {
        if (total > capBytes) {
          drop(t);
          total -= t.bytes;
        } else {
          left.add(t);
        }
      }
      kept = left;
    }
    for (final folder in dir.listSync().whereType<Directory>()) {
      if (folder.listSync().isEmpty) folder.deleteSync();
    }
  }

  // ---------------------------------------------------------------- files

  Future<_Entry?> _read(Directory dir, String stem) async {
    final meta = File(p.join(dir.path, '$stem.json'));
    if (!await meta.exists()) return null;
    try {
      final map = (jsonDecode(await meta.readAsString()) as Map)
          .cast<String, Object?>();
      final ext = map['ext'] as String? ?? 'mp3';
      final file = File(p.join(dir.path, '$stem.$ext'));
      if (!await file.exists()) return null;
      return _Entry(
        take: SpeechTake(
          file: file,
          extension: ext,
          created:
              DateTime.tryParse(map['created'] as String? ?? '') ?? _now(),
          bytes: await file.length(),
          messageId: map['messageId'] as String? ?? '',
          voiceKey: map['voice'] as String? ?? '',
        ),
        textKey: map['textKey'] as String? ?? '',
        stem: stem,
        dir: dir,
        chatId: map['chatId'] as String?,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _delete(_Entry entry) => _deleteStem(entry.dir, entry.stem);

  Future<void> _deleteStem(Directory dir, String stem) async {
    try {
      await for (final f in dir.list()) {
        if (p.basenameWithoutExtension(f.path) == stem && f is File) {
          await f.delete();
        }
      }
    } catch (_) {}
  }

  /// Moves an unclaimed take under [messageId].
  Future<SpeechTake?> _file(
    _Entry loose,
    String messageId,
    String? chatId,
  ) async {
    if (messageId.isEmpty) return loose.take;
    try {
      final saved = await save(
        messageId: messageId,
        voiceKey: loose.take.voiceKey,
        text: '',
        source: loose.take.file,
        extension: loose.take.extension,
        chatId: chatId ?? loose.chatId,
        keyOverride: loose.textKey,
      );
      await _deleteStem(loose.dir, loose.stem);
      return saved;
    } catch (_) {
      return loose.take;
    }
  }

  static Future<void> _excludeNatively(Directory directory) async {
    if (!Platform.isIOS) return;
    try {
      await _channel.invokeMethod<bool>('excludeFromBackup', {
        'path': directory.path,
      });
    } on MissingPluginException {
      // An older native side.
    }
  }
}

class _Entry {
  const _Entry({
    required this.take,
    required this.textKey,
    required this.stem,
    required this.dir,
    required this.chatId,
  });

  final SpeechTake take;
  final String textKey;
  final String stem;
  final Directory dir;
  final String? chatId;
}
