import 'dart:async';

import 'package:conduit_core/features/chat/omni/omni_chat.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/tools/providers/tools_providers.dart';
import 'package:conduit_core/models/openwebui_chat_prompt.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/chat_entry_readiness_providers.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/chat/avatar/assistant_pending_approval.dart';
import '../features/navigation/providers/conversation_selection_provider.dart'
    show conversationSelectionProvider, ConversationSelectionDisposition;

/// "Ask Musey" for Siri and Shortcuts (build 182). Native Swift
/// (`AskMuseyIntent.swift`) takes the question, calls this over the
/// `am.tamm.conduit/ask_musey` channel, and speaks the answer.
///
/// The question goes to the Omni chat through the app's own durable send, with
/// the chat's selected tools, so it is the same turn as typing it there, and
/// the reply is in Omni afterwards whether Siri finished speaking it or not.
/// Nothing here answers a card: a write waits in the chat for Dean's yes.

const String askMuseyChannelName = 'am.tamm.conduit/ask_musey';

/// How long a spoken answer may run before it is cut at a sentence end.
const int kAskMuseySpokenLimit = 480;

const Duration kAskMuseyPoll = Duration(milliseconds: 250);

/// The words Siri says when the turn is not finished in time. The turn was
/// sent, so the reply lands in Omni.
const String kAskMuseySlowLine = "Bobby is still thinking, it's in Musey.";

enum AskMuseyStatus {
  /// Bobby's finished reply, in [AskMuseyOutcome.spoken].
  reply,

  /// A confirmation card waits in Musey. [AskMuseyOutcome.spoken] is the
  /// card's own line; nothing was confirmed.
  card,

  /// Sent, but not finished before the deadline. The reply lands in Omni.
  slow,

  /// Not sent (or the send failed), [AskMuseyOutcome.spoken] says why.
  error,
}

@immutable
class AskMuseyOutcome {
  const AskMuseyOutcome(this.status, this.spoken);

  final AskMuseyStatus status;
  final String spoken;

  Map<String, Object?> toMap() => {'status': status.name, 'spoken': spoken};

  @override
  bool operator ==(Object other) =>
      other is AskMuseyOutcome &&
      other.status == status &&
      other.spoken == spoken;

  @override
  int get hashCode => Object.hash(status, spoken);
}

/// What the turn looks like right now.
@immutable
class AskMuseyTurn {
  const AskMuseyTurn({
    this.content = '',
    this.streaming = true,
    this.failed = false,
    this.cardLine,
  });

  final String content;
  final bool streaming;
  final bool failed;

  /// Non-null while a confirmation card or question waits for Dean.
  final String? cardLine;
}

/// The chat side of a turn. The app's providers back [AskMuseyBridge]; tests
/// back it with a fake.
abstract class AskMuseyPorts {
  /// Opens the Omni chat. Returns null when ready, or the line to speak.
  Future<String?> prepare();

  /// Sends [question] as the next turn of the Omni chat.
  Future<void> send(String question);

  /// The reply to the question just sent, null until its row exists.
  AskMuseyTurn? snapshot();
}

