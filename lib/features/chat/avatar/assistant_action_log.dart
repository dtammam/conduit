import 'dart:convert';

import 'package:conduit/features/chat/reactions/quick_reply_reactions.dart';
import 'package:conduit/features/notifications/providers/notification_socket_listener.dart';
import 'package:conduit/shared/widgets/markdown/compiled_markdown_document.dart';
import 'package:conduit/shared/widgets/markdown/markdown_compile_service.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/persistence/account_scoped_preferences.dart';
import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

const String _logScope = 'chat/avatar-activity';

/// The most records the log keeps; the oldest are dropped first.
const int kAssistantActionLogMaxRecords = 500;

/// How long a record is kept.
const Duration kAssistantActionLogMaxAge = Duration(days: 30);

/// Arguments and results are clipped to this many characters when stored, so
/// 500 records stay small in the preferences file.
const int kAssistantActionFieldLimit = 4000;

/// Whether a tool call finished well.
enum AssistantActionStatus { succeeded, failed }

/// One tool call the app has seen, kept on this device only.
@immutable
class AssistantActionRecord {
  const AssistantActionRecord({
    required this.id,
    required this.chatId,
    required this.messageId,
    required this.toolName,
    required this.arguments,
    required this.result,
    required this.status,
    required this.startedAt,
    required this.finishedAt,
    this.durationSeconds,
  });

  /// The tool call id from the reply, or a stable hash of chat, message and
  /// position when the reply carries none.
  final String id;
  final String chatId;
  final String messageId;

  /// The raw tool name.
  final String toolName;
  final String arguments;
  final String result;
  final AssistantActionStatus status;

  /// When the app first saw the call running, else the message time.
  final DateTime startedAt;

  /// When the app saw the call done (the end of the reply's stream), else the
  /// message time.
  final DateTime finishedAt;

  /// The duration the server reported, when it reported one.
  final int? durationSeconds;

  bool get failed => status == AssistantActionStatus.failed;

  /// What identifies the call across reloads.
  String get key => '$chatId|$messageId|$id';

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'chatId': chatId,
    'messageId': messageId,
    'toolName': toolName,
    'arguments': arguments,
    'result': result,
    'status': status.name,
    'startedAt': startedAt.toUtc().toIso8601String(),
    'finishedAt': finishedAt.toUtc().toIso8601String(),
    'durationSeconds': ?durationSeconds,
  };

  /// Null when [json] is not a record this version wrote.
  static AssistantActionRecord? tryFromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final chatId = json['chatId'];
    final messageId = json['messageId'];
    final toolName = json['toolName'];
    final startedAt = DateTime.tryParse('${json['startedAt']}');
    final finishedAt = DateTime.tryParse('${json['finishedAt']}');
    if (id is! String ||
        chatId is! String ||
        messageId is! String ||
        toolName is! String ||
        startedAt == null ||
        finishedAt == null) {
      return null;
    }
    return AssistantActionRecord(
      id: id,
      chatId: chatId,
      messageId: messageId,
      toolName: toolName,
      arguments: json['arguments'] is String ? json['arguments'] as String : '',
      result: json['result'] is String ? json['result'] as String : '',
      status: json['status'] == AssistantActionStatus.failed.name
          ? AssistantActionStatus.failed
          : AssistantActionStatus.succeeded,
      startedAt: startedAt.toLocal(),
      finishedAt: finishedAt.toLocal(),
      durationSeconds: json['durationSeconds'] is int
          ? json['durationSeconds'] as int
          : null,
    );
  }

  AssistantActionRecord withStartedAt(DateTime value) => AssistantActionRecord(
    id: id,
    chatId: chatId,
    messageId: messageId,
    toolName: toolName,
    arguments: arguments,
    result: result,
    status: status,
    startedAt: value,
    finishedAt: finishedAt,
    durationSeconds: durationSeconds,
  );
}

String _clip(String value) => value.length <= kAssistantActionFieldLimit
    ? value
    : '${value.substring(0, kAssistantActionFieldLimit)}…';

/// FNV-1a, so the fallback id of a call stays the same from run to run
/// (`Object.hash` does not).
String _stableHash(String value) {
  var hash = 0x811c9dc5;
  for (final unit in value.codeUnits) {
    hash = ((hash ^ unit) * 0x01000193) & 0xFFFFFFFF;
  }
  return 'h${hash.toRadixString(16)}';
}

