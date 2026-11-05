import 'dart:io';

import 'reply_mp3_export.dart';
import 'speech_take_store.dart';

/// Which reply's audio, in which voice(s), from which text.
class ReplyAudioRequest {
  const ReplyAudioRequest({
    required this.messageId,
    required this.text,
    required this.lookupVoiceKeys,
    required this.renderVoiceKey,
    this.chatId,
  });

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
  ReplyAudioFlow({required this.exporter, SpeechTakeStore? store})
    : store = store ?? SpeechTakeStore.instance;

  final ReplyMp3Export exporter;
  final SpeechTakeStore store;

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
  Future<SpeechTake> render(
    ReplyAudioRequest request, {
    void Function(Mp3ExportTicket ticket)? onEstimate,
  }) async {
    final rendered = await exporter.export(
      request.text,
      onEstimate: onEstimate,
    );
    final extension = ReplyMp3Export.extensionFor(rendered.mimeType);
    final take = await store.save(
      messageId: request.messageId,
      voiceKey: request.renderVoiceKey,
      text: request.text,
      source: rendered.file,
      extension: extension,
      chatId: request.chatId,
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
