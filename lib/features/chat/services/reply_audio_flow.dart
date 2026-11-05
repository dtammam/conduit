import 'dart:io';

import 'package:conduit_core/features/chat/server_speech/direct_voice_provider_settings.dart';
import 'package:conduit_markdown/conduit_markdown.dart';

import 'reply_mp3_export.dart';
import 'speech_take_join.dart';
import 'speech_take_store.dart';
import 'tts_manager.dart';

/// Which reply's audio, in which voice(s), from which text.
class ReplyAudioRequest {
  const ReplyAudioRequest({
    required this.messageId,
    required this.text,
    required this.lookupVoiceKeys,
    required this.renderVoiceKey,
    this.chatId,
  });

  /// The request for a reply in the voice in use now: a take is looked up in
  /// the voice it was read in ([heardKey]) and in the voice a new render uses
  /// (the Voice provider's), and a render is saved under the latter.
  factory ReplyAudioRequest.forReply({
    required String messageId,
    required String text,
    String? chatId,
    DirectVoiceProviderSettings? voice,
    String? heardKey,
  }) {
    final renderKey = voice != null && voice.canSynthesize
        ? 'direct|${voice.speechModel ?? ''}|${voice.speechVoice ?? ''}'
        : (heardKey ?? 'default');
    return ReplyAudioRequest(
      messageId: messageId,
      text: text,
      chatId: chatId,
      lookupVoiceKeys: [?heardKey, renderKey],
      renderVoiceKey: renderKey,
    );
  }

  final String messageId;
  final String text;
  final String? chatId;

  /// Voices a heard take may be in, best first: the voice the reply was read
  /// in, then the one a new render uses.
  final List<String> lookupVoiceKeys;

  /// The voice a new render is made in and saved under.
  final String renderVoiceKey;
}

/// What Share audio, Share as video and Save to Files do about a reply's
/// sound: use the take Dean heard if one is kept, else render one through the
/// relay. A rendered take is kept too, so the next share is the same audio.
class ReplyAudioFlow {
  ReplyAudioFlow({
    required this.exporter,
    SpeechTakeStore? store,
    List<String> Function(String text)? splitSentences,
  }) : store = store ?? SpeechTakeStore.instance,
       _split = splitSentences ?? TtsManager.instance.splitTextForSpeech;

  final ReplyMp3Export exporter;
  final SpeechTakeStore store;
  final List<String> Function(String text) _split;

  /// The kept take for this reply in a voice it may have been heard in; null
  /// when there is none (or the text changed since). Calls no relay.
  Future<SpeechTake?> savedTake(ReplyAudioRequest request) async {
    for (final voice in request.lookupVoiceKeys) {
      final take = await store.find(
        messageId: request.messageId,
        voiceKey: voice,
        text: request.text,
        chatId: request.chatId,
      );
      if (take != null) return take;
    }
    return null;
  }

  /// Renders a new take through the relay and keeps it in place of any other.
  ///
  /// A background render passes [stillWanted] (false once Dean pressed Listen
  /// or Share took over) and [onlyIfMissing]: a take that appeared while it
  /// rendered is never replaced by it, and it then throws
  /// [ReplyAudioDropped] with nothing kept.
  Future<SpeechTake> render(
    ReplyAudioRequest request, {
    void Function(Mp3ExportTicket ticket)? onEstimate,
    bool Function()? stillWanted,
    bool onlyIfMissing = false,
  }) async {
    final rendered = await exporter.export(
      request.text,
      onEstimate: onEstimate,
    );
    Future<Never> drop() async {
      try {
        await rendered.file.delete();
      } catch (_) {}
      throw const ReplyAudioDropped();
    }

    if (stillWanted != null && !stillWanted()) await drop();
    if (onlyIfMissing && await savedTake(request) != null) await drop();
    if (stillWanted != null && !stillWanted()) await drop();
    final extension = ReplyMp3Export.extensionFor(rendered.mimeType);
    // One whole file: cut it at its silent gaps so Listen can follow the
    // voice sentence by sentence (see SpeechTakeJoin.silenceUnits).
    List<int>? sizes, starts;
    if (extension == 'mp3') {
      try {
        final units = SpeechTakeJoin.silenceUnits(
          await rendered.file.readAsBytes(),
          _split(ConduitMarkdownPreprocessor.cleanText(request.text)),
        );
        sizes = units?.sizes;
        starts = units?.starts;
      } catch (_) {}
    }
    final take = await store.save(
      messageId: request.messageId,
      voiceKey: request.renderVoiceKey,
      text: request.text,
      source: rendered.file,
      extension: extension,
      chatId: request.chatId,
      clipSizes: sizes,
      unitStarts: starts,
    );
    // The take is the copy that lasts; the export's own file is not needed.
    try {
      await rendered.file.delete();
    } catch (_) {}
    return take;
  }

  /// The take to share or save, or null when Dean closes the preview.
  ///
  /// A kept take is used at once, with no relay call and no sheet. With none,
  /// [render] makes one and [showPreview] puts it in front of him; what it
  /// returns is the take he last previewed (Try again calls [render] again
  /// and replaces the kept take). [preview] forces the sheet for a kept take.
  Future<SpeechTake?> choose(
    ReplyAudioRequest request, {
    bool preview = false,
    required Future<SpeechTake> Function() render,
    required Future<SpeechTake?> Function(
      SpeechTake take,
      Future<SpeechTake> Function() tryAgain,
    )
    showPreview,
    Future<SpeechTake> Function()? renderForTryAgain,
  }) async {
    final saved = await savedTake(request);
    if (saved != null && !preview) return saved;
    final take = saved ?? await render();
    return showPreview(take, renderForTryAgain ?? render);
  }

  /// A copy of [take] in the share folder, for the share sheet, the video
  /// maker or Save to Files.
  Future<({File file, String mimeType})> stage(
    SpeechTake take,
    ReplyAudioRequest request,
  ) => exporter.stage(take.file, request.text, take.mimeType);
}

/// A background render that gave way: Listen or Share took over, or a take
/// appeared. Nothing was kept.
class ReplyAudioDropped implements Exception {
  const ReplyAudioDropped();
  @override
  String toString() => 'ReplyAudioDropped';
}
