import 'dart:async';

import '../../chat/musey/musey_feed_api.dart';
import 'notification_router.dart' show notificationPreview;

/// iOS gives a backgrounded app little time, so the summary may take this
/// long and no longer; then the notification goes out with the local text.
const Duration kNotificationSummaryTimeout = Duration(milliseconds: 2500);

/// The longest local fallback body.
const int kNotificationFallbackMax = 90;

/// Chat titles that are placeholders, not a subject.
const Set<String> _defaultTitles = {'new chat', 'chat', 'untitled', 'omni'};

/// A reply cleaned of markdown, cut at its first sentence and at most
/// [max] characters at a word boundary. Empty for an empty reply.
String localNotificationFallback(
  String reply, {
  int max = kNotificationFallbackMax,
}) {
  final cleaned = notificationPreview(
    reply,
    max: 100000,
  ).replaceAll('• ', '').replaceAll(RegExp(r'\s+'), ' ').trim();
  if (cleaned.isEmpty) return '';
  var sentence = cleaned;
  for (final end in RegExp(r'[.!?](?=\s|$)').allMatches(cleaned)) {
    if (end.end >= 8) {
      sentence = cleaned.substring(0, end.end);
      break;
    }
  }
  if (sentence.length <= max) return sentence;
  final cut = sentence.lastIndexOf(' ', max - 1);
  final head = sentence.substring(0, cut > max * 0.5 ? cut : max - 1);
  return '${head.trimRight().replaceAll(RegExp(r'[,;:.\-]+$'), '')}…';
}

/// The notification title: the chat's own title when it is a real subject,
/// else the assistant's name as the chat header shows it, else empty (the
/// notification service then shows "Musey").
String chooseNotificationTitle({String? chatTitle, String? assistantName}) {
  final title = chatTitle?.trim() ?? '';
  if (title.isNotEmpty && !_defaultTitles.contains(title.toLowerCase())) {
    return title;
  }
  final name = assistantName?.trim() ?? '';
  return name;
}

/// What `POST /musey/summary` answered.
class NotificationSummary {
  const NotificationSummary({this.summary, this.fallback});
  final String? summary;
  final String? fallback;
}

String? _clean(Object? v) {
  if (v is! String) return null;
  final t = v.replaceAll(RegExp(r'\s+'), ' ').trim();
  return t.isEmpty ? null : t;
}

/// Reads an answer of `POST /musey/summary`; null for any status but 2xx
/// (a 404 from a relay without the route included) and for a body that is
/// not the expected shape.
NotificationSummary? parseNotificationSummary(int? status, Object? data) {
  if (status == null || status < 200 || status >= 300) return null;
  if (data is! Map) return null;
  return NotificationSummary(
    summary: _clean(data['summary']),
    fallback: _clean(data['fallback']),
  );
}

/// The body for a chat-completion notification: the relay's summary, else
/// its fallback, else [localNotificationFallback]. Never throws and never
/// takes longer than [timeout]; a failed or missing relay gives the local
/// text.
Future<String> notificationBody(
  MuseyFeedApi? api, {
  required String reply,
  String? ask,
  Duration timeout = kNotificationSummaryTimeout,
}) async {
  final local = localNotificationFallback(reply);
  if (api == null || reply.trim().isEmpty) return local;
  try {
    final answer = await api
        .summarize(text: reply, ask: ask, kind: 'chat')
        .timeout(timeout);
    return answer?.summary ?? answer?.fallback ?? local;
  } catch (_) {
    return local;
  }
}
