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
    this.ringWidth = 1,
  });

  static const double size = 36;

  /// How far the chip reaches into the bubble, on each axis.
  static const double overlap = 12;

  /// How far the chip hangs past the bubble's bottom and trailing edges.
  static const double overhang = size - overlap;

  final String emoji;
  final String semanticsLabel;

  /// Width of the page-colored ring that reads as a cut out of the bubble.
  final double ringWidth;

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
          border: Border.all(color: theme.surfaceBackground, width: ringWidth),
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
///
/// With [inset] the badge sits just inside the trailing edge instead, its top
/// reaching [insetOverlap] into the bubble and the rest hanging below, the
/// way a filled chat bubble carries a reaction; [trailingRoom] is then
/// unused. An [inset] badge can instead keep [fixedRoom] below [child]
/// whether or not it shows, so a badge arriving never moves what follows.
class MessageBadgeAnchor extends StatelessWidget {
  const MessageBadgeAnchor({
    super.key,
    required this.badge,
    required this.child,
    this.reserveSpace = true,
    this.trailingRoom = 0,
    this.cornerInset = EdgeInsetsDirectional.zero,
    this.inset = false,
    this.fixedRoom,
  }) : assert(fixedRoom == null || inset, 'fixedRoom needs an inset badge');

  /// How far an [inset] badge hangs below the bubble's bottom edge.
  static const double insetHang = MessageBadge.size - insetOverlap;

  /// How far an [inset] badge reaches up into the bubble.
  static const double insetOverlap = 10;

  /// How far an [inset] badge sits inside the bubble's trailing edge.
  static const double insetEnd = 10;

  final Widget? badge;
  final Widget child;
  final bool reserveSpace;
  final double trailingRoom;
  final EdgeInsetsDirectional cornerInset;
  final bool inset;

  /// For an [inset] badge: room kept below [child] with or without a badge,
  /// overriding [reserveSpace]. The badge hangs past it by the rest of
  /// [insetHang], which the caller must already leave free.
  final double? fixedRoom;

  @override
  Widget build(BuildContext context) {
    final badge = this.badge;
    final showing = badge != null;
    if (inset) {
      final room = fixedRoom ?? (showing && reserveSpace ? insetHang : 0.0);
      return Stack(
        clipBehavior: Clip.none,
        children: [
          Padding(
            padding: EdgeInsets.only(bottom: room),
            child: child,
          ),
          if (badge != null)
            PositionedDirectional(
              bottom: room - insetHang + cornerInset.bottom,
              end: insetEnd + cornerInset.end,
              child: badge,
            ),
        ],
      );
    }
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
