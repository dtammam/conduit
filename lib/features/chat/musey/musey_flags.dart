import 'dart:async';
import 'dart:convert';

import 'package:conduit_core/models/chat_message.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'musey_api.dart';

const String _queueKey = 'musey_flag_queue_v1';
const String _flaggedKey = 'musey_flagged_ids_v1';

/// The reply Dean marked with the break reaction, waiting for his note. The
/// next message he sends goes to the relay's flag log instead of the chat.
@immutable
class BreakFlagTarget {
  const BreakFlagTarget({
    required this.chatId,
    required this.messageId,
    required this.replyText,
    required this.userText,
  });

  final String chatId;
  final String messageId;
  final String replyText;

  /// The user message the reply answered; empty when there was none.
  final String userText;
}

/// The pending "What broke?" prompt, or null in normal sending.
final breakPromptProvider = NotifierProvider<BreakPrompt, BreakFlagTarget?>(
  BreakPrompt.new,
);

class BreakPrompt extends Notifier<BreakFlagTarget?> {
  @override
  BreakFlagTarget? build() => null;

  /// Starts the prompt for [target], marking the reply. A second tap on
  /// another reply moves the prompt there.
  void start(BreakFlagTarget target) {
    final previous = state;
    if (previous != null && previous.messageId != target.messageId) {
      ref.read(flaggedMessagesProvider.notifier).remove(previous.messageId);
    }
    ref.read(flaggedMessagesProvider.notifier).add(target.messageId);
    state = target;
  }

  /// The cancel x: back to normal sending, and the mark comes off.
  void cancel() {
    final target = state;
    if (target == null) return;
    ref.read(flaggedMessagesProvider.notifier).remove(target.messageId);
    state = null;
  }

  /// Takes the pending target for the note being sent, ending the prompt.
  /// The mark stays: the reply is flagged.
  BreakFlagTarget? take() {
    final target = state;
    state = null;
    return target;
  }
}

/// Ids of the replies marked 💥, kept on the phone so the badge survives a
/// restart. The mark is only a badge: what was flagged is in the relay's log.
final flaggedMessagesProvider =
    NotifierProvider<FlaggedMessages, Set<String>>(FlaggedMessages.new);

class FlaggedMessages extends Notifier<Set<String>> {
  bool _loaded = false;

  @override
  Set<String> build() {
    unawaited(_load());
    return const <String>{};
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getStringList(_flaggedKey) ?? const <String>[];
      if (!ref.mounted) return;
      _loaded = true;
      if (stored.isNotEmpty) state = {...stored, ...state};
    } catch (_) {
      _loaded = true;
    }
  }

  void add(String id) {
    if (state.contains(id)) return;
    state = {...state, id};
    unawaited(_save());
  }

  void remove(String id) {
    if (!state.contains(id)) return;
    state = {...state}..remove(id);
    unawaited(_save());
  }

  Future<void> _save() async {
    if (!_loaded) await _load();
    try {
      final prefs = await SharedPreferences.getInstance();
      // Keep the newest few hundred so the list cannot grow without bound.
      final ids = state.toList();
      final kept = ids.length > 300 ? ids.sublist(ids.length - 300) : ids;
      await prefs.setStringList(_flaggedKey, kept);
    } catch (_) {}
  }
}

/// Flags that were posted, or failed and wait for the next launch. A flag is
/// written to disk before the first post, and leaves the queue only when the
/// relay took it, so a failure never drops a note.
class MuseyFlagQueue {
  MuseyFlagQueue(this._api);

  final MuseyApi? Function() _api;
  bool _draining = false;

  /// Everything still waiting, oldest first.
  Future<List<MuseyFlag>> pending() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(_queueKey) ?? const <String>[];
      return [
        for (final item in raw)
          ?MuseyFlag.fromQueueJson(_decode(item)),
      ];
    } catch (_) {
      return const <MuseyFlag>[];
    }
  }

  Object? _decode(String s) {
    try {
      return jsonDecode(s);
    } catch (_) {
      return null;
    }
  }

  Future<void> _write(List<MuseyFlag> flags) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_queueKey, [
      for (final f in flags) jsonEncode(f.toQueueJson()),
    ]);
  }

  /// Saves [flag] locally, then posts it. True when the relay took it now;
  /// false means it is queued and [retryAll] will try again.
  Future<bool> submit(MuseyFlag flag) async {
    final queued = await pending();
    await _write([...queued, flag]);
    final ok = await _post(flag);
    if (ok) await _remove(flag.localId);
    return ok;
  }

  Future<bool> _post(MuseyFlag flag) async {
    final api = _api();
    if (api == null) return false;
    try {
      return await api.postFlag(flag);
    } catch (_) {
      return false;
    }
  }

  Future<void> _remove(String localId) async {
    final queued = await pending();
    await _write([
      for (final f in queued)
        if (f.localId != localId) f,
    ]);
  }

  /// Posts what is waiting, oldest first, stopping at the first failure so
  /// the order holds. Returns how many went out.
  Future<int> retryAll() async {
    if (_draining) return 0;
    _draining = true;
    var sent = 0;
    try {
      for (final flag in await pending()) {
        if (!await _post(flag)) break;
        await _remove(flag.localId);
        sent++;
      }
    } finally {
      _draining = false;
    }
    return sent;
  }
}

final museyFlagQueueProvider = Provider<MuseyFlagQueue>(
  (ref) => MuseyFlagQueue(() => ref.read(museyApiProvider)),
);

int _flagCounter = 0;

/// A queue id that is unique on this phone.
String newFlagLocalId() =>
    '${DateTime.now().microsecondsSinceEpoch}-${_flagCounter++}';

/// The target for a 💥 on the assistant message [messageId]: its text and the
/// text of the user message before it. Null when the message is not there.
BreakFlagTarget? buildBreakTarget(
  List<ChatMessage> messages, {
  required String chatId,
  required String messageId,
}) {
  final index = messages.indexWhere((m) => m.id == messageId);
  if (index < 0) return null;
  var userText = '';
  for (var i = index - 1; i >= 0; i--) {
    if (messages[i].role == 'user') {
      userText = messages[i].content;
      break;
    }
  }
  return BreakFlagTarget(
    chatId: chatId,
    messageId: messageId,
    replyText: messages[index].content,
    userText: userText,
  );
}

/// Posts [note] about [target] to the relay's flag log through [queue]. True
/// when the relay took it; false means it is saved and will be retried.
Future<bool> submitBreakNote(
  MuseyFlagQueue queue,
  BreakFlagTarget target,
  String note, {
  required String build,
  String? persona,
  DateTime? now,
}) => queue.submit(
  MuseyFlag(
    localId: newFlagLocalId(),
    chatId: target.chatId,
    messageId: target.messageId,
    replyText: target.replyText,
    userText: target.userText,
    note: note,
    ts: now ?? DateTime.now(),
    build: build,
    persona: persona,
  ),
);
