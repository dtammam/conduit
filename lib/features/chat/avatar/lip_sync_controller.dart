import 'dart:async';

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
  LipSyncController({SpeechLevelMeter? meter, int Function()? clock})
    : _meter = meter ?? SpeechLevelMeter.instance,
      _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch) {
    _meter.level.addListener(_onLevel);
  }

  final SpeechLevelMeter _meter;
  final int Function() _clock;
  final MouthTracker _tracker = MouthTracker();
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
    if (_meter.level.value == null) {
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
    final wanted = mouthShapeToShow(
      enabled: _enabled,
      stillsReady: stills != null,
      level: _meter.level.value,
      nowMs: _clock(),
      tracker: _tracker,
    );
    final next = wanted == null || stills == null
        ? null
        : resolveMouthShape(wanted, stills.keys.toSet());
    if (next != _shape) {
      _shape = next;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _meter.level.removeListener(_onLevel);
    super.dispose();
  }
}
