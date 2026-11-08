import 'dart:async';
import 'dart:typed_data';

import 'package:conduit_core/conduit_core.dart';
import 'package:conduit_core/features/chat/voice_mode/voice_call_socket.dart';

import 'engine_speech_playback.dart';
import 'engine_voice_capture.dart';

/// The speaker of a voice socket call: PCM16 24 kHz parts queued on the native
/// speech engine (`SpeechEngineQueue.swift`, `appendPcm16`), one gapless
/// waveform, on the same engine that cancels echo for the microphone.
class EngineVoiceCallPlayer implements VoiceCallPlayerPort {
  EngineVoiceCallPlayer({EngineSpeechPlayback? engine})
    : _engine = engine ?? EngineSpeechPlayback() {
    _engine.claimEvents();
    _subs
      ..add(
        _engine.currentIndexChanges.listen((i) {
          if (i != null) _events.add(VoicePlayerStarted(i));
        }),
      )
      ..add(
        _engine.stateChanges.listen((s) {
          if (s.processingState == AudioProcessingState.completed) {
            _events.add(const VoicePlayerDrained());
          }
        }),
      );
  }

  final EngineSpeechPlayback _engine;
  final _events = StreamController<VoicePlayerEvent>.broadcast();
  final _subs = <StreamSubscription<Object?>>[];

  @override
  Stream<VoicePlayerEvent> get events => _events.stream;

  @override
  Stream<Object> get failures => _engine.failures;

  @override
  Future<void> reset() => _engine.resetQueue();

  @override
  Future<void> appendPcm(int part, Uint8List pcm, {bool isLast = false}) =>
      _engine.appendPcm(part, pcm, isLast: isLast);

  @override
  Future<void> play() => _engine.play();

  @override
  Future<void> stop() => _engine.stop();

  @override
  Future<void> setGain(double gain, {Duration ramp = Duration.zero}) async {
    await _engine.setDuck(gain, ramp: ramp);
  }

  @override
  Future<({int part, int posMs})?> position() async {
    final p = await _engine.playbackPosition();
    return p == null ? null : (part: p.item, posMs: p.posMs);
  }

  @override
  void bindViseme(int part, String? visemeId) =>
      _engine.bindViseme(part, visemeId);

  @override
  Future<void> dispose() async {
    for (final sub in _subs) {
      await sub.cancel();
    }
    _subs.clear();
    await _events.close();
    _engine.releaseEvents();
  }
}

/// The microphone of a voice socket call: PCM16 16 kHz on the speech engine
/// with voice processing on (echo cancelled against the assistant's own
/// playback), or `record` if the engine cannot.
class EngineVoiceCallMic implements VoiceCallMicPort {
  EngineVoiceCallMic({AudioCapturePort? capture})
    : _capture = capture ?? AudioCapturePort.hostFactory();

  final AudioCapturePort _capture;

  @override
  Future<Stream<Uint8List>> start() async {
    await _capture.manageIosAudioSession(false);
    return _capture.startStream(
      const AudioCaptureConfig(
        profile: AudioCaptureProfile.voiceCall,
        sampleRate: voiceSocketMicRate,
      ),
    );
  }

  @override
  Future<void> stop() async {
    await _capture.stop();
    await EngineVoiceCapture.endCall();
  }
}
