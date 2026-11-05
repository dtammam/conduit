import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../shared/theme/theme_extensions.dart';
import '../avatar/assistant_action_log.dart';
import 'web_sources.dart';

/// Calls that are plumbing, not actions worth proving.
const Set<String> kToolStampHiddenNames = {
  'ask_user',
  'get_current_timestamp',
  'calculate_timestamp',
  'view_skill',
  'read_skill_file',
  'grep_skill_files',
  'update_skill_files',
  'create_skill',
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

/// [records] without plumbing calls (ask_user, timestamps, skill upkeep).
List<AssistantActionRecord> visibleToolRecords(
  Iterable<AssistantActionRecord> records,
) {
  return [
    for (final record in records)
      if (record.toolName.trim().isNotEmpty &&
          !{
            record.toolName.trim(),
            toolStampName(record.toolName).replaceAll(' ', '_'),
          }.any(kToolStampHiddenNames.contains))
        record,
  ];
}

/// The stamp entries for a list of tool call records, in order of first use.
/// Identical calls (same name and outcome) merge into one entry with a count.
List<ToolStampEntry> buildToolStamp(Iterable<AssistantActionRecord> records) {
  records = visibleToolRecords(records);
  final order = <String>[];
  final entries = <String, ToolStampEntry>{};
  for (final record in records) {
    final raw = record.toolName.trim();
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
}) => buildToolStamp(
  toolRecordsFromContent(messageId: messageId, content: content),
);

/// The settled tool calls in a reply's `tool_calls` details blocks.
List<AssistantActionRecord> toolRecordsFromContent({
  required String messageId,
  required String content,
}) {
  if (!content.contains('tool_calls')) return const [];
  return extractToolCallRecords(
    chatId: '',
    messageId: messageId,
    content: content,
    messageTime: DateTime.fromMillisecondsSinceEpoch(0),
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
List<ToolStampEntry> toolStampFromOutput(List<Map<String, dynamic>>? output) =>
    buildToolStamp(toolRecordsFromOutput(output));

/// The settled tool calls in a stored `output` array, as records.
List<AssistantActionRecord> toolRecordsFromOutput(
  List<Map<String, dynamic>>? output,
) {
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
        arguments: _outputArguments(item['arguments']),
        result: result,
        status: failed
            ? AssistantActionStatus.failed
            : AssistantActionStatus.succeeded,
        startedAt: epoch,
        finishedAt: epoch,
      ),
    );
  }
  return records;
}

