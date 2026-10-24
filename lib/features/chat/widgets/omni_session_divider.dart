import 'dart:math' as math;

import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit_core/features/chat/omni/omni_session.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// [child] with the Omni session divider above it when message [messageId]
/// started a session. The transcript's first row never gets one.
class OmniSessionDividerGate extends ConsumerWidget {
  const OmniSessionDividerGate({
    super.key,
    required this.messageId,
    required this.child,
  });

  final String messageId;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final startsSession = ref.watch(
      omniSessionProvider.select(
        (session) => session.boundaries.contains(messageId),
      ),
    );
    if (!startsSession) return child;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [const OmniSessionDivider(), child],
    );
  }
}

/// A thin wavy line across the transcript where a new Omni session begins.
class OmniSessionDivider extends StatelessWidget {
  const OmniSessionDivider({super.key});

  static const double height = 28;

  @override
  Widget build(BuildContext context) {
    final color = context.conduitTheme.textSecondary.withValues(alpha: 0.35);
    return Semantics(
      label: AppLocalizations.of(context)!.omniSessionDividerLabel,
      container: true,
      child: SizedBox(
        height: height,
        child: CustomPaint(painter: _WavePainter(color)),
      ),
    );
  }
}

class _WavePainter extends CustomPainter {
  const _WavePainter(this.color);

  final Color color;

  static const double _wavelength = 12;
  static const double _amplitude = 1.6;

  @override
  void paint(Canvas canvas, Size size) {
    final inset = size.width * 0.08;
    final width = size.width - inset * 2;
    if (width <= 0) return;
    final mid = size.height / 2;
    final path = Path()..moveTo(inset, mid);
    for (var x = 0.0; x <= width; x += 1) {
      path.lineTo(
        inset + x,
        mid + _amplitude * math.sin(x / _wavelength * 2 * math.pi),
      );
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..strokeCap = StrokeCap.round
        ..isAntiAlias = true,
    );
  }

  @override
  bool shouldRepaint(_WavePainter oldDelegate) => oldDelegate.color != color;
}
