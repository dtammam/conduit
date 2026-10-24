import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit/platform/engine_speech_playback.dart';
import 'package:conduit/platform/engine_voice_capture.dart';
import 'package:conduit_core/conduit_core.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _Record implements AudioCapturePort {
  final calls = <String>[];
  @override
  Future<bool> hasPermission() async => true;
  @override
  Future<void> manageIosAudioSession(bool manage) async {}
  @override
  Future<Stream<Uint8List>> startStream(AudioCaptureConfig config) async {
    calls.add('record ${config.profile.name}');
    return const Stream.empty();
  }

  @override
  Future<void> stop() async => calls.add('record stop');
  @override
  Future<void> dispose() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(EngineSpeechPlayback.channelName);
  late List<String> calls;
  var failOn = '';

  setUp(() {
    calls = <String>[];
    failOn = '';
    EngineVoiceCapture.disabled = false;
    EngineVoiceCapture.engineEnabled = true;
    EngineVoiceCapture.fallbacks = 0;
    EngineVoiceCapture.callPath = null;
    EngineVoiceCapture.voiceProcessingActive = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          final args = call.arguments as Map?;
          // Diagnostics are read-only and not part of the capture sequence.
          if (call.method == 'diagnostics' || call.method == 'log') {
            return <String, Object?>{};
          }
          calls.add(
            call.method == 'setVoiceProcessing'
                ? 'vp ${args!['on']}'
                : call.method == 'startCapture'
                ? 'capture ${args!['sampleRate']}'
                : call.method,
          );
          if (call.method == failOn) {
            throw PlatformException(code: 'speech_engine', message: 'probe');
          }
          return true;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  const call = AudioCaptureConfig(profile: AudioCaptureProfile.voiceCall);
  const dictation = AudioCaptureConfig(profile: AudioCaptureProfile.dictation);

  test('a voice call captures on the engine with voice processing', () async {
    final record = _Record();
    final capture = EngineVoiceCapture(fallback: record);
    await capture.startStream(call);
    check(calls).deepEquals(['vp true', 'capture 16000.0']);
    check(EngineVoiceCapture.voiceProcessingActive).isTrue();
    await capture.stop();
    check(calls.last).equals('stopCapture');
    check(record.calls).isEmpty();

    await EngineVoiceCapture.endCall();
    check(calls.sublist(calls.length - 2))
        .deepEquals(['stopCapture', 'vp false']);
    check(EngineVoiceCapture.voiceProcessingActive).isFalse();
  });

  test('dictation stays on record', () async {
    final record = _Record();
    await EngineVoiceCapture(fallback: record).startStream(dictation);
    check(record.calls).deepEquals(['record dictation']);
    check(calls).isEmpty();
  });

  test(
    'an engine error falls back to record for the rest of the call',
    () async {
      failOn = 'startCapture';
      final record = _Record();
      final capture = EngineVoiceCapture(fallback: record);
      await capture.startStream(call);
      check(record.calls).deepEquals(['record voiceCall']);
      check(EngineVoiceCapture.disabled).isTrue();
      check(EngineVoiceCapture.fallbacks).equals(1);
      check(EngineVoiceCapture.voiceProcessingActive).isFalse();
      calls.clear();
      await capture.startStream(call);
      check(calls).isEmpty();
      check(record.calls.last).equals('record voiceCall');
    },
  );

  test('the next call tries the engine again', () async {
    failOn = 'startCapture';
    final record = _Record();
    await EngineVoiceCapture(fallback: record).startStream(call);
    check(EngineVoiceCapture.disabled).isTrue();

    await EngineVoiceCapture.endCall();
    check(EngineVoiceCapture.disabled).isFalse();
    check(EngineVoiceCapture.fallbacks).equals(0);

    failOn = '';
    calls.clear();
    await EngineVoiceCapture(fallback: record).startStream(call);
    check(calls).deepEquals(['vp true', 'capture 16000.0']);
    check(EngineVoiceCapture.callPath).equals('engine');
  });

  test('with the setting off a call records through record', () async {
    EngineVoiceCapture.engineEnabled = false;
    final record = _Record();
    await EngineVoiceCapture(fallback: record).startStream(call);
    check(record.calls).deepEquals(['record voiceCall']);
    check(calls).isEmpty();
    check(EngineVoiceCapture.voiceProcessingActive).isFalse();
    check(EngineVoiceCapture.callPath).equals('record');
  });
}
