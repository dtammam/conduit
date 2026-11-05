import 'dart:async';

import 'package:conduit_core/utils/debug_logger.dart';

import 'reply_audio_flow.dart';
import 'speech_take_store.dart';

/// A finished reply whose audio may be prepared.
class ReplyAudioPrefetchItem {
  const ReplyAudioPrefetchItem({
    required this.messageId,
    required this.text,
    this.chatId,
    this.latestText,
  });

  /// The speech text as it stands when the render is about to start (a reply
  /// that has only just finished may still be settling); null keeps [text].
  final String Function()? latestText;

  final String messageId;

  /// The speech text, exactly as Listen and Share build it for this reply.
  final String text;
  final String? chatId;
}

/// Renders the audio of finished replies in the background, one at a time, so
/// Listen finds a take ready and Share needs no wait.
///
/// Live speech always wins: nothing starts while Dean is listening or on a
/// call or while the app is not in front, and pressing Listen on a reply being
/// rendered drops that render. Renders go through [render] (the relay's
/// non-streamed export) and are kept only if nothing else made a take first.
/// Failures are silent and not retried until the chat is opened again.
class ReplyAudioPrefetcher {
  ReplyAudioPrefetcher({
    required this.enabled,
    required this.liveSpeechBusy,
    required this.appActive,
    required this.requestFor,
    required this.render,
    required this.savedTake,
    this.delay = const Duration(seconds: 3),
    this.recheck = const Duration(seconds: 4),
    this.maxRechecks = 45,
    this.openCap = 5,
    this.maxChars = 4000,
  });

  final bool Function() enabled;
  final bool Function() liveSpeechBusy;
  final bool Function() appActive;

  /// The request for [item] in the voice in use now (so a changed voice or
  /// persona renders for the new voice only).
  final ReplyAudioRequest Function(ReplyAudioPrefetchItem item) requestFor;
  final Future<SpeechTake> Function(
    ReplyAudioRequest request, {
    required bool Function() stillWanted,
  })
  render;
  final Future<SpeechTake?> Function(ReplyAudioRequest request) savedTake;

  /// Wait after a reply ends before its render may start.
  final Duration delay;

  /// How often a render held back by live speech looks again, and how many
  /// times before it gives up until the chat is opened again (about 3 min).
  final Duration recheck;
  final int maxRechecks;

  /// Most replies rendered when a chat is opened (newest first).
  final int openCap;

  /// Longer replies are left for Share to render on request. Background
  /// exports yield to live speech and can run well over their measured time;
  /// the relay holds a render link for 10 minutes, so this keeps one well
  /// inside it (about 4 minutes of audio).
  final int maxChars;

  final List<_Job> _queue = <_Job>[];
  final Map<String, _Job> _active = <String, _Job>{};
  final Set<String> _failed = <String>{};
  String? _openChat;
  int _openAccepted = 0;
  bool _pumping = false;

  /// Renders started since creation, for tests and the log.
  int started = 0;

  /// A reply just finished streaming in the chat Dean is using.
  void replyFinished(ReplyAudioPrefetchItem item) {
    if (!_worthy(item)) return;
    _enqueue(item, front: true);
  }

  /// A reply shown when a chat is opened. Up to [openCap] without a take are
  /// rendered, newest first (the caller offers them newest first).
  Future<void> chatOpened(ReplyAudioPrefetchItem item) async {
    if (!_worthy(item)) return;
    final chat = item.chatId ?? '';
    if (chat != _openChat) {
      _openChat = chat;
      _openAccepted = 0;
      _failed.clear();
    }
    if (_openAccepted >= openCap) return;
    final request = requestFor(item);
    if (await savedTake(request) != null) return;
    if (_openAccepted >= openCap) return;
    if (_enqueue(item, front: false)) _openAccepted++;
  }

  /// Listen was pressed, or Share was (Share sends its own request, ranked
  /// above background ones): this reply's background render, queued or
  /// running, is dropped and its result thrown away.
  void drop(String messageId) {
    _queue.removeWhere((job) {
      if (job.item.messageId != messageId) return false;
      job.cancelled = true;
      job.done.complete();
      return true;
    });
    _active[messageId]?.cancelled = true;
  }

  /// Completes when this reply's render ends (made, failed or dropped); null
  /// when none is queued or running.
  Future<void>? inFlightFor(String messageId) {
    final active = _active[messageId];
    if (active != null) return active.done.future;
    for (final job in _queue) {
      if (job.item.messageId == messageId) return job.done.future;
    }
    return null;
  }

  bool _worthy(ReplyAudioPrefetchItem item) =>
      item.messageId.isNotEmpty &&
      item.text.trim().isNotEmpty &&
      item.text.length <= maxChars;

  bool _enqueue(ReplyAudioPrefetchItem item, {required bool front}) {
    if (!enabled()) return false;
    final key = '${item.messageId}|${SpeechTakeStore.textKey(item.text)}';
    if (_failed.contains(key)) return false;
    if (_active.containsKey(item.messageId)) return false;
    if (_queue.any((j) => j.item.messageId == item.messageId)) return false;
    final job = _Job(item, key);
    front ? _queue.insert(0, job) : _queue.add(job);
    unawaited(_pump());
    return true;
  }

  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (_queue.isNotEmpty) {
        final job = _queue.removeAt(0);
        if (job.cancelled) continue;
        _active[job.item.messageId] = job;
        try {
          await _run(job);
        } finally {
          _active.remove(job.item.messageId);
          if (!job.done.isCompleted) job.done.complete();
        }
      }
    } finally {
      _pumping = false;
    }
  }

  Future<void> _run(_Job job) async {
    try {
      await Future<void>.delayed(delay);
      var waits = 0;
      while (!job.cancelled &&
          (!enabled() || liveSpeechBusy() || !appActive())) {
        if (++waits > maxRechecks) return; // retried when the chat opens again
        await Future<void>.delayed(recheck);
      }
      if (job.cancelled) return;
      final latest = job.item.latestText?.call() ?? job.item.text;
      if (latest.trim().isEmpty || latest.length > maxChars) return;
      final request = requestFor(
        ReplyAudioPrefetchItem(
          messageId: job.item.messageId,
          text: latest,
          chatId: job.item.chatId,
        ),
      );
      if (await savedTake(request) != null) return;
      if (job.cancelled) return;
      started++;
      await render(request, stillWanted: () => !job.cancelled);
    } on ReplyAudioDropped {
      // Listen or a newer take got there first: nothing to do.
    } catch (error) {
      _failed.add(job.key);
      DebugLogger.info(
        'reply-audio-prefetch-failed',
        scope: 'chat/take',
        data: {'error': error.toString()},
      );
    }
  }
}

class _Job {
  _Job(this.item, this.key);
  final ReplyAudioPrefetchItem item;
  final String key;
  bool cancelled = false;
  final Completer<void> done = Completer<void>();
}
