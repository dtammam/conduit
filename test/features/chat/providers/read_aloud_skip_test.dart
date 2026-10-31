import 'package:checks/checks.dart';
import 'package:conduit/features/chat/providers/text_to_speech_provider.dart';
import 'package:conduit/features/chat/services/reply_mp3_export.dart';
import 'package:conduit/features/chat/services/text_to_speech_service.dart';

import 'dart:io';
import 'dart:typed_data';

import 'package:conduit_core/conduit_core.dart';
import 'package:conduit_core/features/chat/voice_mode/chat_voice_mode_controller.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records what is spoken; stopping reports a cancellation the way the
/// engine does, so a skip must not end the read-aloud it restarts.
class _Service extends TextToSpeechService {
  final spoken = <String>[];
  void Function()? _cancel;
  void Function(int)? sentence;

  @override
  bool get isAvailable => true;

  @override
  void bindHandlers({
    void Function()? onStart,
    void Function()? onComplete,
    void Function()? onCancel,
    void Function()? onPause,
    void Function()? onContinue,
    void Function(String message)? onError,
    void Function(int sentenceIndex)? onSentenceIndex,
    void Function(int start, int end)? onDeviceWordProgress,
  }) {
    _cancel = onCancel;
    sentence = onSentenceIndex;
    super.bindHandlers(
      onStart: onStart,
      onComplete: onComplete,
      onCancel: onCancel,
      onPause: onPause,
      onContinue: onContinue,
      onError: onError,
      onSentenceIndex: onSentenceIndex,
      onDeviceWordProgress: onDeviceWordProgress,
    );
  }

  @override
  Future<bool> initialize({
    String? deviceVoice,
    String? serverVoice,
    double speechRate = 0.5,
    double pitch = 1.0,
    double volume = 1.0,
    TtsEngine engine = TtsEngine.device,
  }) async => true;

  @override
  Future<void> speak(String text) async => spoken.add(text);

  @override
  Future<void> stop() async => _cancel?.call();
}

class _Voice extends ChatVoiceModeController {
  @override
  ChatVoiceModeSnapshot build() =>
      const ChatVoiceModeSnapshot(phase: ChatVoiceModePhase.idle);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Service service;
  late ProviderContainer container;
  TextToSpeechController controller() =>
      container.read(textToSpeechControllerProvider.notifier);
  TextToSpeechState state() => container.read(textToSpeechControllerProvider);

  setUp(() async {
    service = _Service();
    container = ProviderContainer(
      overrides: [
        textToSpeechServiceProvider.overrideWithValue(service),
        chatVoiceModeControllerProvider.overrideWith(_Voice.new),
        readAloudAudioRouteProvider.overrideWithValue(() async {}),
      ],
    );
    addTearDown(container.dispose);
    await controller().toggleForMessage(
      messageId: 'm1',
      text:
          'The first fish swims slowly around the big pond every single morning before the sun comes up. '
          'The second fish dives deep under the old wooden dock whenever a heron flies over the water. '
          'The third fish sleeps in the cool weeds near the shore for most of the hot summer afternoon.',
    );
  });

  test('next sentence restarts from the following sentence', () async {
    final count = state().sentences.length;
    check(count).isGreaterOrEqual(2);
    await controller().nextSentence();
    check(state().activeMessageId).equals('m1');
    check(state().activeSentenceIndex).equals(1);
    check(service.spoken.last)
        .equals(state().sentences.sublist(1).join(' ').trim());
  });

  test('the engine counts from the skipped-to sentence', () async {
    await controller().nextSentence();
    service.sentence?.call(1);
    check(state().activeSentenceIndex).equals(2);
  });

  test('previous sentence from the first one restarts it', () async {
    await controller().previousSentence();
    check(state().activeSentenceIndex).equals(0);
    check(state().activeMessageId).equals('m1');
  });

  test('next past the last sentence stops', () async {
    final last = state().sentences.length - 1;
    await controller().skipToSentence(last);
    await controller().nextSentence();
    check(state().activeMessageId).isNull();
    check(state().status).equals(TtsPlaybackStatus.idle);
  });

  test('mp3 file names come from the first words', () {
    check(ReplyMp3Export.fileNameFor("Here's your day: three things.", 'mp3'))
        .equals('Heres-your-day-three-things.mp3');
    check(ReplyMp3Export.extensionFor('audio/wav')).equals('wav');
    check(ReplyMp3Export.extensionFor('audio/mpeg')).equals('mp3');
  });

  test('share as mp3 uses the relay export and its estimate', () async {
    final tmp = await Directory.systemTemp.createTemp('mp3');
    addTearDown(() => tmp.delete(recursive: true));
    Mp3ExportTicket? seen;
    var rendered = false;
    final exported = await ReplyMp3Export(
      startRelayExport: (_) async => Mp3ExportTicket.fromJson({
        'url': 'http://relay/v1/audio/exports/x.mp3?sig=1',
        'estimate': {'audio_s': 75, 'render_s': 125},
      }),
      download: (url) async => Uint8List.fromList([1, 2, 3]),
      render: (_) async {
        rendered = true;
        return (bytes: Uint8List(0), mimeType: 'audio/mpeg');
      },
      tempDirectory: () async => tmp,
    ).export('A long reply.', onEstimate: (t) => seen = t);
    check(rendered).isFalse();
    check(seen?.renderSeconds).equals(125);
    check(ReplyMp3Export.etaWords(seen?.renderSeconds)).equals('about 2 min');
    check(exported.file.readAsBytesSync().length).equals(3);
    check(exported.file.path.endsWith('.mp3')).isTrue();
  });

  test('an older relay without the export falls back to one render', () async {
    final tmp = await Directory.systemTemp.createTemp('mp3');
    addTearDown(() => tmp.delete(recursive: true));
    final exported = await ReplyMp3Export(
      startRelayExport: (_) async => null,
      render: (_) async =>
          (bytes: Uint8List.fromList([9, 9]), mimeType: 'audio/mpeg'),
      tempDirectory: () async => tmp,
    ).export('Short reply.');
    check(exported.file.readAsBytesSync().length).equals(2);
    check(ReplyMp3Export.etaWords(40)).equals('about 40 s');
  });

  test('the sweep removes shared files older than a day only', () async {
    final tmp = await Directory.systemTemp.createTemp('mp3');
    addTearDown(() => tmp.delete(recursive: true));
    final kept = Directory('${tmp.path}/1')..createSync();
    File('${kept.path}/a.mp3').writeAsBytesSync([1]);
    await ReplyMp3Export.sweep(tmp);
    check(kept.existsSync()).isTrue();
    await ReplyMp3Export.sweep(
      tmp,
      now: DateTime.now().add(const Duration(hours: 25)),
    );
    check(kept.existsSync()).isFalse();
  });
}
