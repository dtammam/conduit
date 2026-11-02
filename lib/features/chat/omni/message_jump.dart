import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// How long a jumped-to message keeps its highlight.
const Duration kMessageJumpHighlight = Duration(milliseconds: 4500);

/// How long a jump waits for its chat and message to load before giving up
/// (the chat is then simply left open at the bottom).
const Duration kMessageJumpPatience = Duration(seconds: 20);

/// A notification tap that points at one message in one chat.
@immutable
class MessageJumpRequest {
  const MessageJumpRequest({
    required this.chatId,
    required this.messageId,
    required this.requestedAt,
  });

  final String chatId;
  final String messageId;
  final DateTime requestedAt;

  bool expired(DateTime now) =>
      now.difference(requestedAt) > kMessageJumpPatience;
}

/// The message a push points at, from the event the native side hands over:
/// its `message_id`, or null for an older push that carries none (those keep
/// opening the chat at the bottom).
String? messageIdFromPushEvent(Map<String, Object?> event) {
  final id = event['message_id'];
  if (id is String && id.trim().isNotEmpty) return id.trim();
  return null;
}

/// How many of the newest messages the timeline must show for [messageId] to
/// be in it, given the complete transcript [ids] (oldest first) and the
/// [loadedCount] now shown. 0 when it is already shown; null when the
/// transcript does not hold it.
int? transcriptCountToReveal({
  required List<String> ids,
  required String messageId,
  required int loadedCount,
}) {
  final index = ids.lastIndexOf(messageId);
  if (index < 0) return null;
  final needed = ids.length - index;
  return needed <= loadedCount ? 0 : needed;
}

final messageJumpProvider =
    NotifierProvider<MessageJumpController, MessageJumpRequest?>(
      MessageJumpController.new,
    );

class MessageJumpController extends Notifier<MessageJumpRequest?> {
  @override
  MessageJumpRequest? build() => null;

  void request(String chatId, String messageId, {DateTime? now}) {
    state = MessageJumpRequest(
      chatId: chatId,
      messageId: messageId,
      requestedAt: now ?? DateTime.now(),
    );
  }

  void clear() => state = null;
}

/// The message to highlight for a moment after a jump.
final highlightedMessageProvider =
    NotifierProvider<HighlightedMessageController, String?>(
      HighlightedMessageController.new,
    );

class HighlightedMessageController extends Notifier<String?> {
  Timer? _timer;

  @override
  String? build() {
    ref.onDispose(() => _timer?.cancel());
    return null;
  }

  void flash(String messageId, {Duration duration = kMessageJumpHighlight}) {
    _timer?.cancel();
    state = messageId;
    _timer = Timer(duration, () {
      if (ref.mounted && state == messageId) state = null;
    });
  }
}
