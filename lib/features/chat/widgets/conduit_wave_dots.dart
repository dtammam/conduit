import 'dart:async';

import 'package:flutter/widgets.dart';

/// Conduit's smooth streaming mark, an opt-in alternative to
/// `ConduitStreamingOrbit`.
///
/// Three dots rise and settle in turn, like a soft wave. One controller
/// drives a painter through `repaint:`, so each frame repaints the dots
/// inside the caller's repaint boundary without rebuilding widgets or
/// changing layout. The box keeps the orbit's 28 px height so swapping the
/// two never moves the transcript.
///
/// Unlike the orbit, the wave asks for frames continuously. With [paced]
/// on it steps on a [pacedFrameInterval] timer instead of every display
/// refresh and skips the part of the cycle where all three dots rest, which
/// keeps the frame cost bounded while text streams beside it.
class ConduitWaveDots extends StatefulWidget {
  const ConduitWaveDots({
    super.key,
    required this.color,
    this.height = 28,
    this.animate = true,
    this.paced = false,
  });

  final Color color;
  final double height;
  final bool animate;

  /// Whether to step the wave on a timer rather than on every display frame.
  final bool paced;

  /// How often a paced wave repaints.
  static const Duration pacedFrameInterval = Duration(milliseconds: 33);

  /// The natural width of the three dots and their gaps.
  static const double width =
      ConduitWaveDotsPainter.dotCount * ConduitWaveDotsPainter.dotDiameter +
      (ConduitWaveDotsPainter.dotCount - 1) * ConduitWaveDotsPainter.dotGap;

  @override
  State<ConduitWaveDots> createState() => _ConduitWaveDotsState();
}

class _ConduitWaveDotsState extends State<ConduitWaveDots>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: ConduitWaveDotsPainter.cycle,
  );
  Timer? _paceTimer;
  double _paceStart = 0;
  double _pacePosition = 0;
  bool _tickerModeEnabled = true;
  bool _appForeground = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _appForeground = _isForeground(WidgetsBinding.instance.lifecycleState);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tickerModeEnabled = TickerMode.valuesOf(context).enabled;
    _syncController();
  }

  @override
  void didUpdateWidget(covariant ConduitWaveDots oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.animate != oldWidget.animate ||
        widget.paced != oldWidget.paced) {
      _syncController();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final appForeground = _isForeground(state);
    if (_appForeground == appForeground) return;
    _appForeground = appForeground;
    _syncController();
  }

  bool _isForeground(AppLifecycleState? state) =>
      state == null ||
      state == AppLifecycleState.resumed ||
      state == AppLifecycleState.inactive;

  /// Runs the wave only while it is wanted and the app is in front. A
  /// disabled [TickerMode] mutes the controller's ticker on its own; the
  /// paced timer checks it here.
  void _syncController() {
    if (!widget.animate || !_appForeground) {
      _stopPacing();
      _controller
        ..stop()
        ..value = 0;
      return;
    }
    if (widget.paced) {
      if (_controller.isAnimating) _controller.stop();
      if (_tickerModeEnabled) {
        _startPacing();
      } else {
        _stopPacing();
      }
      return;
    }
    _stopPacing();
    if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  void _startPacing() {
    if (_paceTimer != null) return;
    _paceStart = _controller.value;
    _pacePosition = _paceStart;
    _paceTimer = Timer.periodic(ConduitWaveDots.pacedFrameInterval, _paceTick);
  }

  /// Stops the timer and leaves the controller where the wave really is, so
  /// a switch back to display-rate frames continues without a jump.
  void _stopPacing() {
    final timer = _paceTimer;
    if (timer == null) return;
    timer.cancel();
    _paceTimer = null;
    _controller.value = _pacePosition;
  }

  void _paceTick(Timer timer) {
    final elapsed = ConduitWaveDots.pacedFrameInterval * timer.tick;
    final next =
        (_paceStart +
            elapsed.inMicroseconds /
                ConduitWaveDotsPainter.cycle.inMicroseconds) %
        1.0;
    final previous = _pacePosition;
    _pacePosition = next;
    // While every dot rests the painted frame would not change.
    if (ConduitWaveDotsPainter.isRestingAt(previous) &&
        ConduitWaveDotsPainter.isRestingAt(next)) {
      return;
    }
    _controller.value = next;
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: ConduitWaveDots.width,
      height: widget.height,
      child: CustomPaint(
        key: const ValueKey<String>('conduit-wave-dots'),
        painter: ConduitWaveDotsPainter(
          color: widget.color,
          progress: widget.animate ? _controller : null,
        ),
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _paceTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }
}

/// Where one dot sits and how strongly it shows at a moment of the cycle.
@immutable
class ConduitWaveDot {
  const ConduitWaveDot({required this.dy, required this.opacity});

  /// Vertical offset from the resting line; negative is up.
  final double dy;

  /// Multiplier on the base color's alpha.
  final double opacity;
}

@visibleForTesting
class ConduitWaveDotsPainter extends CustomPainter {
  ConduitWaveDotsPainter({required this.color, this.progress})
    : super(repaint: progress);

  static const int dotCount = 3;
  static const double dotDiameter = 7;
  static const double dotGap = 5;
  static const double rise = 5;
  static const Duration cycle = Duration(milliseconds: 1300);
  static const Duration stagger = Duration(milliseconds: 150);
  static const double restOpacity = 0.45;
  static const double staticOpacity = 0.6;
  static const Curve _ease = Cubic(0.45, 0, 0.55, 1);

  final Color color;

  /// The cycle position from 0 to 1, or null for static dots.
  final Animation<double>? progress;

  /// The state of dot [index] at cycle position [t], with each later dot
  /// trailing the one before it by [stagger].
  static ConduitWaveDot dotAt(int index, double t) {
    final offset =
        index * stagger.inMicroseconds / cycle.inMicroseconds.toDouble();
    final phase = (t - offset) % 1.0;
    if (phase < 0.3) {
      final f = _ease.transform(phase / 0.3);
      return ConduitWaveDot(
        dy: -rise * f,
        opacity: restOpacity + (1 - restOpacity) * f,
      );
    }
    if (phase < 0.6) {
      final f = _ease.transform((phase - 0.3) / 0.3);
      return ConduitWaveDot(
        dy: -rise * (1 - f),
        opacity: 1 - (1 - restOpacity) * f,
      );
    }
    return const ConduitWaveDot(dy: 0, opacity: restOpacity);
  }

  /// Whether every dot sits on the resting line at cycle position [t].
  static bool isRestingAt(double t) {
    for (var index = 0; index < dotCount; index += 1) {
      final dot = dotAt(index, t);
      if (dot.dy != 0 || dot.opacity != restOpacity) return false;
    }
    return true;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final t = progress?.value;
    final centerY = size.height / 2;
    const radius = dotDiameter / 2;
    final paint = Paint();
    for (var index = 0; index < dotCount; index += 1) {
      final dot = t == null
          ? const ConduitWaveDot(dy: 0, opacity: staticOpacity)
          : dotAt(index, t);
      paint.color = color.withValues(alpha: color.a * dot.opacity);
      canvas.drawCircle(
        Offset(radius + index * (dotDiameter + dotGap), centerY + dot.dy),
        radius,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant ConduitWaveDotsPainter oldDelegate) {
    return color != oldDelegate.color || progress != oldDelegate.progress;
  }
}
