/// Runs one voice turn over Contract A and reports how it ended, so the
/// controller knows whether to speak on, send the turn the Open WebUI way, or
/// fall back. Holds no Open WebUI dependency: the direct path cannot write a
/// chat there (the relay does).
library;

import 'package:dio/dio.dart';

import 'package:conduit_core/features/chat/voice_mode/voice_call_history.dart';
import 'package:conduit_core/features/chat/voice_mode/voice_direct_client.dart';
import 'package:conduit_core/models/chat_message.dart';

enum VoiceDirectOutcome {
  /// The relay answered; the reply was streamed through the callbacks.
  done,

  /// The relay's route is "owui": send this turn the old way. Its ack, if any,
  /// was already passed to `onAck`, and the relay's save queue is drained.
  owui,

  /// The relay could not take the turn at all (missing, off, unreachable, or
  /// refused before any answer): send it the old way.
  fallback,

  /// The turn failed after the relay had started answering.
  failed,

  /// [VoiceDirectTurnRunner.cancel] stopped it (barge-in, call end).
  cancelled,
}

final class VoiceDirectResult {
  const VoiceDirectResult(
    this.outcome, {
    this.content = '',
    this.error,
    this.disableDirect = false,
  });
  final VoiceDirectOutcome outcome;

  /// The reply as streamed (or the relay's final text on `done`).
  final String content;
  final String? error;

  /// True when /voice/turn is missing or switched off: stay on the old path
  /// for the rest of the call.
  final bool disableDirect;
}

final class VoiceDirectTurnRunner {
  VoiceDirectTurnRunner({required this.history});

  final VoiceCallHistory history;
  CancelToken? _cancel;

  void cancel() {
    final token = _cancel;
    if (token != null && !token.isCancelled) token.cancel('voice turn stopped');
  }

  Future<VoiceDirectResult> run({
    required VoiceDirectClient client,
    required String callId,
    required String chatId,
    required String text,
    required List<ChatMessage> chatMessages,
    required void Function(String text) onAck,
    required void Function(String text) onDelta,
    String? personaId,
    String build = '',
    String tz = '',
    bool test = false,
    String? turnId,
  }) async {
    final id = turnId ?? newVoiceTurnId();
    final atIndex = VoiceCallHistory.entriesOf(chatMessages).length;
    final request = VoiceDirectRequest(
      turnId: id,
      callId: callId,
      chatId: chatId,
      personaId: personaId,
      text: text,
      history: history.build(chatMessages),
      build: build,
      tz: tz,
      test: test,
    );
    final cancel = CancelToken();
    _cancel = cancel;
    final streamed = StringBuffer();
    var heard = false;
    var owui = false;

    VoiceCallHistory partial() => history
      ..record(
        atIndex: atIndex,
        user: VoiceHistoryEntry(id: '$id:u', role: 'user', content: text),
        assistant: streamed.isEmpty
            ? null
            : VoiceHistoryEntry(
                id: '$id:a',
                role: 'assistant',
                content: streamed.toString(),
              ),
        interrupted: true,
      );

    try {
      await for (final event in client.turn(request, cancel: cancel)) {
        switch (event) {
          case VoiceDirectMeta():
            heard = true;
            if (event.isOwui) owui = true;
          case VoiceDirectAck():
            heard = true;
            if (event.text.isNotEmpty) onAck(event.text);
          case VoiceDirectDelta():
            heard = true;
            streamed.write(event.text);
            if (event.text.isNotEmpty) onDelta(event.text);
          case VoiceDirectDone():
            history.record(
              atIndex: atIndex,
              user: VoiceHistoryEntry(
                id: event.userId ?? '$id:u',
                role: 'user',
                content: text,
              ),
              assistant: VoiceHistoryEntry(
                id: event.assistantId ?? '$id:a',
                role: 'assistant',
                content: event.content,
              ),
              interrupted: event.interrupted,
            );
            return VoiceDirectResult(
              VoiceDirectOutcome.done,
              content: event.content,
            );
          case VoiceDirectError():
            if (streamed.isEmpty && !owui) {
              return VoiceDirectResult(
                VoiceDirectOutcome.fallback,
                error: event.message,
                disableDirect: event.meansUnavailable,
              );
            }
            return VoiceDirectResult(
              VoiceDirectOutcome.failed,
              content: streamed.toString(),
              error: event.message,
            );
        }
      }
      if (cancel.isCancelled) {
        if (streamed.isNotEmpty) partial();
        return VoiceDirectResult(
          VoiceDirectOutcome.cancelled,
          content: streamed.toString(),
        );
      }
      if (owui) {
        await client.waitSaved(chatId);
        return const VoiceDirectResult(VoiceDirectOutcome.owui);
      }
      return const VoiceDirectResult(
        VoiceDirectOutcome.failed,
        error: 'The voice turn ended without an answer.',
      );
    } on VoiceDirectUnavailable catch (error) {
      return VoiceDirectResult(
        VoiceDirectOutcome.fallback,
        error: error.reason,
        disableDirect: true,
      );
    } on VoiceDirectNetworkException catch (error) {
      if (!heard) {
        return VoiceDirectResult(
          VoiceDirectOutcome.fallback,
          error: error.message,
        );
      }
      return VoiceDirectResult(
        VoiceDirectOutcome.failed,
        content: streamed.toString(),
        error: error.message,
      );
    } finally {
      if (identical(_cancel, cancel)) _cancel = null;
    }
  }
}
