import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:flutter/widgets.dart';

/// A round chip holding one emoji, laid over a message bubble's
/// bottom-trailing corner like a tapback: about a third of it overlaps the
/// bubble and the rest hangs outside, below and past the trailing edge.
class MessageBadge extends StatelessWidget {
  const MessageBadge({
    super.key,
    required this.emoji,
    required this.semanticsLabel,
  });

  static const double size = 36;

  /// How far the chip reaches into the bubble, on each axis.
  static const double overlap = 12;

  /// How far the chip hangs past the bubble's bottom and trailing edges.
  static const double overhang = size - overlap;

  final String emoji;
  final String semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    return Semantics(
      label: semanticsLabel,
      excludeSemantics: true,
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: theme.surfaceContainer,
          shape: BoxShape.circle,
          // The page color around the chip reads as a cut out of the bubble.
          border: Border.all(color: theme.surfaceBackground),
        ),
        child: Text(emoji, style: const TextStyle(fontSize: 20, height: 1)),
      ),
    );
  }
}

/// Lays [badge] over the bottom-trailing corner of [child], a third inside
/// and the rest outside. The stack stays in place without a badge so [child]
/// keeps its state.
///
/// With [reserveSpace] the overhang is added below [child] so nothing after
/// it can cover the badge; without it the caller must already leave that
/// much room under [child]. [trailingRoom] is added past [child]'s trailing
/// edge while a badge shows, so that together with the room the caller
/// already has there the overhang is not clipped. [cornerInset] moves the
/// corner the badge hangs from in from [child]'s own bottom-trailing corner,
/// for a [child] whose visible surface does not reach its edges.
class MessageBadgeAnchor extends StatelessWidget {
  const MessageBadgeAnchor({
    super.key,
    required this.badge,
    required this.child,
    this.reserveSpace = true,
    this.trailingRoom = 0,
    this.cornerInset = EdgeInsetsDirectional.zero,
  });

  final Widget? badge;
  final Widget child;
  final bool reserveSpace;
  final double trailingRoom;
  final EdgeInsetsDirectional cornerInset;

  @override
  Widget build(BuildContext context) {
    final badge = this.badge;
    final showing = badge != null;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Padding(
          padding: EdgeInsetsDirectional.only(
            end: showing ? trailingRoom : 0,
            bottom: showing && reserveSpace ? MessageBadge.overhang : 0,
          ),
          child: child,
        ),
        if (badge != null)
          PositionedDirectional(
            bottom:
                (reserveSpace ? 0 : -MessageBadge.overhang) +
                cornerInset.bottom,
            end: trailingRoom - MessageBadge.overhang + cornerInset.end,
            child: badge,
          ),
      ],
    );
  }
}
