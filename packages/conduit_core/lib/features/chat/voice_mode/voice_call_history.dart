/// The session history a voice call sends with each direct turn, and the
/// turns the call has shown locally.
///
/// Show-only: this never writes to Open WebUI. On the direct path the relay is
/// the single writer of the chat; Musey keeps these turns in memory for the
/// call and re-reads the chat from Open WebUI when the call ends.
library;

import 'package:conduit_core/features/chat/voice_mode/voice_direct_client.dart';
import 'package:conduit_core/models/chat_message.dart';

final class VoiceCallTurn {
  const VoiceCallTurn({
    required this.atIndex,
    required this.user,
    this.assistant,
    this.interrupted = false,
  });

  /// How many history entries from the chat itself came before this turn.
  final int atIndex;
  final VoiceHistoryEntry user;
  final VoiceHistoryEntry? assistant;
  final bool interrupted;
}

class VoiceCallHistory {
  /// The most recent entries sent. The relay trims further; this keeps a long
  /// chat (the Omni session can be megabytes) from riding along on every turn.
  static const int maxEntries = 40;

  final List<VoiceCallTurn> _turns = <VoiceCallTurn>[];

  /// The turns of this call that went the direct way, in order.
  List<VoiceCallTurn> get turns => List<VoiceCallTurn>.unmodifiable(_turns);

  bool get hasDirectTurns => _turns.isNotEmpty;

  /// The chat's own settled messages as history entries. Streaming messages
  /// and empty ones are left out; content is kept byte for byte.
  static List<VoiceHistoryEntry> entriesOf(List<ChatMessage> messages) => [
    for (final message in messages)
      if ((message.role == 'user' || message.role == 'assistant') &&
          !message.isStreaming &&
          message.content.isNotEmpty)
        VoiceHistoryEntry(
          id: message.id,
          role: message.role,
          content: message.content,
        ),
  ];

  /// The history for the next turn: the chat's messages with this call's
  /// direct turns put back where they happened (an Open WebUI-routed turn is
  /// already among [chatMessages]), capped to the last [maxEntries].
  List<VoiceHistoryEntry> build(List<ChatMessage> chatMessages) {
    final base = entriesOf(chatMessages);
    final merged = <VoiceHistoryEntry>[];
    var next = 0;
    for (var i = 0; i <= base.length; i++) {
      while (next < _turns.length && _turns[next].atIndex <= i) {
        final turn = _turns[next++];
        merged.add(turn.user);
        if (turn.assistant != null) merged.add(turn.assistant!);
      }
      if (i < base.length) merged.add(base[i]);
    }
    if (merged.length <= maxEntries) return merged;
    return merged.sublist(merged.length - maxEntries);
  }

  /// Records a turn the relay answered. [atIndex] is the length of
  /// [entriesOf] the chat had when the turn was sent.
  void record({
    required int atIndex,
    required VoiceHistoryEntry user,
    VoiceHistoryEntry? assistant,
    bool interrupted = false,
  }) {
    _turns.add(
      VoiceCallTurn(
        atIndex: atIndex,
        user: user,
        assistant: assistant,
        interrupted: interrupted,
      ),
    );
  }

  void clear() => _turns.clear();
}
