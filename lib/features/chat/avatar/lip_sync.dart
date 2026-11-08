import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// The drawn mouths of the cartoon lip sync. The first five (closed, slight,
/// open, wide, oo) are the core set every persona with lip sync must ship;
/// mid, ee, fv and mbp are optional extra frames (2026-11-08, build 188).
enum MouthShape { closed, slight, open, wide, oo, mid, ee, fv, mbp }

/// Server names of the stills, in [MouthShape] order.
final List<String> kMouthShapeNames = [
  for (final shape in MouthShape.values) shape.name,
];

/// The five shapes a persona must ship; without all of them there is no lip
/// sync. The extras are used when present.
const List<MouthShape> kMouthCoreShapes = [
  MouthShape.closed,
  MouthShape.slight,
  MouthShape.open,
  MouthShape.wide,
  MouthShape.oo,
];

/// What to draw for an extra shape when the persona does not ship it, so a
/// set of only the core five still works (the build 187 behavior).
const Map<MouthShape, MouthShape> kMouthFallback = {
  MouthShape.mid: MouthShape.slight,
  MouthShape.ee: MouthShape.open,
  MouthShape.fv: MouthShape.slight,
  MouthShape.mbp: MouthShape.closed,
};

/// [wanted] if the persona has it, else its fallback, else the shape itself
/// (core shapes are always there when lip sync is on).
MouthShape resolveMouthShape(MouthShape wanted, Set<MouthShape> available) {
  if (available.contains(wanted)) return wanted;
  return kMouthFallback[wanted] ?? wanted;
}

/// RMS levels (dBFS of the player's output) where the mouth opens a step:
/// closed below [kMouthSlightDb], then slight, mid, open and wide.
/// Measured 2026-11-08 on one Kokoro sentence in 43 ms windows: gaps between
/// words sit below -48 (18% of windows), the 25th, 50th and 75th percentiles
/// of the whole sentence were -35, -28 and -23 dB, the loudest -19. The old
/// slight band (-48 to -36) is split in two at -40; open starts at -32.
const double kMouthSlightDb = -48;
const double kMouthMidDb = -40;
const double kMouthOpenDb = -32;
const double kMouthWideDb = -24;

/// A rounded "oo" mouth is chosen for a mid-loud, low-pitched sound. The
/// native side sends [SpeechLevel.zcrHz], half the zero crossings per second,
/// a rough pitch of the dominant energy; below this the sound is a low vowel
/// such as "oo" or "oh" (the 10th percentile of voiced windows was 260 Hz,
/// the median 530 Hz).
const double kMouthOoMaxHz = 400;

/// A wide flat "ee" smile is chosen for a mid-loud sound at or above this
/// zero-crossing rate but below [kMouthFvMinHz]: a bright vowel. Starting
/// value, not measured on Dean's voice yet (the median voiced window is 530).
const double kMouthEeMinHz = 800;

/// A fricative (f, v, s, th: noise, so very many zero crossings) at low to
/// mid loudness (below [kMouthOpenDb]) shows teeth on the lower lip. Starting
/// value, not measured on Dean's voice yet.
const double kMouthFvMinHz = 1800;

/// A bilabial closure (m, b, p) is a quick dip to near silence right after a
/// loud reading. A near-silent reading within this long of the last
/// mid-or-louder one shows the pressed lips; a longer silence is a plain
/// closed mouth.
const int kMouthMbpWindowMs = 100;

/// The least time a shape stays on screen, so a fast flutter of loudness
/// does not flicker the face (limited animation changes on twos or threes).
/// Was 80 in build 187; readings come every 47 ms, so 70 keeps one step
/// per reading pair.
const int kMouthMinHoldMs = 70;

/// The pressed-lips shape may cut a held shape short after this long, since
/// a real closure is brief and a 70 ms hold would swallow it.
const int kMouthMbpInterruptMs = 40;

/// A change of still fades in over this long, so the shapes do not pop.
const int kMouthFadeMs = 50;

/// No loudness sample for this long means the voice has stopped.
const int kMouthSilenceTimeoutMs = 400;

/// The shape for one loudness reading. [rmsDb] is dBFS (0 loudest, about
/// -100 silence); [zcrHz] is the zero-crossing pitch estimate, when known;
/// [recentlyLoud] says a mid-or-louder reading came within
/// [kMouthMbpWindowMs] (see [MouthTracker]).
///
/// Order of the rules: near silence is closed, or mbp right after sound;
/// a very high zcr at low to mid loudness is fv; from mid to just under wide
/// loudness a low zcr is oo and a high one ee; everything else by loudness.
MouthShape shapeForLevel(
  double rmsDb, {
  double? zcrHz,
  bool recentlyLoud = false,
}) {
  if (rmsDb.isNaN || rmsDb < kMouthSlightDb) {
    return recentlyLoud ? MouthShape.mbp : MouthShape.closed;
  }
  final hz = (zcrHz != null && zcrHz > 0) ? zcrHz : null;
  if (rmsDb < kMouthOpenDb && hz != null && hz >= kMouthFvMinHz) {
    return MouthShape.fv;
  }
  if (rmsDb < kMouthMidDb) return MouthShape.slight;
  if (rmsDb < kMouthWideDb) {
    if (hz != null && hz < kMouthOoMaxHz) return MouthShape.oo;
    if (hz != null && hz >= kMouthEeMinHz && hz < kMouthFvMinHz) {
      return MouthShape.ee;
    }
    return rmsDb < kMouthOpenDb ? MouthShape.mid : MouthShape.open;
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
    final needed = wanted == MouthShape.mbp
        ? math.min(minHoldMs, kMouthMbpInterruptMs)
        : minHoldMs;
    if (wanted != _shape && nowMs - since >= needed) {
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

/// Remembers when the voice was last mid-loud or louder, for the mbp dip.
class MouthTracker {
  final MouthHold hold = MouthHold();
  int? _lastLoudMs;

  /// Whether a mid-or-louder reading came within [kMouthMbpWindowMs] before
  /// [nowMs]; call [note] first for the reading at hand.
  bool recentlyLoud(int nowMs) {
    final last = _lastLoudMs;
    return last != null && nowMs - last <= kMouthMbpWindowMs;
  }

  void note(double rmsDb, int nowMs) {
    if (!rmsDb.isNaN && rmsDb >= kMouthMidDb) _lastLoudMs = nowMs;
  }

  void reset() {
    _lastLoudMs = null;
    hold.reset();
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
/// [stillsReady] is true only when the five core stills are on disk. The
/// shape returned is the wanted one; the caller resolves it against the
/// stills it has ([resolveMouthShape]).
MouthShape? mouthShapeToShow({
  required bool enabled,
  required bool stillsReady,
  required SpeechLevel? level,
  required int nowMs,
  required MouthTracker tracker,
}) {
  if (!enabled || !stillsReady || level == null) {
    tracker.reset();
    return null;
  }
  if (nowMs - level.atMs > kMouthSilenceTimeoutMs) {
    tracker.reset();
    return null;
  }
  // The dip is judged against loudness before this reading.
  final shape = shapeForLevel(
    level.rmsDb,
    zcrHz: level.zcrHz,
    recentlyLoud: tracker.recentlyLoud(level.atMs),
  );
  tracker.note(level.rmsDb, level.atMs);
  return tracker.hold.update(shape, nowMs);
}
