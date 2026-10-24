import 'dart:async';

import 'package:conduit_core/conduit_core.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:flutter/services.dart';

import 'engine_speech_playback.dart';
import 'record_audio_capture.dart';

/// The iOS microphone for voice calls, taken from the speech engine that
/// plays the assistant (`SpeechEngineQueue.swift`).
///
/// Apple's voice processing cancels echo only of audio played through the
/// same engine. With the call's microphone on the engine that also plays the
/// assistant, the canceller has the assistant's voice as its reference, so
/// much less of it reaches barge-in (2026-10-24: echo through the speaker and
/// in the car kept interrupting). While a call's capture runs here, the
/// assistant's clips all play on that engine too ([HybridSpeechPlayback]).
///
/// Only voice-call captures come here; dictation stays on `record`. An engine
/// error hands this capture, and every later one in the same call, to
/// `record`; the next call tries the engine again ([endCall] clears it).
/// With [engineEnabled] off (the setting) every call records through `record`.
class EngineVoiceCapture implements AudioCapturePort {
  EngineVoiceCapture({
    AudioCapturePort? fallback,
    MethodChannel? channel,
    EventChannel? audio,
  }) : _fallback = fallback ?? RecordAudioCapture(),
       _channel =
           channel ?? const MethodChannel(EngineSpeechPlayback.channelName),
       _audio = audio ?? const EventChannel(captureChannelName);

  static const captureChannelName =
      'app.cogwheel.conduit/speech_engine_capture';

  final AudioCapturePort _fallback;
  final MethodChannel _channel;
  final EventChannel _audio;
  bool _usingEngine = false;

  /// Whether a voice call's capture runs on the engine with voice processing
  /// on; the assistant's playback then goes to the same engine.
  static bool voiceProcessingActive = false;

  /// Set after the engine failed to capture; `record` for the rest of the
  /// call. [endCall] clears it, so the next call tries the engine again.
  static bool disabled = false;

  /// Whether voice calls may capture on the engine at all (the "Echo
  /// cancellation on the speech engine" setting, set before a call's capture
  /// starts). Off, a call records through `record` and the engine plays
  /// without voice processing.
  static bool engineEnabled = true;

  /// Engine failures handed to `record` in this call, for the diagnostics.
  static int fallbacks = 0;

  /// Which path this call's capture took: `engine`, `record` (setting off)
  /// or `record-fallback`; null until a call's capture starts.
  static String? callPath;

  @override
  Future<bool> hasPermission() => _fallback.hasPermission();

  @override
  Future<void> manageIosAudioSession(bool manage) =>
      _fallback.manageIosAudioSession(manage);

  @override
  Future<Stream<Uint8List>> startStream(AudioCaptureConfig config) async {
    final voiceCall =
        config.profile == AudioCaptureProfile.voiceCall &&
        config.channels == 1 &&
        config.bitRate == 16;
    if (!voiceCall) return _fallback.startStream(config);
    if (disabled || !engineEnabled) {
      final first = callPath == null;
      callPath ??= disabled ? 'record-fallback' : 'record';
      if (first) await _logDiagnostics(_channel, 'call-start');
      return _fallback.startStream(config);
    }
    try {
      await _logDiagnostics(_channel, 'call-reset', reset: true, log: false);
      await _channel.invokeMethod<Object?>('setVoiceProcessing', {
        'on': config.echoCancel,
      });
      voiceProcessingActive = config.echoCancel;
      final stream = _audio.receiveBroadcastStream().map(
        (event) => event is Uint8List ? event : Uint8List(0),
      );
      await _channel.invokeMethod<Object?>('startCapture', {
        'sampleRate': config.sampleRate.toDouble(),
      });
      _usingEngine = true;
      callPath = 'engine';
      await _logDiagnostics(_channel, 'call-start');
      DebugLogger.info(
        'voice-engine-capture',
        scope: 'voice/engine',
        data: {'echoCancel': config.echoCancel},
      );
      return stream;
    } catch (error) {
      DebugLogger.warning(
        'voice-engine-capture-fallback',
        scope: 'voice/engine',
        data: {'error': error.toString()},
      );
      fallbacks += 1;
      await _logNative(
        _channel,
        'capture fallback to record (#$fallbacks): $error',
      );
      await endCall(channel: _channel, endsCall: false);
      disabled = true;
      callPath = 'record-fallback';
      return _fallback.startStream(config);
    }
  }

  @override
  Future<void> stop() async {
    if (!_usingEngine) return _fallback.stop();
    _usingEngine = false;
    try {
      await _channel.invokeMethod<Object?>('stopCapture');
    } catch (_) {}
  }

  @override
  Future<void> dispose() => _fallback.dispose();

  /// The call is over: microphone off the engine and voice processing off,
  /// so other playback goes back to the plain media path. The next call tries
  /// the engine again. [endsCall] false only cleans up after a failed engine
  /// capture inside a call.
  static Future<void> endCall({
    MethodChannel? channel,
    bool endsCall = true,
  }) async {
    final engine =
        channel ?? const MethodChannel(EngineSpeechPlayback.channelName);
    final wasActive = voiceProcessingActive;
    voiceProcessingActive = false;
    if (endsCall) {
      if (callPath != null) {
        await _logDiagnostics(engine, 'call-end', reset: true);
      }
      disabled = false;
      fallbacks = 0;
      callPath = null;
    }
    if (!wasActive) return;
    try {
      await engine.invokeMethod<Object?>('stopCapture');
      await engine.invokeMethod<Object?>('setVoiceProcessing', {'on': false});
    } catch (_) {}
  }

  /// What the engine and the audio session look like, and how often the engine
  /// was reconfigured since the last reset: configuration changes, the
  /// recoveries they caused, voice processing toggles, the hardware sample
  /// rate and IO buffer, the route, and the player format against the
  /// engine's own. The native side also writes it to the unified log
  /// (subsystem app.cogwheel.conduit, category voice-engine), which release
  /// builds keep. Never throws.
  static Future<void> _logDiagnostics(
    MethodChannel channel,
    String phase, {
    bool reset = false,
    bool log = true,
  }) async {
    try {
      final result = await channel.invokeMapMethod<String, Object?>(
        'diagnostics',
        {
          'reset': reset,
          'extra': {
            'phase': phase,
            'capturePath': callPath ?? 'none',
            'captureFallbacks': fallbacks,
            'engineSettingOn': engineEnabled,
          },
        },
      );
      if (log) {
        DebugLogger.info(
          'voice-engine-diagnostics',
          scope: 'voice/engine',
          data: {'phase': phase, ...?result},
        );
      }
    } catch (_) {}
  }

  static Future<void> _logNative(MethodChannel channel, String message) async {
    try {
      await channel.invokeMethod<Object?>('log', {'message': message});
    } catch (_) {}
  }
}
