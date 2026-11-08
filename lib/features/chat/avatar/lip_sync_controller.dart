import 'dart:async';

import 'dart:math' as math;

import 'package:conduit_core/features/chat/server_speech/viseme_timeline.dart';
import 'package:flutter/widgets.dart';

import 'lip_sync.dart';

/// Decides which mouth still the avatar shows while a voice reply plays.
///
/// It listens to the [SpeechLevelMeter], applies the hold, and tells its
/// listeners only when the shape (or the lack of one) changes, so the strip
/// rebuilds a handful of times a second, never per frame. With no stills, the
/// setting off or no voice, [shape] is null and the strip shows what it
/// showed before lip sync existed.
class LipSyncController extends ChangeNotifier {
  LipSyncController({
    SpeechLevelMeter? meter,
    int Function()? clock,
    VisemeStore? visemes,
    math.Random? random,
  }) : _meter = meter ?? SpeechLevelMeter.instance,
       _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch),
       _visemes = visemes ?? VisemeStore.instance,
       _accents = FaceAccents(random: random) {
    _meter.level.addListener(_onLevel);
    _meter.position.addListener(_onLevel);
    _visemes.addListener(_evaluate);
  }

  final SpeechLevelMeter _meter;
  final int Function() _clock;
  final VisemeStore _visemes;
  final FaceAccents _accents;
  final LoudnessRange _range = LoudnessRange();
  final MouthTracker _tracker = MouthTracker();
  int _shapeSinceMs = 0;
  bool _synced = false;

  /// Whether the shape on screen follows a viseme timeline (else loudness).
  bool get followsTimeline => _synced;
  Timer? _timer;
  bool _enabled = true;
  Map<MouthShape, ImageProvider>? _stills;
  MouthShape? _shape;
  bool _disposed = false;

  /// The shape on screen (an extra the persona lacks already replaced by its
  /// fallback), or null for the idle clip.
  MouthShape? get shape => _shape;

  /// The still to show now, or null.
  ImageProvider? get current {
    final shape = _shape;
    final stills = _stills;
    if (shape == null || stills == null) return null;
    return stills[shape];
  }

  /// Whether the stills are loaded.
  bool get hasStills => _stills != null;

  set enabled(bool value) {
    if (_enabled == value) return;
    _enabled = value;
    _evaluate();
  }

  /// Sets the preloaded stills by shape, or null for none. The five core
  /// shapes must all be there; extras are optional.
  void setStills(Map<MouthShape, ImageProvider>? stills) {
    assert(stills == null || kMouthCoreShapes.every(stills.containsKey));
    _stills = stills;
    _evaluate();
  }

  void _onLevel() {
    if (_meter.level.value == null && _meter.position.value == null) {
      _timer?.cancel();
      _timer = null;
    } else {
      // Silence is the absence of readings, so look again without one.
      _timer ??= Timer.periodic(
        const Duration(milliseconds: 150),
        (_) => _evaluate(),
      );
    }
    _evaluate();
  }

  void _evaluate() {
    if (_disposed) return;
    final stills = _stills;
    final now = _clock();
    final level = _meter.level.value;
    final position = _meter.position.value;
    final available = stills?.keys.toSet() ?? const <MouthShape>{};

    // The timeline of the clip playing now, when it has arrived and the
    // player is still reporting its position.
    final timeline =
        position != null && now - position.atMs <= kMouthPositionStaleMs
        ? _visemes[position.visemeId]
        : null;
    final freshLevel =
        level != null && now - level.atMs <= kMouthSilenceTimeoutMs;

    MouthShape? base;
    var loud = false;
    if (!_enabled || stills == null) {
      _tracker.reset();
    } else if (timeline != null) {
      final from = mouthShapeFromName(timeline.shapeAt(position!.posAt(now)));
      if (from != null) {
        _tracker.hold.minHoldMs = kMouthTimelineHoldMs;
        base = _tracker.hold.update(resolveMouthShape(from, available), now);
        _synced = true;
        if (freshLevel) {
          _range.note(position.visemeId, level.rmsDb);
          loud = _range.isTop(level.rmsDb);
        } else {
          loud = base == MouthShape.wide;
        }
      }
    }
    if (base == null && _enabled && stills != null) {
      _synced = false;
      _tracker.hold.minHoldMs = kMouthMinHoldMs;
      base = mouthShapeToShow(
        enabled: true,
        stillsReady: true,
        level: level,
        nowMs: now,
        tracker: _tracker,
      );
      if (base != null && level != null) {
        _range.note(position?.visemeId, level.rmsDb);
        loud = _range.isTop(level.rmsDb);
      }
    }

    MouthShape? next;
    if (base == null || stills == null) {
      _accents.reset();
      _range.reset();
      _synced = false;
    } else {
      final resolved = resolveMouthShape(base, available);
      next = _accents.apply(
        resolved,
        nowMs: now,
        available: available,
        fading: now - _shapeSinceMs < kMouthFadeMs,
        loud: loud,
      );
    }
    if (next != _shape) {
      _shape = next;
      _shapeSinceMs = now;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _meter.level.removeListener(_onLevel);
    _meter.position.removeListener(_onLevel);
    _visemes.removeListener(_evaluate);
    super.dispose();
  }
}