/// Sends [question] and waits for the reply, a card or [deadline]. Never
/// confirms a card. [now] and [delay] are injectable for tests.
Future<AskMuseyOutcome> runAskMuseyTurn({
  required AskMuseyPorts ports,
  required String question,
  required Duration deadline,
  Duration poll = kAskMuseyPoll,
  DateTime Function()? now,
  Future<void> Function(Duration)? delay,
}) async {
  final clock = now ?? DateTime.now;
  final wait = delay ?? (d) => Future<void>.delayed(d);
  final end = clock().add(deadline);
  final text = question.trim();
  if (text.isEmpty) {
    return const AskMuseyOutcome(
      AskMuseyStatus.error,
      "I didn't catch a question.",
    );
  }

  var sent = false;
  Duration remaining() => end.difference(clock());

  Future<T> within<T>(Future<T> work) {
    final left = remaining();
    if (left <= Duration.zero) return Future<T>.error(TimeoutException(null));
    return work.timeout(left);
  }

  try {
    final problem = await within(ports.prepare());
    if (problem != null) {
      return AskMuseyOutcome(AskMuseyStatus.error, problem);
    }
    await within(ports.send(text));
    sent = true;
    while (true) {
      final turn = ports.snapshot();
      if (turn != null) {
        final card = turn.cardLine;
        if (card != null) {
          return AskMuseyOutcome(AskMuseyStatus.card, card);
        }
        if (turn.failed) {
          return const AskMuseyOutcome(
            AskMuseyStatus.error,
            "Bobby couldn't answer that. It's in Musey.",
          );
        }
        if (!turn.streaming && turn.content.trim().isNotEmpty) {
          final spoken = museySpeakable(turn.content);
          if (spoken.isNotEmpty) {
            return AskMuseyOutcome(AskMuseyStatus.reply, spoken);
          }
        }
      }
      if (remaining() <= Duration.zero) {
        return const AskMuseyOutcome(AskMuseyStatus.slow, kAskMuseySlowLine);
      }
      await wait(poll);
    }
  } on TimeoutException {
    return sent
        ? const AskMuseyOutcome(AskMuseyStatus.slow, kAskMuseySlowLine)
        : const AskMuseyOutcome(
            AskMuseyStatus.error,
            "Musey wasn't ready. Open it and try again.",
          );
  } catch (error) {
    DebugLogger.warning(
      'ask-musey-failed',
      scope: 'app-intents/ask-musey',
      data: {'error': error.runtimeType.toString(), 'sent': sent},
    );
    return AskMuseyOutcome(
      AskMuseyStatus.error,
      sent
          ? "Something went wrong. Check Musey."
          : "I couldn't send that. Try again.",
    );
  }
}

final RegExp _fence = RegExp(r'```[\s\S]*?(```|$)');
final RegExp _image = RegExp(r'!\[[^\]]*\]\([^)]*\)');
final RegExp _link = RegExp(r'\[([^\]]+)\]\([^)]*\)');
final RegExp _bareUrl = RegExp(r'https?://\S+');
final RegExp _lineMarker = RegExp(
  r'^[ \t]*(#{1,6}[ \t]+|>[ \t]?|[-*+][ \t]+|\d+[.)][ \t]+)',
  multiLine: true,
);
final RegExp _inlineMarks = RegExp(r'(\*\*|__|~~|`|\*|(?<=\s|^)_|_(?=\s|$))');
final RegExp _tagLike = RegExp(r'<[^>\n]{1,80}>');
final RegExp _blankRuns = RegExp(r'\s+');

/// Bobby's reply as something Siri can read: no code blocks, links, images or
/// markdown marks, whitespace collapsed, cut at a sentence end near
/// [kAskMuseySpokenLimit] with a pointer to Musey when cut.
String museySpeakable(String markdown, {int limit = kAskMuseySpokenLimit}) {
  var text = markdown
      .replaceAll(_fence, ' ')
      .replaceAll(_image, ' ')
      .replaceAllMapped(_link, (m) => m.group(1) ?? '')
      .replaceAll(_bareUrl, ' ')
      .replaceAll(_tagLike, ' ')
      .replaceAll(_lineMarker, '')
      .replaceAll(_inlineMarks, '')
      .replaceAll(_blankRuns, ' ')
      .trim();
  if (text.length <= limit) return text;
  var cut = -1;
  for (var i = limit; i > limit ~/ 2; i--) {
    final c = text[i - 1];
    if ((c == '.' || c == '!' || c == '?') &&
        (i == text.length || text[i] == ' ')) {
      cut = i;
      break;
    }
  }
  if (cut < 0) {
    cut = text.lastIndexOf(' ', limit);
    if (cut < limit ~/ 2) cut = limit;
  }
  text = text.substring(0, cut).trim();
  if (!RegExp(r'[.!?]$').hasMatch(text)) text = '$text.';
  return '$text The rest is in Musey.';
}

/// What Siri says for a card: the card's own question or message.
String museyCardLine(OpenWebUiComposerPrompt prompt) {
  for (final q in prompt.questions) {
    final line = museySpeakable(q.question);
    if (line.isNotEmpty) return line;
  }
  for (final raw in [prompt.message, prompt.title]) {
    final line = museySpeakable(raw);
    if (line.isNotEmpty) return line;
  }
  return 'Bobby has a card for you.';
}

/// [AskMuseyPorts] over the app's providers.
class ProviderAskMuseyPorts implements AskMuseyPorts {
  ProviderAskMuseyPorts(this._ref);

