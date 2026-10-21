/// Hearing the user start to talk over the assistant.
///
/// A voice call with server speech recognition keeps its microphone open
/// while the assistant speaks. The platform's echo cancellation takes most of
/// the assistant's own voice out of that signal; what is left is judged here,
/// on loudness alone, so the assistant is interrupted when the user starts
/// speaking rather than when a transcript comes back.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:conduit_core/voice/voice_events.dart';

/// Cuts 16-bit little-endian mono PCM into fixed frames and reports each
/// frame's loudness.
class Pcm16LevelMeter {
  Pcm16LevelMeter({required this.sampleRate, this.frameSamples = 512});

  final int sampleRate;
  final int frameSamples;

  int? _carryByte;
  int _frameFill = 0;
  double _sumSquares = 0;

  Duration get frameDuration =>
      Duration(microseconds: frameSamples * 1000000 ~/ sampleRate);

  /// Adds [bytes] and returns the levels of the frames they completed.
  List<VoiceCaptureLevel> add(Uint8List bytes) {
    final levels = <VoiceCaptureLevel>[];
    var index = 0;
    final carry = _carryByte;
    if (carry != null && bytes.isNotEmpty) {
      _addSample(_toInt16(carry, bytes[0]), levels);
      _carryByte = null;
      index = 1;
    }
    for (; index + 1 < bytes.length; index += 2) {
      _addSample(_toInt16(bytes[index], bytes[index + 1]), levels);
    }
    if (index < bytes.length) {
      _carryByte = bytes[index];
    }
    return levels;
  }

  void reset() {
    _carryByte = null;
    _frameFill = 0;
    _sumSquares = 0;
  }

  static int _toInt16(int low, int high) {
    final value = low | (high << 8);
    return value >= 0x8000 ? value - 0x10000 : value;
  }

  void _addSample(int sample, List<VoiceCaptureLevel> levels) {
    final normalized = sample / 32768.0;
    _sumSquares += normalized * normalized;
    _frameFill++;
    if (_frameFill < frameSamples) return;
    final rms = math.sqrt(_sumSquares / frameSamples);
    levels.add(VoiceCaptureLevel(dbfs: dbfsOf(rms), duration: frameDuration));
    _frameFill = 0;
    _sumSquares = 0;
  }

  /// The level of an RMS amplitude, floored at -100 dBFS for silence.
  static double dbfsOf(double rms) {
    if (rms <= 0.00001) return -100;
    return 20 * math.log(rms) / math.ln10;
  }
}

/// Decides when the microphone held open during the assistant's speech has
/// heard the user start talking.
///
/// It keeps a running noise floor: it drops at once to anything quieter and
/// climbs slowly towards anything louder, so the steady residue of the
/// assistant's voice that echo cancellation leaves behind becomes part of the
/// floor. Speech is a level at least [marginDb] above that floor (and above
/// [minThresholdDb]) held for [sustain], allowing dips of up to [maxGap]
/// between syllables. Nothing counts until [arm] has been called (playback
/// started) and [grace] has passed, the stretch where the echo canceller is
/// still adapting and the floor learns the room fast.
class BargeInOnsetDetector {
  BargeInOnsetDetector({
    this.grace = defaultGrace,
    this.sustain = defaultSustain,
    this.maxGap = defaultMaxGap,
    this.preRoll = defaultPreRoll,
    this.marginDb = defaultMarginDb,
    this.minThresholdDb = defaultMinThresholdDb,
  });

  static const Duration defaultGrace = Duration(milliseconds: 300);
  static const Duration defaultSustain = Duration(milliseconds: 250);
  static const Duration defaultMaxGap = Duration(milliseconds: 100);
  static const Duration defaultPreRoll = Duration(milliseconds: 500);
  static const double defaultMarginDb = 12;
  static const double defaultMinThresholdDb = -50;

  /// How fast the floor climbs towards louder frames, per frame, during the
  /// grace period and after it.
  static const double _graceRise = 0.25;
  static const double _steadyRise = 0.02;

  /// How fast the floor falls towards quieter frames, per frame.
  static const double _fall = 0.5;

  final Duration grace;
  final Duration sustain;
  final Duration maxGap;

  /// How much audio from before the onset the next recording keeps, so it
  /// holds the start of what the user said.
  final Duration preRoll;
  final double marginDb;
  final double minThresholdDb;

  double? _floorDb;
  bool _armed = false;
  bool _fired = false;
  Duration _sinceArmed = Duration.zero;
  Duration _candidateSpan = Duration.zero;
  Duration _candidateAbove = Duration.zero;
  Duration _candidateGap = Duration.zero;

  bool get isArmed => _armed && !_fired;

  /// The level a frame needs to count as speech.
  double get thresholdDb =>
      math.max((_floorDb ?? minThresholdDb) + marginDb, minThresholdDb);

  /// Playback started: the grace period runs from here. Arming again does
  /// nothing, so the grace period happens once per assistant turn.
  void arm() {
    if (_armed) return;
    _armed = true;
    _sinceArmed = Duration.zero;
    _resetCandidate();
  }

  /// Adds one frame. Returns how far back from now the user's speech began,
  /// pre-roll included, the first time an onset is heard; null otherwise.
  Duration? add(VoiceCaptureLevel level) {
    if (_fired) return null;
    final floor = _floorDb;
    if (floor == null) {
      _floorDb = level.dbfs;
      return null;
    }

    final inGrace = !_armed || _sinceArmed < grace;
    if (_armed) _sinceArmed += level.duration;
    final above = level.dbfs >= thresholdDb;

    if (inGrace) {
      _resetCandidate();
      _track(level.dbfs, rise: _graceRise);
      return null;
    }

    if (above) {
      _candidateSpan += level.duration;
      _candidateAbove += level.duration;
      _candidateGap = Duration.zero;
      if (_candidateAbove >= sustain) {
        _fired = true;
        final lookback = _candidateSpan + preRoll;
        _resetCandidate();
        return lookback;
      }
      return null;
    }

    if (_candidateAbove > Duration.zero) {
      _candidateSpan += level.duration;
      _candidateGap += level.duration;
      if (_candidateGap <= maxGap) return null;
      _resetCandidate();
    }
    _track(level.dbfs, rise: _steadyRise);
    return null;
  }

  void _track(double dbfs, {required double rise}) {
    final floor = _floorDb ?? dbfs;
    final rate = dbfs < floor ? _fall : rise;
    _floorDb = floor + (dbfs - floor) * rate;
  }

  void _resetCandidate() {
    _candidateSpan = Duration.zero;
    _candidateAbove = Duration.zero;
    _candidateGap = Duration.zero;
  }
}
