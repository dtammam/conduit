import 'dart:math' as math;

import 'package:conduit_core/models/chat_message.dart';

/// What the assistant is doing, as shown by the optional avatar in the chat
/// app bar: resting, busy with a reply (reasoning, writing or running a
/// tool), making or editing an image, or just finished.
enum AssistantActivity { idle, working, making, done }

/// How long [AssistantActivity.done] shows after a reply finishes cleanly.
const Duration kAssistantActivityDoneHold = Duration(seconds: 3);

/// Status actions that mean a search, knowledge lookup or tool is running.
///
/// These are the actions `streaming_status_widget.dart` names specially
/// (plus Open WebUI's plain `web_search`); Hermes tool steps are matched by
/// their `hermes_tool_` prefix.
const Set<String> _toolStatusActions = {
  'web_search',
  'web_search_queries_generated',
  'queries_generated',
  'knowledge_search',
  'sources_retrieved',
};

/// Semantic `<details>` types whose open block means a tool is running.
const Set<String> _toolDetailsTypes = {'tool_calls', 'code_interpreter'};

/// Open WebUI's built-in image tools, offered to a model with native
/// function calling: `generate_image` and `edit_image`.
const Set<String> _imageToolNames = {'generate_image', 'edit_image'};

/// Status descriptions Open WebUI's image generation feature (the composer's
/// image toggle) emits while it works. They carry no `action`, only this
/// English description, followed by "Image created" with `done: true`.
const Set<String> _imageStatusDescriptions = {'creating image'};

/// Whether a tool call named [name] makes or edits an image: one of
/// [_imageToolNames], also behind a server prefix ("images_generate_image").
bool _isImageToolName(String? name) {
  final trimmed = name?.trim().toLowerCase() ?? '';
  if (trimmed.isEmpty) return false;
  for (final tool in _imageToolNames) {
    if (trimmed == tool || trimmed.endsWith('_$tool')) return true;
  }
  return false;
}

bool _isImageStatus(ChatStatusUpdate status) {
  final action = status.action?.trim().toLowerCase() ?? '';
  if (action == 'image_generation' || _isImageToolName(action)) {
    return true;
  }
  final description = status.description?.trim().toLowerCase() ?? '';
  return _imageStatusDescriptions.contains(description);
}

bool _isToolStatusAction(String? action) {
  final trimmed = action?.trim();
  if (trimmed == null || trimmed.isEmpty) return false;
  return _toolStatusActions.contains(trimmed) ||
      trimmed.startsWith('hermes_tool_');
}

/// The assistant message the avatar describes: the streaming one in the
/// trailing run of assistant messages (a multi-model turn has several), else
/// the last of that run. Null when the transcript does not end with one.
ChatMessage? latestAssistantMessage(List<ChatMessage> messages) {
  ChatMessage? last;
  for (var index = messages.length - 1; index >= 0; index -= 1) {
    final message = messages[index];
    if (message.role != 'assistant') break;
    if (message.isStreaming) return message;
    last ??= message;
  }
  return last;
}

/// The live activity of [message] and, when the assistant runs a tool or
/// makes an image and the stream names the step, what that step is: the
/// status line's description (a search, a knowledge lookup) or the tool
/// call's name as the status rows show it ("search_web" reads "Search
/// web"). Never returns [AssistantActivity.done]; the avatar holds that
/// state for [kAssistantActivityDoneHold] after streaming ends.
({AssistantActivity activity, String? detail}) _deriveLive(
  ChatMessage? message,
) {
  if (message == null || !message.isStreaming) {
    return (activity: AssistantActivity.idle, detail: null);
  }

  ChatStatusUpdate? status;
  for (var index = message.statusHistory.length - 1; index >= 0; index -= 1) {
    final candidate = message.statusHistory[index];
    if (candidate.hidden == true) continue;
    status = candidate;
    break;
  }
  if (status != null && status.done != true) {
    if (_isImageStatus(status)) {
      return (
        activity: AssistantActivity.making,
        detail: _statusDetail(status),
      );
    }
    if (_isToolStatusAction(status.action)) {
      return (
        activity: AssistantActivity.working,
        detail: _statusDetail(status),
      );
    }
  }

  final active = _activeTrailingDetails(message.content);
  if (active != null && _toolDetailsTypes.contains(active.type)) {
    return (
      activity: _isImageToolName(active.name)
          ? AssistantActivity.making
          : AssistantActivity.working,
      detail: _toolStepLabel(active.name),
    );
  }
  // Reasoning, waiting for the first token and writing the answer are one
  // busy state.
  return (activity: AssistantActivity.working, detail: null);
}

