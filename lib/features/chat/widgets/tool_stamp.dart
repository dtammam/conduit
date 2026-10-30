import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../shared/theme/theme_extensions.dart';
import '../avatar/assistant_action_log.dart';

/// Calls that are plumbing, not actions worth proving.
const Set<String> kToolStampHiddenNames = {
  'ask_user',
  'get_current_timestamp',
  'calculate_timestamp',
};

/// One entry of the tool stamp: a friendly name, whether it worked, and how
/// many identical calls it stands for.
class ToolStampEntry {
  const ToolStampEntry({
    required this.name,
    required this.failed,
    this.count = 1,
  });

  final String name;
  final bool failed;
  final int count;

  String get label =>
      '$name ${failed ? '✗' : '✓'}${count > 1 ? ' ×$count' : ''}';

  @override
  bool operator ==(Object other) =>
      other is ToolStampEntry &&
      other.name == name &&
      other.failed == failed &&
      other.count == count;

  @override
  int get hashCode => Object.hash(name, failed, count);
}

/// "calendar-mcp_event_create" reads "event create"; an MCP server prefix
/// (a segment with a hyphen before the first underscore) and a leading
/// "actual_" are dropped, underscores become spaces.
String toolStampName(String raw) {
  var name = raw.trim();
  final underscore = name.indexOf('_');
  if (underscore > 0 &&
      underscore < name.length - 1 &&
      name.substring(0, underscore).contains('-')) {
    name = name.substring(underscore + 1);
  }
  if (name.startsWith('actual_') && name.length > 'actual_'.length) {
    name = name.substring('actual_'.length);
  }
  return name.replaceAll('_', ' ').trim();
}

bool _resultSaysFailed(String result) {
  final text = result.trim();
  if (!text.startsWith('{')) return false;
  try {
    final decoded = jsonDecode(text);
    if (decoded is Map) {
      return decoded['isError'] == true || decoded['success'] == false;
    }
  } catch (_) {}
  return false;
}

/// The stamp entries for a list of tool call records, in order of first use.
/// Identical calls (same name and outcome) merge into one entry with a count.
List<ToolStampEntry> buildToolStamp(Iterable<AssistantActionRecord> records) {
  final order = <String>[];
  final entries = <String, ToolStampEntry>{};
  for (final record in records) {
    final raw = record.toolName.trim();
    if (raw.isEmpty) continue;
    final hidden = {raw, toolStampName(raw).replaceAll(' ', '_')};
    if (hidden.any(kToolStampHiddenNames.contains)) continue;
    final name = toolStampName(raw);
    if (name.isEmpty) continue;
    final failed = record.failed || _resultSaysFailed(record.result);
    final key = '$name|$failed';
    final existing = entries[key];
    if (existing == null) {
      order.add(key);
      entries[key] = ToolStampEntry(name: name, failed: failed);
    } else {
      entries[key] = ToolStampEntry(
        name: name,
        failed: failed,
        count: existing.count + 1,
      );
    }
  }
  return [for (final key in order) entries[key]!];
}

/// The stamp for a settled reply, read from its stored content (the
/// `tool_calls` blocks), never from what the model wrote.
List<ToolStampEntry> toolStampFromContent({
  required String messageId,
  required String content,
}) {
  if (!content.contains('tool_calls')) return const [];
  return buildToolStamp(
    extractToolCallRecords(
      chatId: '',
      messageId: messageId,
      content: content,
      messageTime: DateTime.fromMillisecondsSinceEpoch(0),
    ),
  );
}

String _outputResultText(Object? output) {
  if (output is String) return output;
  if (output is List) {
    return output
        .map((part) => part is Map ? (part['text']?.toString() ?? '') : '')
        .where((text) => text.isNotEmpty)
        .join('\n');
  }
  return '';
}

/// The stamp from a message's stored `output` array: each completed
/// `function_call` paired by `call_id` with its `function_call_output`. A call
/// with no output yet, or a status other than completed, is still running and
/// left out. Returns an empty list when [output] has no such calls.
List<ToolStampEntry> toolStampFromOutput(List<Map<String, dynamic>>? output) {
  if (output == null || output.isEmpty) return const [];
  final results = <String, String>{};
  for (final item in output) {
    if (item['type'] == 'function_call_output') {
      final id = (item['call_id'] ?? item['id'])?.toString();
      if (id != null && id.isNotEmpty) {
        results[id] = _outputResultText(item['output']);
      }
    }
  }
  final records = <AssistantActionRecord>[];
  final epoch = DateTime.fromMillisecondsSinceEpoch(0);
  for (final item in output) {
    if (item['type'] != 'function_call') continue;
    final id = (item['call_id'] ?? item['id'])?.toString() ?? '';
    final status = item['status']?.toString();
    if (!results.containsKey(id) || (status != null && status != 'completed')) {
      continue;
    }
    final result = results[id]!;
    final text = result.trim().toLowerCase();
    final failed =
        text.startsWith('error') ||
        text.startsWith('exception:') ||
        text.startsWith('traceback') ||
        _resultSaysFailed(result) ||
        _jsonErrorField(result);
    records.add(
      AssistantActionRecord(
        id: id,
        chatId: '',
        messageId: '',
        toolName: item['name']?.toString() ?? '',
        arguments: '',
        result: result,
        status: failed
            ? AssistantActionStatus.failed
            : AssistantActionStatus.succeeded,
        startedAt: epoch,
        finishedAt: epoch,
      ),
    );
  }
  return buildToolStamp(records);
}

bool _jsonErrorField(String result) {
  final text = result.trim();
  if (!text.startsWith('{')) return false;
  try {
    final decoded = jsonDecode(text);
    if (decoded is Map) {
      final error = decoded['error'];
      return error is String
          ? error.trim().isNotEmpty
          : error is Map || error is List;
    }
  } catch (_) {}
  return false;
}

/// A small muted row under a reply: a wrench and the calls that really ran.
class ToolStamp extends StatelessWidget {
  const ToolStamp({super.key, required this.entries});

  final List<ToolStampEntry> entries;

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) return const SizedBox.shrink();
    final theme = context.conduitTheme;
    final color = theme.textSecondary.withValues(alpha: 0.75);
    return Semantics(
      label: 'Tools used: ${entries.map((e) => e.label).join(', ')}',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Icon(Icons.build_outlined, size: 13, color: color),
            ),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                entries.map((e) => e.label).join(' · '),
                key: const ValueKey<String>('tool-stamp-text'),
                style: TextStyle(fontSize: 12, height: 1.25, color: color),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
