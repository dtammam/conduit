import 'dart:convert';

import 'package:conduit_core/features/chat/omni/omni_chat.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit_core/features/direct_connections/services/direct_chat_bridge.dart';
import 'package:conduit_core/features/direct_connections/services/direct_model_registry.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/persistence/account_scoped_preferences.dart';
import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/utils/usage_summary.dart';
import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';

const int kContextWindowMinTokens = 1024;
const int kContextWindowMaxTokens = 2 * 1024 * 1024;

/// Above this share of the window the ring takes the warning tint.
const double kContextUsageWarningFraction = 0.8;

/// Above this share of the window the ring takes the critical tint.
const double kContextUsageCriticalFraction = 0.95;

/// Rough characters per token for the estimate used when no usage is reported.
const int kContextEstimateCharsPerToken = 4;

enum ContextUsageLevel { normal, warning, critical }

ContextUsageLevel contextUsageLevel(double fraction) {
  if (fraction > kContextUsageCriticalFraction) {
    return ContextUsageLevel.critical;
  }
  if (fraction > kContextUsageWarningFraction) {
    return ContextUsageLevel.warning;
  }
  return ContextUsageLevel.normal;
}

/// Where the context window figure came from.
enum ContextWindowSource {
  /// The model's own metadata (`context_length` or `params.num_ctx`).
  model,

  /// Set by the person from the ring's sheet.
  user,

  /// The Direct Connections compaction default, used when nothing else is set.
  directDefault,
}

/// How many tokens the conversation takes, and how that was found out.
@immutable
class ContextTokenCount {
  const ContextTokenCount({
    required this.usedTokens,
    required this.estimated,
    this.promptTokens,
    this.completionTokens,
  });

  final int usedTokens;

  /// True when the figure is an estimate rather than the server's count.
  final bool estimated;

  /// The prompt and completion split of the latest reply, when reported.
  final int? promptTokens;
  final int? completionTokens;

  @override
  bool operator ==(Object other) =>
      other is ContextTokenCount &&
      other.usedTokens == usedTokens &&
      other.estimated == estimated &&
      other.promptTokens == promptTokens &&
      other.completionTokens == completionTokens;

  @override
  int get hashCode =>
      Object.hash(usedTokens, estimated, promptTokens, completionTokens);
}

/// The latest finished reply's reported usage: its prompt plus its completion
/// is about the size of the next prompt.
///
/// Only the latest finished reply counts. When it carries no usage (the model
/// was not asked for it, or a proxy composed the reply), an older reply's
/// figure would understate the conversation, so this gives up instead.
ContextTokenCount? reportedContextTokens(List<ChatMessage> messages) {
  for (var index = messages.length - 1; index >= 0; index -= 1) {
    final message = messages[index];
    if (message.role != 'assistant' || message.isStreaming) continue;
    final usage = message.usage;
    if (usage == null || usage.isEmpty) return null;
    final summary = UsageSummary.fromUsage(usage);
    // The summary reads Ollama and llama.cpp counts only beside their timings;
    // a bare count is still a count here.
    final prompt =
        summary.promptTokens ??
        _positiveInt(usage['prompt_eval_count']) ??
        _positiveInt(usage['prompt_n']);
    final completion =
        summary.generationTokens ??
        _positiveInt(usage['eval_count']) ??
        _positiveInt(usage['predicted_n']);
    final int used;
    if (prompt != null || completion != null) {
      used = (prompt ?? 0) + (completion ?? 0);
    } else {
      used = summary.totalTokens ?? 0;
    }
    // Some proxies stamp composed replies with all-zero usage.
    if (used <= 0) return null;
    return ContextTokenCount(
      usedTokens: used,
      estimated: false,
      promptTokens: prompt,
      completionTokens: completion,
    );
  }
  return null;
}

/// A rough count from the message text, about four characters per token.
/// The system prompt and tool definitions are not in the transcript, so this
/// runs low.
ContextTokenCount? estimatedContextTokens(List<ChatMessage> messages) {
  var characters = 0;
  for (final message in messages) {
    if (message.isStreaming) continue;
    characters += message.content.length;
  }
  if (characters <= 0) return null;
  return ContextTokenCount(
    usedTokens:
        (characters + kContextEstimateCharsPerToken - 1) ~/
        kContextEstimateCharsPerToken,
    estimated: true,
  );
}