/// The first line of [text] that has anything in it, trimmed to [maxLength]
/// characters with an ellipsis.
String firstLinePreview(String text, {int maxLength = 80}) {
  for (final line in const LineSplitter().convert(text)) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    if (trimmed.length <= maxLength) return trimmed;
    return '${trimmed.substring(0, maxLength - 1).trimRight()}…';
  }
  return '';
}

/// The one-line result of a call for the activity list and the failure line
/// in the chat. Tool results are often an array of content parts
/// (`[{"type": "text", "text": "..."}]`, or a map with a `content` list of
/// them): those preview the first part's text. A JSON object previews its
/// `message`, `error` or `status` string. Anything else previews its first
/// line as written.
String toolResultPreview(AssistantActionRecord record, {int maxLength = 80}) {
  final text = record.result.trim();
  Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException {
    // Plain text result.
    return firstLinePreview(text, maxLength: maxLength);
  }
  final preview = _decodedPreview(decoded, maxLength);
  return preview.isNotEmpty
      ? preview
      : firstLinePreview(text, maxLength: maxLength);
}

String _decodedPreview(Object? decoded, int maxLength) {
  if (decoded is String) {
    return firstLinePreview(decoded, maxLength: maxLength);
  }
  if (decoded is List) {
    for (final part in decoded) {
      if (part is Map) {
        final field = part['text'];
        if (field is String && field.trim().isNotEmpty) {
          return firstLinePreview(field, maxLength: maxLength);
        }
      } else if (part is String && part.trim().isNotEmpty) {
        return firstLinePreview(part, maxLength: maxLength);
      }
    }
    return '';
  }
  if (decoded is Map) {
    final content = decoded['content'];
    if (content is List) {
      final fromParts = _decodedPreview(content, maxLength);
      if (fromParts.isNotEmpty) return fromParts;
    }
    for (final key in const ['message', 'error', 'status']) {
      final field = decoded[key];
      if (field is String && field.trim().isNotEmpty) {
        return firstLinePreview(field, maxLength: maxLength);
      }
    }
  }
  return '';
}

/// The tool calls in one assistant reply, in order. Reads the reply with the
/// markdown compiler, so attributes decode the way the transcript decodes
/// them and a call counts as failed by the same rule as the status rows.
///
/// This parses the whole reply, so call it once per settled reply, never per
/// streamed chunk. Calls still running are left out.
List<AssistantActionRecord> extractToolCallRecords({
  required String chatId,
  required String messageId,
  required String content,
  required DateTime messageTime,
  DateTime? finishedAt,
  Map<String, DateTime> startedAtByCall = const <String, DateTime>{},
}) {
  if (!content.contains('tool_calls')) return const [];
  final document = compilePreparedMarkdownSync(
    prepareMarkdownContent(content, streaming: false),
  );
  final records = <AssistantActionRecord>[];
  var index = 0;
  for (final node in document.nodes) {
    if (node is! CompiledMarkdownElement || node.tag != 'details') continue;
    final data = node.detailsData;
    final call = data?.toolCallData;
    if (data == null || call == null || data.type != 'tool_calls') continue;
    final position = index++;
    if (data.isPending) continue;
    final rawId = node.attributes['id']?.trim() ?? '';
    final id = rawId.isEmpty
        ? _stableHash('$chatId|$messageId|$position')
        : rawId;
    final end = finishedAt ?? messageTime;
    var start = startedAtByCall['$messageId|$id'] ?? messageTime;
    if (start.isAfter(end)) start = end;
    records.add(
      AssistantActionRecord(
        id: id,
        chatId: chatId,
        messageId: messageId,
        toolName: data.name,
        arguments: _clip(call.argumentsText),
        result: _clip(call.resultText),
        status: data.toolCallFailed
            ? AssistantActionStatus.failed
            : AssistantActionStatus.succeeded,
        startedAt: start,
        finishedAt: end,
        durationSeconds: data.hasDuration ? data.durationSeconds : null,
      ),
    );
  }
  return records;
}

/// [records] without anything older than [kAssistantActionLogMaxAge] or past
/// [kAssistantActionLogMaxRecords], newest first. Ties keep the order given.
List<AssistantActionRecord> capAssistantActionRecords(
  Iterable<AssistantActionRecord> records, {
  required DateTime now,
}) {
  final oldest = now.subtract(kAssistantActionLogMaxAge);
  final kept = <(int, AssistantActionRecord)>[];
  var position = 0;
  for (final record in records) {
    if (record.finishedAt.isBefore(oldest)) continue;
    kept.add((position++, record));
  }
  kept.sort((a, b) {
    final byTime = b.$2.finishedAt.compareTo(a.$2.finishedAt);
    return byTime != 0 ? byTime : a.$1.compareTo(b.$1);
  });
  return List<AssistantActionRecord>.unmodifiable(
    kept.take(kAssistantActionLogMaxRecords).map((entry) => entry.$2),
  );
}

