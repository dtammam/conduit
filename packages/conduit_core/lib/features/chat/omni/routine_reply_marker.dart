/// Tells the relay which routine a reply answers.
///
/// A routine's notification carries the routine's id (its slug). When the
/// person replies from the notification, or opens it and types the next
/// message, that one request carries [routineReplyMarker] on its own line at
/// the end of the system prompt, the way `omni_session.dart` adds its session
/// line. The relay strips the line before the model sees it and remembers the
/// session, so later turns do not repeat it.
library;

import 'package:conduit_core/database/chat_database_repository.dart'
    show ChatStorageIdentity;
import 'package:riverpod/riverpod.dart';

String _rawChatId(String id) => ChatStorageIdentity.parse(id).rawId;

final RegExp _slugPattern = RegExp(r'^[a-z0-9][a-z0-9-]{0,47}$');

/// How long an opened notification may wait for the next message.
const Duration routineReplyWindow = Duration(minutes: 30);

/// The system line for [slug], or null when it is not a valid routine id.
String? routineReplyMarker(String? slug) {
  if (slug == null || !_slugPattern.hasMatch(slug)) return null;
  return '[routine-reply:$slug]';
}

/// The routine a chat's next message answers.
class PendingRoutineReply {
  const PendingRoutineReply({
    required this.chatId,
    required this.slug,
    required this.armedAt,
  });

  final String chatId;
  final String slug;
  final DateTime armedAt;
}

final routineReplyMarkerProvider =
    NotifierProvider<RoutineReplyMarkerNotifier, PendingRoutineReply?>(
      RoutineReplyMarkerNotifier.new,
    );

/// Holds one pending routine reply: set when a notification is opened or
/// replied to, used up by the next message sent in that chat.
class RoutineReplyMarkerNotifier extends Notifier<PendingRoutineReply?> {
  @override
  PendingRoutineReply? build() => null;

  /// Remembers that the next message in [chatId] answers [slug]. An invalid
  /// slug clears whatever was pending.
  void arm(String chatId, String? slug, {DateTime? now}) {
    if (routineReplyMarker(slug) == null || chatId.isEmpty) {
      state = null;
      return;
    }
    state = PendingRoutineReply(
      chatId: _rawChatId(chatId),
      slug: slug!,
      armedAt: now ?? DateTime.now(),
    );
  }

  /// The slug for a message about to be sent in [chatId], and forgets it.
  /// Null when nothing is pending, it is for another chat (which also drops
  /// it) or it is older than [routineReplyWindow].
  String? take(String chatId, {DateTime? now}) {
    final pending = state;
    if (pending == null) return null;
    state = null;
    if (pending.chatId != _rawChatId(chatId)) return null;
    final age = (now ?? DateTime.now()).difference(pending.armedAt);
    return age > routineReplyWindow ? null : pending.slug;
  }

  /// Drops the pending reply unless it belongs to [chatId] (the chat was
  /// switched).
  void keepOnlyFor(String? chatId) {
    final pending = state;
    if (pending != null &&
        (chatId == null || pending.chatId != _rawChatId(chatId))) {
      state = null;
    }
  }
}
