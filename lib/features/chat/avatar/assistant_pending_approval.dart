import 'package:conduit_core/features/chat/composer/openwebui_prompt_answers.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/chat/providers/openwebui_chat_prompt_provider.dart';
import 'package:conduit_core/features/chat/providers/openwebui_prompt_resolution.dart';
import 'package:conduit_core/models/openwebui_chat_prompt.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The Open WebUI prompt waiting in the active chat, as the avatar's
/// Approvals tab and badge see it: the same prompt the composer overlay
/// shows, found by the same rules.
class AssistantApproval {
  const AssistantApproval({
    required this.prompt,
    required this.conversationId,
    this.persisted,
  });

  final OpenWebUiComposerPrompt prompt;
  final String conversationId;

  /// Set when the prompt is saved on a message (answered through the server);
  /// null for a live socket prompt.
  final OpenWebUiPendingToolPrompt? persisted;

  /// The tool the prompt is about, when it names one.
  String? get toolName {
    final name = persisted?.toolName ?? prompt.title;
    return name.trim().isEmpty ? null : name.trim();
  }

  /// Whether a plain approve or reject answers it. A question with options
  /// needs the composer's overlay.
  bool get canDecideHere => prompt.kind != OpenWebUiComposerPromptKind.askUser;

  @override
  bool operator ==(Object other) =>
      other is AssistantApproval &&
      other.prompt.identity == prompt.identity &&
      other.conversationId == conversationId;

  @override
  int get hashCode => Object.hash(prompt.identity, conversationId);
}

/// The pending prompt of the active chat, null when nothing waits.
final assistantApprovalProvider = Provider<AssistantApproval?>((ref) {
  final conversation = ref.watch(activeConversationProvider);
  final conversationId = conversation?.id;
  if (conversationId == null) return null;
  final loading = ref.watch(isLoadingConversationProvider);
  final pendingIdentity = ref.watch(
    chatMessagesProvider.select(
      (messages) => findPendingOpenWebUiToolPrompt(messages)?.prompt.identity,
    ),
  );
  if (pendingIdentity != null &&
      canUsePersistedOpenWebUiPrompt(
        isLoadingConversation: loading,
        ownerConversationId: conversationId,
        activeConversationId: conversationId,
      ) &&
      conversationUsesOpenWebUiStorage(conversation) &&
      !isTemporaryChat(conversationId)) {
    final pending = findPendingOpenWebUiToolPrompt(
      ref.read(chatMessagesProvider),
    );
    if (pending != null) {
      return AssistantApproval(
        prompt: pending.prompt,
        conversationId: conversationId,
        persisted: pending,
      );
    }
  }
  final live = ref.watch(openWebUiLivePromptProvider);
  if (live != null && live.conversationId == conversationId) {
    return AssistantApproval(
      prompt: live.prompt,
      conversationId: conversationId,
    );
  }
  return null;
});

/// Approves or rejects [approval] through the same code the composer overlay
/// calls, so answering here is answering in the chat. Throws when the chat
/// cannot take the answer.
Future<void> decideAssistantApproval(
  WidgetRef ref,
  AssistantApproval approval, {
  required bool approved,
}) async {
  final persisted = approval.persisted;
  if (persisted != null) {
    await resolvePersistedOpenWebUiPrompt(
      ref,
      ownerConversationId: approval.conversationId,
      pending: persisted,
      action: openWebUiDecisionAction(approval.prompt, approved),
    );
    return;
  }
  final notifier = ref.read(openWebUiLivePromptProvider.notifier);
  if (approval.prompt.kind == OpenWebUiComposerPromptKind.confirmation) {
    notifier.decide(approval.prompt.identity, approved);
  } else {
    notifier.cancel();
  }
}
