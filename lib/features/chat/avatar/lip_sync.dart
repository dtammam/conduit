import 'package:flutter/foundation.dart';

/// The five drawn mouths of the cartoon lip sync, quietest first.
enum MouthShape { closed, slight, open, wide, oo }

/// Server names of the stills, in [MouthShape] order.
const List<String> kMouthShapeNames = [
  'closed',
  'slight',
  'open',
  'wide',
  'oo',
];

/// RMS levels (dBFS of the player's output) where the mouth opens a step.
/// Measured 2026-11-08 on one Kokoro sentence in 43 ms windows: gaps between
/// words sit below -48 (18% of windows), the 25th, 50th and 75th percentiles
/// of the whole sentence were -35, -28 and -23 dB, the loudest -19.
const double kMouthSlightDb = -48;
const double kMouthOpenDb = -36;
const double kMouthWideDb = -24;

/// A rounded "oo" mouth is chosen for a mid-loud, low-pitched sound. The
/// native side sends [SpeechLevel.zcrHz], half the zero crossings per second,
/// a rough pitch of the dominant energy; below this the sound is a low vowel
/// such as "oo" or "oh" (the 10th percentile of voiced windows was 260 Hz,
/// the median 530 Hz).
const double kMouthOoMaxHz = 400;

/// The least time a shape stays on screen, so a fast flutter of loudness
/// does not flicker the face (limited animation changes on twos or threes).
const int kMouthMinHoldMs = 80;

/// No loudness sample for this long means the voice has stopped.
const int kMouthSilenceTimeoutMs = 400;

/// The shape for one loudness reading. [rmsDb] is dBFS (0 loudest, about
/// -100 silence); [zcrHz] is the zero-crossing pitch estimate, when known.
MouthShape shapeForLevel(double rmsDb, {double? zcrHz}) {
  if (rmsDb.isNaN || rmsDb < kMouthSlightDb) return MouthShape.closed;
  if (rmsDb < kMouthOpenDb) return MouthShape.slight;
  if (rmsDb < kMouthWideDb) {
    if (zcrHz != null && zcrHz > 0 && zcrHz < kMouthOoMaxHz) {
      return MouthShape.oo;
    }
    return MouthShape.open;
  }
  return MouthShape.wide;
}

/// Keeps a chosen shape for at least [minHoldMs] before it changes.
///
/// Time is passed in, so the logic is the same on the phone and in tests.
class MouthHold {
  MouthHold({this.minHoldMs = kMouthMinHoldMs});

  final int minHoldMs;
  MouthShape _shape = MouthShape.closed;
  int? _since;

  MouthShape get shape => _shape;

  /// Offers the wanted shape at [nowMs]; returns the shape to show.
  MouthShape update(MouthShape wanted, int nowMs) {
    final since = _since;
    if (since == null) {
      _since = nowMs;
      _shape = wanted;
      return _shape;
    }
    if (wanted != _shape && nowMs - since >= minHoldMs) {
      _shape = wanted;
      _since = nowMs;
    }
    return _shape;
  }

  /// Back to a closed mouth with no hold running.
  void reset() {
    _shape = MouthShape.closed;
    _since = null;
  }
}

/// One loudness reading from the player's output.
@immutable
class SpeechLevel {
  const SpeechLevel(this.rmsDb, this.zcrHz, this.atMs);

  final double rmsDb;
  final double? zcrHz;
  final int atMs;
}

/// The latest loudness of the voice that is playing, fed by the native
/// speech engine about 20 times a second and cleared when playback stops.
/// Null means nothing is speaking.
class SpeechLevelMeter {
  SpeechLevelMeter._();

  static final SpeechLevelMeter instance = SpeechLevelMeter._();

  final ValueNotifier<SpeechLevel?> level = ValueNotifier<SpeechLevel?>(null);

  void push(double rmsDb, double? zcrHz, int nowMs) {
    level.value = SpeechLevel(rmsDb, zcrHz, nowMs);
  }

  void clear() {
    if (level.value != null) level.value = null;
  }
}

/// What the avatar should show for the voice right now: the mouth shape, or
/// null when the idle clip should play (no stills, setting off, no voice).
///
/// [stillsReady] is true only when all five stills are on disk.
MouthShape? mouthShapeToShow({
  required bool enabled,
  required bool stillsReady,
  required SpeechLevel? level,
  required int nowMs,
  required MouthHold hold,
}) {
  if (!enabled || !stillsReady || level == null) {
    hold.reset();
    return null;
  }
  if (nowMs - level.atMs > kMouthSilenceTimeoutMs) {
    hold.reset();
    return null;
  }
  return hold.update(shapeForLevel(level.rmsDb, zcrHz: level.zcrHz), nowMs);
}