  final Ref _ref;
  String? _omniId;
  int _countBefore = 0;
  String? _assistantId;

  @override
  Future<String?> prepare() async {
    if (_ref.read(apiServiceProvider) == null) {
      return 'Musey is signed out. Open it and sign in.';
    }
    if (!_ref.read(appSettingsProvider).omniChatEnabled) {
      return 'The Omni chat is off in Musey.';
    }
    final ready = await waitForChatEntryReady(
      _ref,
      requireModel: true,
      timeout: const Duration(seconds: 8),
    );
    if (!ready) return "Musey isn't ready. Open it and try again.";
    final omni = await _ref.read(omniChatProvider.future);
    if (omni == null) return "I couldn't open the Omni chat.";
    if (_ref.read(activeConversationProvider)?.id != omni.id) {
      final result = await _ref
          .read(conversationSelectionProvider.notifier)
          .select(omni);
      if (result.disposition != ConversationSelectionDisposition.committed) {
        return "I couldn't open the Omni chat.";
      }
    }
    final messages = _ref.read(chatMessagesProvider);
    if (messages.any((m) => m.isStreaming)) {
      return 'Bobby is busy in Musey. Try again in a moment.';
    }
    _omniId = omni.id;
    _countBefore = messages.length;
    return null;
  }

  @override
  Future<void> send(String question) async {
    final completer = Completer<String>();
    await durableSend(
      _ref,
      question,
      null,
      // The chat's selected tools, like typing it: a send that should act
      // must name them (AGENTS.md).
      toolIds: () {
        final ids = _ref.read(selectedToolIdsProvider);
        return ids.isNotEmpty ? ids : null;
      }(),
      onAssistantPlaceholderCreated: (handle) {
        if (!completer.isCompleted) {
          completer.complete(handle.assistantMessageId);
        }
      },
    );
    _assistantId = completer.isCompleted ? await completer.future : null;
  }

  @override
  AskMuseyTurn? snapshot() {
    final omniId = _omniId;
    if (omniId == null) return null;
    final approval = _ref.read(assistantApprovalProvider);
    if (approval != null && approval.conversationId == omniId) {
      return AskMuseyTurn(cardLine: museyCardLine(approval.prompt));
    }
    final messages = _ref.read(chatMessagesProvider);
    final id = _assistantId;
    final reply = id != null
        ? messages.where((m) => m.id == id).firstOrNull
        : (messages.length > _countBefore + 1 &&
                  messages.last.role == 'assistant'
              ? messages.last
              : null);
    if (reply == null) return null;
    return AskMuseyTurn(
      content: reply.content,
      streaming: reply.isStreaming,
      failed: reply.error != null,
    );
  }
}

/// Answers native `ask` calls from the Siri intent. Read once after sign-in;
/// it tells native it is ready, and native waits for that before asking.
final askMuseyBridgeProvider = NotifierProvider<AskMuseyBridge, void>(
  AskMuseyBridge.new,
);

class AskMuseyBridge extends Notifier<void> {
  static const MethodChannel _channel = MethodChannel(askMuseyChannelName);

  @visibleForTesting
  AskMuseyPorts Function(Ref ref)? portsOverride;

  @override
  void build() {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return;
    _channel.setMethodCallHandler(_onCall);
    ref.onDispose(() => _channel.setMethodCallHandler(null));
    unawaited(_channel.invokeMethod<void>('ready').catchError((Object _) {}));
  }

  Future<Object?> _onCall(MethodCall call) async {
    if (call.method != 'ask') throw MissingPluginException();
    final args = call.arguments is Map
        ? (call.arguments as Map).cast<String, Object?>()
        : const <String, Object?>{};
    final outcome = await handleAsk(
      question: (args['question'] as String?) ?? '',
      deadline: Duration(
        milliseconds: (args['deadline_ms'] as num?)?.toInt() ?? 20000,
      ),
    );
    return outcome.toMap();
  }

  @visibleForTesting
  Future<AskMuseyOutcome> handleAsk({
    required String question,
    required Duration deadline,
  }) {
    return runAskMuseyTurn(
      ports: (portsOverride ?? ProviderAskMuseyPorts.new)(ref),
      question: question,
      deadline: deadline,
    );
  }
}
