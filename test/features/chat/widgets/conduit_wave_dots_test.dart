import 'package:checks/checks.dart';
import 'package:conduit/features/chat/widgets/conduit_wave_dots.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

const _color = Color(0xFF3355AA);

final _dots = find.byKey(const ValueKey<String>('conduit-wave-dots'));

ConduitWaveDotsPainter _painter(WidgetTester tester) {
  return tester.widget<CustomPaint>(_dots).painter! as ConduitWaveDotsPainter;
}

double? _progress(WidgetTester tester) => _painter(tester).progress?.value;

Widget _harness({
  bool animate = true,
  bool tickerEnabled = true,
  bool paced = false,
}) {
  return Directionality(
    textDirection: TextDirection.ltr,
    child: TickerMode(
      enabled: tickerEnabled,
      child: Center(
        child: ConduitWaveDots(color: _color, animate: animate, paced: paced),
      ),
    ),
  );
}

/// The x of dot [index]'s center: 7 px dots with 5 px gaps.
double _dotX(int index) => 3.5 + index * 12;

/// The cycle position after [ticks] paced frames.
double _pacedAt(int ticks) => (ticks * 33 / 1300) % 1.0;

void main() {
  test('dots rise 5 px at 30% of their own phase and rest from 60%', () {
    final first = ConduitWaveDotsPainter.dotAt(0, 0);
    check(first.dy).equals(0);
    check(first.opacity).isCloseTo(0.45, 1e-9);

    final halfway = ConduitWaveDotsPainter.dotAt(0, 0.15);
    check(halfway.dy).isCloseTo(-2.5, 1e-6);
    check(halfway.opacity).isCloseTo(0.725, 1e-6);

    final peak = ConduitWaveDotsPainter.dotAt(0, 0.3);
    check(peak.dy).isCloseTo(-5, 1e-6);
    check(peak.opacity).isCloseTo(1, 1e-6);

    final falling = ConduitWaveDotsPainter.dotAt(0, 0.45);
    check(falling.dy).isCloseTo(-2.5, 1e-6);

    for (final t in <double>[0.6, 0.8, 0.999]) {
      final rest = ConduitWaveDotsPainter.dotAt(0, t);
      check(because: 't=$t', rest.dy).equals(0);
      check(because: 't=$t', rest.opacity).isCloseTo(0.45, 1e-9);
    }
  });

  test('later dots trail by 150 ms and 300 ms of the same cycle', () {
    const step = 150 / 1300;
    // Cubic is solved numerically, so the peak lands within a hair of 5 px.
    check(ConduitWaveDotsPainter.dotAt(1, 0.3 + step).dy).isCloseTo(-5, 1e-3);
    check(ConduitWaveDotsPainter.dotAt(2, 0.3 + 2 * step).dy)
        .isCloseTo(-5, 1e-3);
    // At the start of the cycle the trailing dots still rest, so the wave
    // opens on a flat row.
    check(ConduitWaveDotsPainter.dotAt(1, 0).dy).equals(0);
    check(ConduitWaveDotsPainter.dotAt(2, 0).dy).equals(0);
    // While the first dot peaks the second is higher than the third, which
    // has only just started to rise.
    final second = ConduitWaveDotsPainter.dotAt(1, 0.3).dy;
    final third = ConduitWaveDotsPainter.dotAt(2, 0.3).dy;
    check(second)
      ..isGreaterThan(-5)
      ..isLessThan(0);
    check(third)
      ..isGreaterThan(second)
      ..isLessThan(0);
  });

  test('the row rests from the last dot settling to the end of the cycle', () {
    const lastSettles = 0.6 + 2 * 150 / 1300;
    check(ConduitWaveDotsPainter.isRestingAt(0)).isTrue();
    check(ConduitWaveDotsPainter.isRestingAt(lastSettles - 0.01)).isFalse();
    check(ConduitWaveDotsPainter.isRestingAt(lastSettles + 0.01)).isTrue();
    check(ConduitWaveDotsPainter.isRestingAt(0.999)).isTrue();
    check(ConduitWaveDotsPainter.isRestingAt(0.01)).isFalse();
  });

  testWidgets('keeps the 28 px box at the natural width of three dots', (
    tester,
  ) async {
    await tester.pumpWidget(_harness(animate: false));

    check(tester.getSize(find.byType(ConduitWaveDots)))
        .equals(const Size(31, 28));
    check(ConduitWaveDots.width).equals(31);
  });

  testWidgets('paints three static dots without a ticker when not animated', (
    tester,
  ) async {
    await tester.pumpWidget(_harness(animate: false));

    check(_painter(tester).progress).isNull();
    check(_painter(tester).color).equals(_color);
    check(tester.binding.transientCallbackCount).equals(0);
    final staticColor = _color.withValues(alpha: 0.6);
    expect(
      tester.renderObject(_dots),
      paints
        ..circle(x: _dotX(0), y: 14, radius: 3.5, color: staticColor)
        ..circle(x: _dotX(1), y: 14, radius: 3.5, color: staticColor)
        ..circle(x: _dotX(2), y: 14, radius: 3.5, color: staticColor),
    );
    check(find.byType(AnimatedBuilder).evaluate()).isEmpty();
  });

  testWidgets('one controller repaints the dots through the cycle', (
    tester,
  ) async {
    await tester.pumpWidget(_harness());
    check(_progress(tester)).equals(0);

    // 390 ms is 30% of the cycle: the first dot is at its peak.
    await tester.pump(const Duration(milliseconds: 390));
    check(_progress(tester)!).isCloseTo(0.3, 1e-6);
    expect(
      tester.renderObject(_dots),
      paints
        ..circle(x: _dotX(0), y: 9, radius: 3.5, color: _color)
        ..circle(x: _dotX(1))
        ..circle(x: _dotX(2)),
    );

    // At 540 ms the second dot peaks while the first is on its way down.
    // Its phase is computed in floating point, so compare the painted center
    // with a tolerance rather than through the exact `paints` matcher.
    await tester.pump(const Duration(milliseconds: 150));
    final secondPeak = ConduitWaveDotsPainter.dotAt(1, _progress(tester)!);
    check(secondPeak.dy).isCloseTo(-5, 1e-3);
    check(secondPeak.opacity).isCloseTo(1, 1e-3);
    expect(
      tester.renderObject(_dots),
      paints
        ..circle(x: _dotX(0))
        ..something((method, arguments) {
          if (method != #drawCircle) return false;
          final center = arguments[0] as Offset;
          return center.dx == _dotX(1) && (center.dy - 9).abs() < 1e-3;
        })
        ..circle(x: _dotX(2)),
    );

    // The controller repeats rather than stopping at the end of a cycle.
    await tester.pump(const Duration(milliseconds: 1300));
    check(_progress(tester)!).isCloseTo(540 / 1300, 1e-6);
    check(find.byType(AnimatedBuilder).evaluate()).isEmpty();
  });

  testWidgets('stops and resets when animate turns off', (tester) async {
    await tester.pumpWidget(_harness());
    await tester.pump(const Duration(milliseconds: 390));

    await tester.pumpWidget(_harness(animate: false));
    check(_painter(tester).progress).isNull();
    check(tester.binding.transientCallbackCount).equals(0);

    await tester.pumpWidget(_harness());
    check(_progress(tester)).equals(0);
    await tester.pump(const Duration(milliseconds: 130));
    check(_progress(tester)!).isCloseTo(0.1, 1e-6);
  });

  testWidgets('pauses the wave while the app is backgrounded', (tester) async {
    await tester.pumpWidget(_harness());
    await tester.pump(const Duration(milliseconds: 130));

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(milliseconds: 800));
    check(_progress(tester)).equals(0);
    check(tester.binding.transientCallbackCount).equals(0);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 390));
    check(_progress(tester)!).isCloseTo(0.3, 1e-6);
  });

  testWidgets('holds still while its TickerMode is disabled', (tester) async {
    await tester.pumpWidget(_harness());
    await tester.pump(const Duration(milliseconds: 130));
    final before = _progress(tester)!;

    await tester.pumpWidget(_harness(tickerEnabled: false));
    await tester.pump(const Duration(milliseconds: 800));
    check(_progress(tester)).equals(before);
    check(tester.binding.transientCallbackCount).equals(0);

    await tester.pumpWidget(_harness());
    await tester.pump(const Duration(milliseconds: 130));
    check(_progress(tester)!).isGreaterThan(before);
    check(tester.takeException()).isNull();
  });

  group('paced', () {
    testWidgets('steps on a timer instead of display frames', (tester) async {
      await tester.pumpWidget(_harness(paced: true));
      check(_progress(tester)).equals(0);
      check(tester.binding.transientCallbackCount).equals(0);

      await tester.pump(const Duration(milliseconds: 33));
      check(_progress(tester)!).isCloseTo(_pacedAt(1), 1e-9);
      check(tester.binding.transientCallbackCount).equals(0);

      await tester.pump(const Duration(milliseconds: 33 * 11));
      check(_progress(tester)!).isCloseTo(_pacedAt(12), 1e-9);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('skips frames while every dot rests', (tester) async {
      await tester.pumpWidget(_harness(paced: true));

      // Tick 33 is the first one inside the resting stretch; it still
      // repaints because the frame before it was moving.
      await tester.pump(const Duration(milliseconds: 33 * 33));
      check(_progress(tester)!).isCloseTo(_pacedAt(33), 1e-9);
      check(ConduitWaveDotsPainter.isRestingAt(_pacedAt(33))).isTrue();

      // The next ticks rest too, so the controller is left alone.
      await tester.pump(const Duration(milliseconds: 33 * 6));
      check(_progress(tester)!).isCloseTo(_pacedAt(33), 1e-9);

      // Tick 40 wraps into the next cycle, where the first dot rises again.
      await tester.pump(const Duration(milliseconds: 33));
      check(_progress(tester)!).isCloseTo(_pacedAt(40), 1e-9);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('continues from the same spot at display rate', (tester) async {
      await tester.pumpWidget(_harness(paced: true));
      await tester.pump(const Duration(milliseconds: 33 * 12));

      await tester.pumpWidget(_harness());
      check(_progress(tester)!).isCloseTo(_pacedAt(12), 1e-9);
      check(tester.binding.transientCallbackCount).equals(1);

      await tester.pump(const Duration(milliseconds: 130));
      check(_progress(tester)!).isCloseTo(_pacedAt(12) + 0.1, 1e-6);
    });

    testWidgets('holds still while its TickerMode is disabled', (tester) async {
      await tester.pumpWidget(_harness(paced: true));
      await tester.pump(const Duration(milliseconds: 33 * 4));
      final before = _progress(tester)!;

      await tester.pumpWidget(_harness(paced: true, tickerEnabled: false));
      await tester.pump(const Duration(milliseconds: 800));
      check(_progress(tester)).equals(before);

      await tester.pumpWidget(_harness(paced: true));
      await tester.pump(const Duration(milliseconds: 33 * 4));
      check(_progress(tester)!).isGreaterThan(before);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('stops and resets while the app is backgrounded', (
      tester,
    ) async {
      await tester.pumpWidget(_harness(paced: true));
      await tester.pump(const Duration(milliseconds: 33 * 4));

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump(const Duration(milliseconds: 800));
      check(_progress(tester)).equals(0);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(milliseconds: 33 * 4));
      check(_progress(tester)!).isCloseTo(_pacedAt(4), 1e-9);

      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