/// The conversation's token count: the server's figure when the latest
/// reply carries one, else the estimate from the message text.
ContextTokenCount? countContextTokens(List<ChatMessage> messages) =>
    reportedContextTokens(messages) ?? estimatedContextTokens(messages);

int? _positiveInt(Object? raw) {
  final parsed = switch (raw) {
    int() => raw,
    num() => raw.toInt(),
    String() => int.tryParse(raw.trim()),
    _ => null,
  };
  return parsed != null && parsed > 0 ? parsed : null;
}

/// The context window a model's metadata advertises: a `context_length`
/// capability, else Open WebUI's `num_ctx` model parameter.
int? modelAdvertisedContextWindow(Model model) {
  final advertised = directModelAdvertisedContextLength(model);
  if (advertised != null) return advertised;
  final metadata = model.metadata;
  final info = metadata?['info'];
  final infoParams = info is Map ? info['params'] : null;
  final params = metadata?['params'];
  return _positiveInt(infoParams is Map ? infoParams['num_ctx'] : null) ??
      _positiveInt(params is Map ? params['num_ctx'] : null);
}

bool isValidContextWindow(int tokens) =>
    tokens >= kContextWindowMinTokens && tokens <= kContextWindowMaxTokens;

/// Context windows set from the ring's sheet for server models, per model id.
///
/// Direct models keep theirs in [DirectContextLengthOverridesController],
/// which only takes Direct model ids. These name an Open WebUI account's
/// models, so they are stored per account.
class ContextWindowOverridesController extends Notifier<Map<String, int>> {
  Future<void> _mutationQueue = Future<void>.value();

  @override
  Map<String, int> build() {
    ref.watch(settledActiveAccountIdProvider);
    // Windows set before they were stored per account sit under the
    // device-wide key; an account with none of its own still reads them.
    final raw =
        PreferencesStore.getString(
          scopedPreferenceReadKey(PreferenceKeys.contextWindowOverrides),
        ) ??
        PreferencesStore.getString(PreferenceKeys.contextWindowOverrides);
    if (raw == null || raw.isEmpty) return const <String, int>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const <String, int>{};
      return Map<String, int>.unmodifiable({
        for (final entry in decoded.entries)
          if (_positiveInt(entry.value) case final tokens?
              when isValidContextWindow(tokens))
            entry.key.toString(): tokens,
      });
    } catch (_) {
      return const <String, int>{};
    }
  }

  Future<void> set(String modelId, int contextWindow) {
    if (modelId.isEmpty || !isValidContextWindow(contextWindow)) {
      throw ArgumentError('Invalid context window.');
    }
    return _enqueue(
      () => _persist(Map<String, int>.of(state)..[modelId] = contextWindow),
    );
  }

  Future<void> clear(String modelId) =>
      _enqueue(() => _persist(Map<String, int>.of(state)..remove(modelId)));

  Future<void> _enqueue(Future<void> Function() write) {
    final result = _mutationQueue.then<void>(
      (_) => write(),
      onError: (Object _, StackTrace _) => write(),
    );
    _mutationQueue = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<void> _persist(Map<String, int> updated) async {
    await PreferencesStore.put(
      scopedPreferenceWriteKey(PreferenceKeys.contextWindowOverrides),
      jsonEncode(updated),
    );
    if (ref.mounted) state = Map.unmodifiable(updated);
  }
}

final contextWindowOverridesProvider =
    NotifierProvider<ContextWindowOverridesController, Map<String, int>>(
      ContextWindowOverridesController.new,
    );

/// What the ring shows for the open conversation.
@immutable
class ContextUsage {
  const ContextUsage({
    required this.modelId,
    required this.tokens,
    this.contextWindow,
    this.windowSource,
    this.isDirect = false,
  });

  final String modelId;
  final ContextTokenCount tokens;

  /// Null when neither the model nor the person has said how big it is.
  final int? contextWindow;
  final ContextWindowSource? windowSource;