/// The ids of the assistant messages that make up the turn ending at
/// [messageId]: that message and the assistant messages before it, back to
/// the previous user message that is not a quick-reply turn. A read-back, a
/// quick reply and a receipt therefore count as one turn.
Set<String> turnMessageIds(List<ChatMessage> messages, String messageId) {
  final index = messages.indexWhere((message) => message.id == messageId);
  if (index < 0) return {messageId};
  final ids = <String>{messageId};
  for (var i = index - 1; i >= 0; i--) {
    final message = messages[i];
    if (message.role == 'user') {
      if (isQuickReplyTurn(messages, i)) continue;
      break;
    }
    if (message.role == 'assistant') ids.add(message.id);
  }
  return ids;
}

/// The recorded tool calls and when the user last looked at the failures.
@immutable
class AssistantActionLogState {
  const AssistantActionLogState({
    this.records = const <AssistantActionRecord>[],
    required this.failuresSeenAt,
  });

  /// Newest first.
  final List<AssistantActionRecord> records;

  /// Failures recorded after this have not been seen.
  final DateTime failuresSeenAt;

  int get unseenFailures => records
      .where(
        (record) => record.failed && record.finishedAt.isAfter(failuresSeenAt),
      )
      .length;

  /// The records of [chatId] whose message is in [messageIds].
  List<AssistantActionRecord> forMessages(
    String chatId,
    Set<String> messageIds,
  ) => records
      .where(
        (record) =>
            record.chatId == chatId && messageIds.contains(record.messageId),
      )
      .toList(growable: false);
}

final assistantActionLogProvider =
    NotifierProvider<AssistantActionLog, AssistantActionLogState>(
      AssistantActionLog.new,
    );

/// The action log: loaded from the account's preferences, changed by
/// [recordAll], [clear] and [markFailuresSeen], and written back each time.
class AssistantActionLog extends Notifier<AssistantActionLogState> {
  /// When each call was first seen running, by `messageId|callId`. Held for
  /// this session only.
  final Map<String, DateTime> _startedAt = <String, DateTime>{};

  /// The content length last scanned for each message, by `chatId|messageId`,
  /// so a reload or a rebuild never parses the same reply twice.
  final Map<String, int> _scanned = <String, int>{};

