/// Replying to one specific message.
///
/// Long-pressing a message and choosing Reply sets a [ReplyTarget]. The next
/// message sent in that chat starts with a markdown quote of the target
/// ([composeReplyText]) and, for that one request, names the target's id to
/// the relay with [replyToMarker] on its own line at the end of the system
/// prompt, the way `routine_reply_marker.dart` names a routine.
library;

import 'package:conduit_core/database/chat_database_repository.dart'
    show ChatStorageIdentity;
import 'package:riverpod/riverpod.dart';

String _rawChatId(String id) => ChatStorageIdentity.parse(id).rawId;

final RegExp _messageIdPattern = RegExp(r'^[A-Za-z0-9-]{1,64}$');

/// How much of the quoted message goes into the quote.
const int replyQuoteMaxChars = 200;

/// The system line for the message [id], or null when it is not a valid
/// message id (so nothing reaches the prompt).
String? replyToMarker(String? id) {
  if (id == null || !_messageIdPattern.hasMatch(id)) return null;
  return '[reply-to:$id]';
}

/// The first [replyQuoteMaxChars] characters of [content] as a markdown
/// quote: every line prefixed by `> `, and an ellipsis at the end when the
/// text was cut. Empty when [content] has no text.
String quoteForReply(String content) {
  final text = content.replaceAll('\r\n', '\n').trim();
  if (text.isEmpty) return '';
  final runes = text.runes.toList(growable: false);
  final cut = runes.length > replyQuoteMaxChars;
  final shown = String.fromCharCodes(
    cut ? runes.sublist(0, replyQuoteMaxChars) : runes,
  );
  final lines = (cut ? '${shown.trimRight()}…' : shown).split('\n');
  return lines.map((line) => '> $line').join('\n');
}

/// The text that is stored and shown for a reply: the quote, a blank line,
/// then what the person typed. [text] alone when there is nothing to quote.
String composeReplyText(String quotedContent, String text) {
  final quote = quoteForReply(quotedContent);
  return quote.isEmpty ? text : '$quote\n\n$text';
}

/// The first non-empty line of [content], for the bar above the composer.
String replyPreview(String content) {
  for (final line in content.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isNotEmpty) return trimmed;
  }
  return '';
}

/// A message text split into its leading markdown quote and the rest.
typedef LeadingQuote = ({String quote, String rest});

/// The leading `> ` lines of [content] with the quote marks removed, and the
/// text after them (past the blank line that follows the quote). Null when
/// [content] does not start with a quote.
LeadingQuote? splitLeadingQuote(String content) {
  if (!content.startsWith('> ') && !content.startsWith('>\n')) return null;
  final lines = content.replaceAll('\r\n', '\n').split('\n');
  final quoted = <String>[];
  var i = 0;
  while (i < lines.length && lines[i].startsWith('>')) {
    final line = lines[i].substring(1);
    quoted.add(line.startsWith(' ') ? line.substring(1) : line);
    i++;
  }
  while (i < lines.length && lines[i].trim().isEmpty) {
    i++;
  }
  return (quote: quoted.join('\n'), rest: lines.sublist(i).join('\n'));
}

/// The message the next send replies to.
class ReplyTarget {
  const ReplyTarget({required this.messageId, required this.content});

  final String messageId;
  final String content;
}

final replyTargetProvider = NotifierProvider<ReplyTargetNotifier, ReplyTarget?>(
  ReplyTargetNotifier.new,
);

/// Holds the message being replied to while the composer shows the quote bar.
class ReplyTargetNotifier extends Notifier<ReplyTarget?> {
  @override
  ReplyTarget? build() => null;

  void set(String messageId, String content) {
    if (messageId.isEmpty || quoteForReply(content).isEmpty) return;
    state = ReplyTarget(messageId: messageId, content: content);
  }

  void clear() => state = null;
}

/// The reply a send is about to make, for the request builder.
class PendingReplyTo {
  const PendingReplyTo({required this.chatId, required this.messageId});

  final String chatId;
  final String messageId;
}

final pendingReplyToProvider =
    NotifierProvider<PendingReplyToNotifier, PendingReplyTo?>(
      PendingReplyToNotifier.new,
    );

/// Set by a send that replies, used up by that send's request.
class PendingReplyToNotifier extends Notifier<PendingReplyTo?> {
  @override
  PendingReplyTo? build() => null;

  /// Remembers that the next request in [chatId] replies to [messageId]. An
  /// invalid id clears whatever was pending.
  void arm(String chatId, String messageId) {
    if (replyToMarker(messageId) == null || chatId.isEmpty) {
      state = null;
      return;
    }
    state = PendingReplyTo(chatId: _rawChatId(chatId), messageId: messageId);
  }

  /// The message id for a request in [chatId], and forgets it. Null when
  /// nothing is pending or it was for another chat.
  String? take(String chatId) {
    final pending = state;
    if (pending == null) return null;
    state = null;
    return pending.chatId == _rawChatId(chatId) ? pending.messageId : null;
  }

  void clear() => state = null;
}