  /// Direct models keep their window in the Direct Connections setting.
  final bool isDirect;

  int get usedTokens => tokens.usedTokens;

  /// Share of the window in use, 0 to 1, or null when the window is unknown.
  double? get fraction {
    final window = contextWindow;
    if (window == null || window <= 0) return null;
    return (usedTokens / window).clamp(0.0, 1.0).toDouble();
  }

  @override
  bool operator ==(Object other) =>
      other is ContextUsage &&
      other.modelId == modelId &&
      other.tokens == tokens &&
      other.contextWindow == contextWindow &&
      other.windowSource == windowSource &&
      other.isDirect == isDirect;

  @override
  int get hashCode =>
      Object.hash(modelId, tokens, contextWindow, windowSource, isDirect);
}

/// The context window for [model] and where it came from.
({int? tokens, ContextWindowSource? source}) resolveContextWindow({
  required Model model,
  required Map<String, int> overrides,
  required Map<String, int> directOverrides,
}) {
  if (DirectModelId.decode(model.id) != null) {
    // Same precedence Direct compaction uses, so the ring and the compaction
    // agree on how full the conversation is.
    final advertised = directModelAdvertisedContextLength(model);
    if (advertised != null) {
      return (tokens: advertised, source: ContextWindowSource.model);
    }
    final set = directOverrides[model.id];
    if (set != null) return (tokens: set, source: ContextWindowSource.user);
    return (
      tokens: kDefaultDirectContextLength,
      source: ContextWindowSource.directDefault,
    );
  }
  final set = overrides[model.id];
  if (set != null) return (tokens: set, source: ContextWindowSource.user);
  final advertised = modelAdvertisedContextWindow(model);
  if (advertised != null) {
    return (tokens: advertised, source: ContextWindowSource.model);
  }
  return (tokens: null, source: null);
}

/// The transcript as the token count sees it. A streaming reply is not
/// counted until it finishes, so two lists are equal while their finished
/// messages are the same instances (unchanged messages keep their identity
/// across chatMessagesProvider emissions). Selecting this lets a streamed
/// chunk cost one identity walk instead of a recount.
@immutable
class _SettledMessages {
  const _SettledMessages(this.messages);

  final List<ChatMessage> messages;

  Iterable<ChatMessage> get _settled =>
      messages.where((message) => !message.isStreaming);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! _SettledMessages) return false;
    final mine = _settled.iterator;
    final theirs = other._settled.iterator;
    while (true) {
      final hasMine = mine.moveNext();
      if (hasMine != theirs.moveNext()) return false;
      if (!hasMine) return true;
      if (!identical(mine.current, theirs.current)) return false;
    }
  }

  @override
  int get hashCode => Object.hashAll(_settled.map(identityHashCode));
}

/// Null while there is nothing to measure: the setting is off, or there is
/// no model or no counted messages. With the setting off nothing is counted.
///
/// Recounted when a message finishes, the list changes or the window does,
/// not on every streamed chunk.
final chatContextUsageProvider = Provider<ContextUsage?>((ref) {
  final enabled = ref.watch(
    appSettingsProvider.select((settings) => settings.showContextUsage),
  );
  if (!enabled) return null;
  // The Omni chat sends the model only its current session, so the whole
  // chat's token count would measure nothing the model sees.
  final conversationId = ref.watch(
    activeConversationProvider.select((conversation) => conversation?.id),
  );
  if (isOmniChatId(conversationId)) return null;
  final model = ref.watch(selectedModelProvider);
  if (model == null) return null;
  final messages = ref
      .watch(chatMessagesProvider.select(_SettledMessages.new))
      .messages;
  final tokens = countContextTokens(messages);
  if (tokens == null) return null;
  final window = resolveContextWindow(
    model: model,
    overrides: ref.watch(contextWindowOverridesProvider),
    directOverrides: ref.watch(directContextLengthOverridesProvider),
  );
  return ContextUsage(
    modelId: model.id,
    tokens: tokens,
    contextWindow: window.tokens,
    windowSource: window.source,
    isDirect: DirectModelId.decode(model.id) != null,
  );
});
