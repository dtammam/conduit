import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/chat/server_speech/fallback_server_speech.dart';
import 'package:conduit_core/features/chat/server_speech/server_speech.dart';
import 'package:conduit_core/ports/progressive_audio.dart';
import 'package:test/test.dart';

final class _Speech implements StreamingServerSpeech {
  _Speech(
    this.source, {
    this.ready = true,
    this.fails = false,
    this.streams = false,
    this.voiceChoice = false,
  });

  @override
  final ServerSpeechSource source;
  final bool ready;
  final bool fails;
  final bool streams;
  final bool voiceChoice;
  final List<String?> voices = [];
  int transcribed = 0;
  int spoken = 0;

  @override
  bool get canTranscribe => ready;

  @override
  bool get canSynthesize => ready;

  @override
  bool get offersVoiceChoice => voiceChoice;

  @override
  bool get streamsSpeech => streams;

  @override
  Future<String> transcribe(
    Uint8List audio, {
    required String fileName,
    required String mimeType,
    String? language,
  }) async {
    transcribed++;
    if (fails) throw StateError('down');
    return source.name;
  }

  @override
  Future<SynthesizedSpeech> synthesize(
    String text, {
    String? preferredVoice,
    double? speed,
  }) async {
    spoken++;
    voices.add(preferredVoice);
    if (fails) throw StateError('down');
    return (bytes: Uint8List.fromList([source.index]), mimeType: 'audio/mpeg');
  }

  @override
  Future<SpeechClip> synthesizeClip(
    String text, {
    String? preferredVoice,
    double? speed,
  }) async {
    spoken++;
    if (fails) throw StateError('down');
    return SpeechClip.progressive(
      ProgressiveAudio(mimeType: 'audio/mpeg')..add([source.index]),
    );
  }
}

Future<String> _hear(ServerSpeechProvider speech) =>
    speech.transcribe(Uint8List(1), fileName: 'a.wav', mimeType: 'audio/wav');

void main() {
  test('uses the Voice provider while it works', () async {
    final primary = _Speech(ServerSpeechSource.direct);
    final fallback = _Speech(ServerSpeechSource.openWebUi);
    final speech = FallbackServerSpeech(primary: primary, fallback: fallback);

    check(await _hear(speech)).equals('direct');
    check((await speech.synthesize('Hi.')).bytes).deepEquals([2]);
    check(fallback.transcribed).equals(0);
    check(fallback.spoken).equals(0);
  });

  test('a failed request goes to the server for that request only', () async {
    final primary = _Speech(ServerSpeechSource.direct, fails: true);
    final fallback = _Speech(ServerSpeechSource.openWebUi);
    final speech = FallbackServerSpeech(primary: primary, fallback: fallback);

    check(await _hear(speech)).equals('openWebUi');
    check((await speech.synthesize('Hi.', preferredVoice: 'v')).bytes)
        .deepEquals([0]);
    check(fallback.voices).deepEquals(['v']);
    check(primary.transcribed).equals(1);
    check(primary.spoken).equals(1);
  });

  test('a Voice provider without the models is skipped', () async {
    final primary = _Speech(ServerSpeechSource.direct, ready: false);
    final fallback = _Speech(ServerSpeechSource.openWebUi, voiceChoice: true);
    final speech = FallbackServerSpeech(primary: primary, fallback: fallback);

    check(await _hear(speech)).equals('openWebUi');
    check(primary.transcribed).equals(0);
    check(speech.source).equals(ServerSpeechSource.openWebUi);
    check(speech.offersVoiceChoice).isTrue();
  });

  test('the voice list is hidden while the Voice provider speaks', () {
    final speech = FallbackServerSpeech(
      primary: _Speech(ServerSpeechSource.direct),
      fallback: _Speech(ServerSpeechSource.openWebUi, voiceChoice: true),
    );

    check(speech.offersVoiceChoice).isFalse();
  });

  test(
    'a streamed clip falls back to a whole one when the stream fails',
    () async {
      final primary = _Speech(
        ServerSpeechSource.direct,
        fails: true,
        streams: true,
      );
      final fallback = _Speech(ServerSpeechSource.openWebUi);
      final speech = FallbackServerSpeech(primary: primary, fallback: fallback);

      check(speech.streamsSpeech).isTrue();
      final clip = await speech.synthesizeClip('Hi.');

      check(clip.progressive).isNull();
      check(clip.whole!.bytes).deepEquals([0]);
    },
  );

  test(
    'a streamed clip passes through when the Voice provider works',
    () async {
      final speech = FallbackServerSpeech(
        primary: _Speech(ServerSpeechSource.direct, streams: true),
        fallback: _Speech(ServerSpeechSource.openWebUi),
      );

      check((await speech.synthesizeClip('Hi.')).progressive).isNotNull();
    },
  );
}
