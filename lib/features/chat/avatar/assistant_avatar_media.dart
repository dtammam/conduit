import 'dart:io';

import 'package:conduit_core/utils/debug_logger.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'assistant_activity.dart';

const String _logScope = 'chat/avatar';

enum AssistantAvatarMediaKind { video, image }

/// One clip the avatar can show: a video or an image the user picked.
class AssistantAvatarMedia {
  const AssistantAvatarMedia.file(this.path, this.kind);

  /// The file system path of the clip.
  final String path;
  final AssistantAvatarMediaKind kind;

  /// Stable identity used to key video controllers.
  String get id => 'file:$path';
}

/// The clips on disk, read once at strip init and again after every change.
class AssistantAvatarMediaSet {
  const AssistantAvatarMediaSet({this.userFiles = const {}});

  static const empty = AssistantAvatarMediaSet();

  final Map<AssistantActivity, AssistantAvatarMedia> userFiles;

  /// The clip assigned to [state] itself, without any fallback.
  AssistantAvatarMedia? ownMedia(AssistantActivity state) => userFiles[state];

  /// The clip to show for [state]: its own, else
  /// [AssistantActivity.making] borrows the working clip and
  /// [AssistantActivity.done] the idle clip. Null means the strip shows the
  /// model's initial.
  AssistantAvatarMedia? resolve(AssistantActivity state) {
    final own = ownMedia(state);
    if (own != null) return own;
    return switch (state) {
      AssistantActivity.making => ownMedia(AssistantActivity.working),
      AssistantActivity.done => ownMedia(AssistantActivity.idle),
      AssistantActivity.idle || AssistantActivity.working => null,
    };
  }
}

const Set<String> _videoExtensions = {
  'mp4',
  'm4v',
  'mov',
  'webm',
  '3gp',
  'mkv',
};

AssistantAvatarMediaKind _kindForExtension(String extension) {
  final normalized = extension.replaceFirst('.', '').toLowerCase();
  return _videoExtensions.contains(normalized)
      ? AssistantAvatarMediaKind.video
      : AssistantAvatarMediaKind.image;
}

/// Reads and writes the per-state clips under
/// `<documents>/assistant_avatar/<state>.<ext>`. Presence on disk is the
/// only state; every operation logs and swallows its own failures.
class AssistantAvatarMediaStore {
  AssistantAvatarMediaStore({
    Future<Directory> Function()? documentsDirectory,
    Future<XFile?> Function()? pickMedia,
  }) : _documentsDirectory =
           documentsDirectory ?? getApplicationDocumentsDirectory,
       _pickMedia = pickMedia ?? (() => ImagePicker().pickMedia());

  final Future<Directory> Function() _documentsDirectory;
  final Future<XFile?> Function() _pickMedia;

  Future<Directory> _folder() async {
    final documents = await _documentsDirectory();
    return Directory(p.join(documents.path, 'assistant_avatar'));
  }

  /// Everything currently available. Never throws.
  Future<AssistantAvatarMediaSet> load() async =>
      AssistantAvatarMediaSet(userFiles: await _loadUserFiles());

  Future<Map<AssistantActivity, AssistantAvatarMedia>> _loadUserFiles() async {
    final found = <AssistantActivity, AssistantAvatarMedia>{};
    try {
      final folder = await _folder();
      if (!await folder.exists()) return found;
      await for (final entity in folder.list(followLinks: false)) {
        if (entity is! File) continue;
        final name = p.basenameWithoutExtension(entity.path);
        final state = AssistantActivity.values
            .where((value) => value.name == name)
            .firstOrNull;
        if (state == null) continue;
        found[state] = AssistantAvatarMedia.file(
          entity.path,
          _kindForExtension(p.extension(entity.path)),
        );
      }
    } catch (error, stackTrace) {
      DebugLogger.error(
        'load-user-files-failed',
        scope: _logScope,
        error: error,
        stackTrace: stackTrace,
      );
    }
    return found;
  }

  /// Opens the photo library and stores the picked video or image as the
  /// clip for [state]. Returns false when the copy failed, null when the
  /// user cancelled, true when stored.
  Future<bool?> pickAndAssign(AssistantActivity state) async {
    final XFile? picked;
    try {
      picked = await _pickMedia();
    } catch (error, stackTrace) {
      DebugLogger.error(
        'pick-failed',
        scope: _logScope,
        error: error,
        stackTrace: stackTrace,
      );
      return false;
    }
    if (picked == null) return null;
    return assign(state, picked);
  }

  /// Replaces the clip for [state] with [source]. Returns whether it stored.
  Future<bool> assign(AssistantActivity state, XFile source) async {
    try {
      var extension = p.extension(source.name).replaceFirst('.', '');
      if (extension.isEmpty) {
        extension = p.extension(source.path).replaceFirst('.', '');
      }
      if (extension.isEmpty) {
        extension = (source.mimeType?.startsWith('video/') ?? false)
            ? 'mp4'
            : 'jpg';
      }
      final folder = await _folder();
      await folder.create(recursive: true);
      await _deleteExisting(folder, state);
      final target = p.join(folder.path, '${state.name}.$extension');
      await source.saveTo(target);
      DebugLogger.log(
        'assigned',
        scope: _logScope,
        data: {'state': state.name, 'extension': extension},
      );
      return true;
    } catch (error, stackTrace) {
      DebugLogger.error(
        'assign-failed',
        scope: _logScope,
        error: error,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  /// Deletes the user file for [state].
  Future<void> remove(AssistantActivity state) async {
    try {
      final folder = await _folder();
      if (!await folder.exists()) return;
      await _deleteExisting(folder, state);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'remove-failed',
        scope: _logScope,
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _deleteExisting(
    Directory folder,
    AssistantActivity state,
  ) async {
    await for (final entity in folder.list(followLinks: false)) {
      if (entity is File &&
          p.basenameWithoutExtension(entity.path) == state.name) {
        await entity.delete();
      }
    }
  }
}