  @override
  AssistantActionLogState build() {
    // A different account has a different log.
    ref.watch(
      activeServerProvider.select((server) => server.asData?.value?.id),
    );
    _scanned.clear();
    final now = DateTime.now();
    if (!PreferencesStore.isReady) {
      return AssistantActionLogState(failuresSeenAt: now);
    }
    final records = <AssistantActionRecord>[];
    final raw = PreferencesStore.getString(
      scopedPreferenceReadKey(PreferenceKeys.assistantActionLog),
    );
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final entry in decoded) {
            final record = AssistantActionRecord.tryFromJson(entry);
            if (record != null) records.add(record);
          }
        }
      } catch (error, stackTrace) {
        DebugLogger.error(
          'log-read-failed',
          scope: _logScope,
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
    final seenRaw = PreferencesStore.getString(
      scopedPreferenceReadKey(PreferenceKeys.assistantActionLogSeen),
    );
    final seen = seenRaw == null ? null : DateTime.tryParse(seenRaw)?.toLocal();
    if (seen == null) {
      // First run: history already on screen is not news.
      Future<void>.microtask(_persistSeen);
    }
    return AssistantActionLogState(
      records: capAssistantActionRecords(records, now: now),
      failuresSeenAt: seen ?? now,
    );
  }

  /// Remembers that the call [callId] of [messageId] is running now.
  void noteRunning(String messageId, String callId) {
    _startedAt.putIfAbsent('$messageId|$callId', DateTime.now);
  }

  /// Records the tool calls of the settled assistant messages in [messages]
  /// that have not been read yet (or whose text changed). With [finishedAt]
  /// the calls end then; otherwise at their message's time.
  Future<void> scanMessages(
    String chatId,
    List<ChatMessage> messages, {
    DateTime? finishedAt,
  }) async {
    final found = <AssistantActionRecord>[];
    for (final message in messages) {
      if (message.role != 'assistant' || message.isStreaming) continue;
      final memoKey = '$chatId|${message.id}';
      if (_scanned[memoKey] == message.content.length) continue;
      _scanned[memoKey] = message.content.length;
      try {
        found.addAll(
          extractToolCallRecords(
            chatId: chatId,
            messageId: message.id,
            content: message.content,
            messageTime: message.timestamp,
            finishedAt: finishedAt,
            startedAtByCall: _startedAt,
          ),
        );
      } catch (error, stackTrace) {
        DebugLogger.error(
          'scan-failed',
          scope: _logScope,
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
    await recordAll(found);
  }

  /// Adds the records the log does not have yet; one it has with a different
  /// result is replaced, keeping its first start time.
  Future<void> recordAll(List<AssistantActionRecord> incoming) async {
    if (incoming.isEmpty) return;
    final byKey = <String, AssistantActionRecord>{
      for (final record in state.records) record.key: record,
    };
    var changed = false;
    // Older first in, so a tie keeps the later call ahead of the earlier one.
    final fresh = <AssistantActionRecord>[];
    for (final record in incoming) {
      final existing = byKey[record.key];
      if (existing == null) {
        fresh.add(record);
        byKey[record.key] = record;
        changed = true;
      } else if (existing.result != record.result ||
          existing.status != record.status) {
        byKey[record.key] = record.withStartedAt(existing.startedAt);
        changed = true;
      }
    }
    if (!changed) return;
    final replaced = state.records.map((r) => byKey[r.key] ?? r);
    final merged = capAssistantActionRecords([
      ...fresh.reversed,
      ...replaced,
    ], now: DateTime.now());
    state = AssistantActionLogState(
      records: merged,
      failuresSeenAt: state.failuresSeenAt,
    );
    DebugLogger.log(
      'recorded',
      scope: _logScope,
      data: {'added': fresh.length, 'total': merged.length},
    );
    await _persist();
  }

  /// The user has looked at the failures up to now.
  Future<void> markFailuresSeen() async {
    state = AssistantActionLogState(
      records: state.records,
      failuresSeenAt: DateTime.now(),
    );
    await _persistSeen();
  }

  /// Empties the log.
  Future<void> clear() async {
    _scanned.clear();
    state = AssistantActionLogState(failuresSeenAt: DateTime.now());
    await _persist();
    await _persistSeen();
  }

  Future<void> _persist() async {
    if (!PreferencesStore.isReady) return;
    try {
      await PreferencesStore.put(
        scopedPreferenceWriteKey(PreferenceKeys.assistantActionLog),
        jsonEncode(state.records.map((r) => r.toJson()).toList()),
      );
    } catch (error, stackTrace) {
      DebugLogger.error(
        'log-write-failed',
        scope: _logScope,
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _persistSeen() async {
    if (!PreferencesStore.isReady) return;
    try {
      await PreferencesStore.put(
        scopedPreferenceWriteKey(PreferenceKeys.assistantActionLogSeen),
        state.failuresSeenAt.toUtc().toIso8601String(),
      );
    } catch (error, stackTrace) {
      DebugLogger.error(
        'seen-write-failed',
        scope: _logScope,
        error: error,
        stackTrace: stackTrace,
      );
    }
  }
}

/// Which tab of the avatar's sheet to open on.
enum AssistantSheetTab { activity, approvals, routines, appearance }

/// A request, from outside the app bar, to open the avatar's sheet: the
/// failure line under a reply and the reply's "View actions" menu item send
/// one. The avatar strip listens and opens the sheet.
@immutable
class AssistantSheetRequest {
  const AssistantSheetRequest({
    required this.tab,
    this.messageIds,
    required this.nonce,
  });

  final AssistantSheetTab tab;

  /// When set, the activity list shows only calls of these messages.
  final Set<String>? messageIds;

  /// Makes two requests for the same thing different.
  final int nonce;
}

final assistantSheetRequestProvider =
    NotifierProvider<AssistantSheetRequestNotifier, AssistantSheetRequest?>(
      AssistantSheetRequestNotifier.new,
    );

class AssistantSheetRequestNotifier extends Notifier<AssistantSheetRequest?> {
  int _nonce = 0;

  @override
  AssistantSheetRequest? build() => null;

  void open({
    AssistantSheetTab tab = AssistantSheetTab.activity,
    Set<String>? messageIds,
  }) {
    state = AssistantSheetRequest(
      tab: tab,
      messageIds: messageIds,
      nonce: ++_nonce,
    );
  }

  /// The strip took the request.
  void consume() => state = null;
}

/// Opens a chat by id from the avatar's sheet, the way a notification tap
/// does.
final assistantOpenChatProvider = Provider<Future<void> Function(String)>(
  (ref) =>
      (chatId) => openChatById(ref, chatId),
);