String? _statusDetail(ChatStatusUpdate status) {
  final description = status.description?.trim() ?? '';
  if (description.isNotEmpty) return description;
  final action = status.action?.trim() ?? '';
  final name = action.startsWith('hermes_tool_')
      ? action.substring('hermes_tool_'.length)
      : action;
  return _toolStepLabel(name);
}

/// A tool or action name the way the streaming status rows print one
/// (`streaming_status_widget.dart`): underscores become spaces and the
/// first letter is capitalized. Null for an empty name.
String? _toolStepLabel(String? name) {
  final words = name?.replaceAll('_', ' ').trim() ?? '';
  if (words.isEmpty) return null;
  return '${words[0].toUpperCase()}${words.substring(1)}';
}

/// What the avatar shows: the live activity while streaming, otherwise
/// [AssistantActivity.done] while [holdingDone] (the avatar holds it for a
/// few seconds after a clean finish), otherwise idle.
AssistantActivity resolveDisplayedAssistantActivity({
  required AssistantActivity live,
  required bool holdingDone,
}) {
  if (live != AssistantActivity.idle) return live;
  return holdingDone ? AssistantActivity.done : AssistantActivity.idle;
}

/// The narrow slice of the transcript the avatar rebuilds on: the live
/// activity, the running tool step's name when there is one, and whether
/// the latest reply carries an error.
typedef AssistantActivitySnapshot = ({
  AssistantActivity live,
  String? detail,
  bool failed,
});

AssistantActivitySnapshot assistantActivitySnapshot(
  List<ChatMessage> messages,
) {
  final message = latestAssistantMessage(messages);
  final live = _deriveLive(message);
  return (
    live: live.activity,
    detail: live.detail,
    failed: message?.error != null,
  );
}

/// How far back from the end of a reply [_activeTrailingDetails] looks for
/// the opening tag of a running block. The snapshot is taken on every
/// streamed chunk, so the scan must not grow with the reply. An in-flight
/// tool block is a short opening tag and summary at the very end of the
/// reply; one whose tag starts further back than this reads as plain
/// working, with no step name.
const int _trailingDetailsWindow = 8192;

final RegExp _detailsOpenTag = RegExp(
  r'<details\b([^>]*)>',
  caseSensitive: false,
);
final RegExp _detailsTypeAttr = RegExp(r'''type\s*=\s*["']([^"']+)["']''');
final RegExp _detailsNameAttr = RegExp(r'''\bname\s*=\s*["']([^"']*)["']''');
final RegExp _detailsDoneTrue = RegExp(r'''done\s*=\s*["']true["']''');

/// The `type` and `name` of the last `<details>` block when it is still
/// running and nothing visible follows it: an unclosed block, or a closed
/// one marked `done="false"` (how Open WebUI shows a tool call in flight).
/// Only the last [_trailingDetailsWindow] characters are read.
({String type, String? name})? _activeTrailingDetails(String content) {
  final windowStart = math.max(0, content.length - _trailingDetailsWindow);
  RegExpMatch? last;
  for (final match in _detailsOpenTag.allMatches(content, windowStart)) {
    last = match;
  }
  if (last == null) return null;
  final attributes = last.group(1) ?? '';
  final rest = content.substring(last.end).toLowerCase();
  final closeIndex = rest.indexOf('</details>');
  if (closeIndex >= 0) {
    final after = rest.substring(closeIndex + '</details>'.length);
    if (after.trim().isNotEmpty) return null;
    if (_detailsDoneTrue.hasMatch(attributes)) return null;
  }
  final type = _detailsTypeAttr.firstMatch(attributes)?.group(1)?.trim();
  if (type == null) return null;
  return (
    type: type,
    name: _detailsNameAttr.firstMatch(attributes)?.group(1)?.trim(),
  );
}