String _outputArguments(Object? raw) {
  if (raw is String) return raw;
  if (raw is Map) {
    try {
      return jsonEncode(raw);
    } catch (_) {}
  }
  return '';
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

/// The relay's rule for a call that changes something.
final RegExp kToolWriteRule = RegExp(
  r'(^|_)(transactions_(create|update|delete)|event_(create|update|delete)|'
  r'create_note|update_note|manage_tags|schedule_(create|update|delete))$',
);

enum ToolSummaryKind { read, write, image, failedWrite, failedRead }

/// One phrase of the grouped stamp.
class ToolSummarySegment {
  const ToolSummarySegment(this.kind, this.text);

  final ToolSummaryKind kind;
  final String text;

  @override
  bool operator ==(Object other) =>
      other is ToolSummarySegment && other.kind == kind && other.text == text;

  @override
  int get hashCode => Object.hash(kind, text);

  @override
  String toString() => '$kind:$text';
}

/// The system a tool belongs to: budget, calendar, notes, routines, web,
/// weather, image, else its cleaned name.
String toolSystem(String raw) {
  final name = raw.trim();
  if (name.startsWith('actual-mcp_')) return 'budget';
  if (name.startsWith('calendar-mcp_')) return 'calendar';
  if (name.startsWith('notes-mcp_')) return 'notes';
  if (name.startsWith('schedule-mcp_')) return 'routines';
  switch (name) {
    case 'search_web':
    case 'fetch_url':
      return 'web';
    case 'weather_forecast':
      return 'weather';
    case 'generate_image':
    case 'edit_image':
      return 'image';
  }
  return toolStampName(name);
}

bool _isImageTool(String raw) {
  final name = raw.trim();
  return name == 'generate_image' || name == 'edit_image';
}

/// Groups calls by what they did: reads per system, writes per system, the
/// image, then failures. A failure replaces the success of the same system
/// and action. Order: reads, writes, image, failed writes, failed reads.
List<ToolSummarySegment> buildToolSummary(
  Iterable<AssistantActionRecord> records,
) {
  final reads = <String>[];
  final failedReads = <String>[];
  final writes = <String, int>{};
  final failedWrites = <String>[];
  var image = false;
  final seen = <String>{};

  void addOnce(List<String> list, String value) {
    if (!list.contains(value)) list.add(value);
  }

  final visible = visibleToolRecords(records).toList();
  for (final record in visible) {
    final raw = record.toolName.trim();
    final system = toolSystem(raw);
    if (system.isEmpty) continue;
    if (_isImageTool(raw)) {
      if (record.failed) {
        addOnce(failedWrites, system);
      } else {
        image = true;
      }
      seen.add(system);
      continue;
    }
    final isWrite = kToolWriteRule.hasMatch(raw);
    if (record.failed) {
      addOnce(isWrite ? failedWrites : failedReads, system);
    } else if (isWrite) {
      writes[system] = (writes[system] ?? 0) + 1;
    } else {
      addOnce(reads, system);
    }
  }
  // A failure replaces the success of the same system and action.
  reads.removeWhere(failedReads.contains);
  writes.removeWhere((system, _) => failedWrites.contains(system));
  if (image && failedWrites.contains('image')) image = false;

  return [
    if (reads.isNotEmpty)
      ToolSummarySegment(ToolSummaryKind.read, 'Checked ${reads.join(', ')}'),
    for (final entry in writes.entries)
      ToolSummarySegment(
        ToolSummaryKind.write,
        'Saved to ${entry.key}${entry.value > 1 ? ' ×${entry.value}' : ''}',
      ),
    if (image) const ToolSummarySegment(ToolSummaryKind.image, 'Made an image'),
    for (final system in failedWrites)
      ToolSummarySegment(
        ToolSummaryKind.failedWrite,
        system == 'image'
            ? "Couldn't make an image"
            : "Couldn't save to $system",
      ),
    for (final system in failedReads)
      ToolSummarySegment(ToolSummaryKind.failedRead, "Couldn't check $system"),
  ];
}

/// http and https URLs with a host only; anything else is not shown.
String? _webUrl(Object? raw) {
  if (raw is! String) return null;
  final text = raw.trim();
  final uri = Uri.tryParse(text);
  if (uri == null || !uri.hasAuthority || uri.host.isEmpty) return null;
  if (uri.scheme != 'http' && uri.scheme != 'https') return null;
  return uri.removeFragment().toString();
}

final RegExp _titleLinkPair = RegExp(
  r'"title"\s*:\s*"((?:[^"\\]|\\.)*)"[^{}]*?"(?:link|url)"\s*:\s*"((?:[^"\\]|\\.)*)"',
);
final RegExp _linkOnly = RegExp(r'"(?:link|url)"\s*:\s*"((?:[^"\\]|\\.)*)"');

String _unescapeJson(String body) {
  try {
    final v = jsonDecode('"$body"');
    return v is String ? v : body;
  } catch (_) {
    return body;
  }
}

void _collectSources(Object? node, List<WebSource> out, int depth) {
  if (depth > 4) return;
  if (node is List) {
    for (final item in node) {
      _collectSources(item, out, depth + 1);
    }
  } else if (node is Map) {
    final url = _webUrl(node['link'] ?? node['url'] ?? node['source']);
    if (url != null) {
      final snippet = (node['snippet'] ?? node['description'] ?? '')
          .toString()
          .trim();
      out.add(
        WebSource(
          url: url,
          title: (node['title'] ?? '').toString(),
          snippet: snippet.isEmpty ? null : snippet,
        ),
      );
    }
    final text = node['text'];
    if (text is String) _parseSourceText(text, out, depth + 1);
    for (final key in const ['results', 'data', 'items']) {
      if (node[key] is List) _collectSources(node[key], out, depth + 1);
    }
  }
}

void _parseSourceText(String text, List<WebSource> out, int depth) {
  final body = text.trim();
  if (body.isEmpty) return;
  if (body.startsWith('[') || body.startsWith('{')) {
    try {
      _collectSources(jsonDecode(body), out, depth);
      return;
    } catch (_) {
      // Clipped or not JSON: read the pairs that are whole.
    }
  }
  final pairs = _titleLinkPair.allMatches(body).toList();
  if (pairs.isNotEmpty) {
    for (final m in pairs) {
      final url = _webUrl(_unescapeJson(m.group(2)!));
      if (url != null) {
        out.add(WebSource(url: url, title: _unescapeJson(m.group(1)!)));
      }
    }
    return;
  }
  for (final m in _linkOnly.allMatches(body)) {
    final url = _webUrl(_unescapeJson(m.group(1)!));
    if (url != null) out.add(WebSource(url: url, title: ''));
  }
}

String? _searchQuery(String arguments) {
  try {
    final args = jsonDecode(arguments);
    if (args is! Map) return null;
    for (final key in const ['query', 'q', 'search_query']) {
      final v = args[key];
      if (v is String && v.trim().isNotEmpty) return v.trim();
    }
    final many = args['queries'];
    if (many is List && many.isNotEmpty && many.first is String) {
      return (many.first as String).trim();
    }
  } catch (_) {}
  return null;
}

/// The pages behind a reply's web steps, read from the tool results of
/// `search_web` (title, link, snippet; the query is the call's argument) and
/// `fetch_url` (the page opened). Pages opened come first, then search hits;
/// each URL once, keeping the first query that returned it; no cap (the
/// control shows a few icons, the sheet lists them all). Failed calls add
/// nothing.
List<WebSource> webSourcesFromRecords(Iterable<AssistantActionRecord> records) {
  final opened = <String, WebSource>{};
  final found = <String, WebSource>{};
  for (final record in records) {
    if (record.failed || _resultSaysFailed(record.result)) continue;
    final name = record.toolName.trim();
    final base =
        name.contains('_') && name.substring(0, name.indexOf('_')).contains('-')
        ? name.substring(name.indexOf('_') + 1)
        : name;
    if (base == 'fetch_url') {
      final list = <WebSource>[];
      _parseSourceText(record.result, list, 0);
      if (list.isEmpty) {
        // The page the tool actually fetched is named in the call it ran.
        try {
          final args = jsonDecode(record.arguments);
          final url = args is Map ? _webUrl(args['url']) : null;
          if (url != null) list.add(WebSource(url: url, title: ''));
        } catch (_) {}
      }
      if (list.isNotEmpty) opened.putIfAbsent(list.first.url, () => list.first);
    } else if (base == 'search_web') {
      final list = <WebSource>[];
      _parseSourceText(record.result, list, 0);
      final query = _searchQuery(record.arguments);
      for (final hit in list) {
        found.putIfAbsent(
          hit.url,
          () => WebSource(
            url: hit.url,
            title: hit.title,
            snippet: hit.snippet,
            query: query,
          ),
        );
      }
    }
  }
  return [
    for (final o in opened.values)
      WebSource(
        url: o.url,
        title: o.title.isNotEmpty ? o.title : (found[o.url]?.title ?? ''),
        snippet: found[o.url]?.snippet,
        query: found[o.url]?.query,
        opened: true,
      ),
    for (final f in found.values)
      if (!opened.containsKey(f.url)) f,
  ];
}

/// Everything the stamp shows for one reply, from its stored tool calls.
class ToolStampData {
  const ToolStampData(this.entries, this.summary, [this.sources = const []]);

  final List<ToolStampEntry> entries;
  final List<ToolSummarySegment> summary;

  /// Pages the web steps found or opened (see [webSourcesFromRecords]).
  final List<WebSource> sources;

  bool get isEmpty => entries.isEmpty;

  static const empty = ToolStampData([], []);

  factory ToolStampData.fromRecords(Iterable<AssistantActionRecord> records) {
    final list = records.toList();
    return ToolStampData(
      buildToolStamp(list),
      buildToolSummary(list),
      webSourcesFromRecords(list),
    );
  }
}

/// A small row under a reply, grouped by what happened ("Checked calendar ·
/// Saved to calendar"). Tap it for the exact tool list. Plain English: the
/// stamp does not go through the ARB files.
class ToolStamp extends StatefulWidget {
  const ToolStamp({super.key, required this.data});

  final ToolStampData data;

  @override
  State<ToolStamp> createState() => _ToolStampState();
}

class _ToolStampState extends State<ToolStamp> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    if (data.isEmpty) return const SizedBox.shrink();
    final theme = context.conduitTheme;
    final muted = theme.textSecondary.withValues(alpha: 0.75);
    final strong = theme.textPrimary;
    final error = theme.error;
    final mutedError = theme.error.withValues(alpha: 0.7);
    const size = 12.0;

    final summary = data.summary;
    final readOnly =
        summary.isNotEmpty &&
        summary.every((segment) => segment.kind == ToolSummaryKind.read);

    final spans = <InlineSpan>[];
    void sep() {
      if (spans.isNotEmpty) {
        spans.add(
          TextSpan(
            text: ' · ',
            style: TextStyle(color: muted),
          ),
        );
      }
    }

    InlineSpan icon(IconData data, Color color) => WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: Padding(
        padding: const EdgeInsets.only(right: 3),
        child: Icon(data, size: 13, color: color),
      ),
    );

    for (final segment in summary) {
      sep();
      switch (segment.kind) {
        case ToolSummaryKind.read:
          spans.add(
            TextSpan(
              text: segment.text,
              style: TextStyle(color: muted),
            ),
          );
        case ToolSummaryKind.write:
        case ToolSummaryKind.image:
          spans.add(icon(Icons.check_circle_outline, strong));
          spans.add(
            TextSpan(
              text: segment.text,
              style: TextStyle(color: strong, fontWeight: FontWeight.w500),
            ),
          );
        case ToolSummaryKind.failedWrite:
          spans.add(icon(Icons.error_outline, error));
          spans.add(
            TextSpan(
              text: segment.text,
              style: TextStyle(color: error, fontWeight: FontWeight.w500),
            ),
          );
        case ToolSummaryKind.failedRead:
          spans.add(
            TextSpan(
              text: segment.text,
              style: TextStyle(color: mutedError),
            ),
          );
      }
    }

    final detail = data.entries.map((e) => e.label).join(' · ');
    final stamp = Semantics(
      label:
          'Tools used: ${summary.map((s) => s.text).join(', ')}. '
          '${_expanded ? 'Tap to collapse' : 'Tap for details'}',
      button: true,
      excludeSemantics: true,
      child: GestureDetector(
        key: const ValueKey<String>('tool-stamp'),
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _expanded = !_expanded),
        child: Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  if (readOnly) ...[
                    Icon(Icons.build_outlined, size: 13, color: muted),
                    const SizedBox(width: 5),
                  ],
                  Flexible(
                    child: Text.rich(
                      TextSpan(children: spans),
                      key: const ValueKey<String>('tool-stamp-text'),
                      style: const TextStyle(fontSize: size, height: 1.25),
                    ),
                  ),
                ],
              ),
              if (_expanded)
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Text(
                    detail,
                    key: const ValueKey<String>('tool-stamp-detail'),
                    style: TextStyle(
                      fontSize: size,
                      height: 1.25,
                      color: muted,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    if (data.sources.isEmpty) return stamp;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        stamp,
        WebSourcesControl(sources: data.sources),
      ],
    );
  }
}
