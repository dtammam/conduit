import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Wraps [bubble], one prose segment of a reply. [isLastBubble] is true for
/// the segment that closes the reply's last bubble. Called for every segment
/// so the wrapper keeps the same shape as segments stop being last, and the
/// markdown below it keeps its state.
typedef MarkdownProseBubbleDecorator = Widget Function(
  Widget bubble, {
  required bool isLastBubble,
});

/// How a [StreamingMarkdownWidget] lays its prose into chat bubbles.
///
/// Consecutive prose blocks share one bubble; details blocks and groups (tool
/// calls, reasoning) break the run and render bare between bubbles, aligned
/// with the bubbles' leading edge. Each prose block is painted as its own
/// slice of the bubble (rounded top on the first, rounded bottom on the last)
/// so long settled replies keep their per-block chunked inflation.
@immutable
class MarkdownProseBubble {
  const MarkdownProseBubble({
    required this.color,
    this.radius = 20,
    this.padding = const EdgeInsetsDirectional.fromSTEB(16, 12, 16, 12),
    this.maxWidthFactor = 0.85,
    this.gap = 8,
    this.decorate,
  });

  /// The bubble fill.
  final Color color;

  /// Corner radius of each bubble.
  final double radius;

  /// Space between the bubble edge and the prose.
  final EdgeInsetsDirectional padding;

  /// The widest a bubble gets, as a share of the width it is given. A bubble
  /// holding one block hugs its content up to that width; a bubble holding
  /// several fills it so every slice lines up.
  final double maxWidthFactor;

  /// Space between a bubble and a neighboring details block.
  final double gap;

  /// Optional wrapper around each segment, for example a reaction badge on
  /// the last bubble.
  final MarkdownProseBubbleDecorator? decorate;
}

/// One block's slice of a prose bubble.
class MarkdownProseBubbleSegment extends StatelessWidget {
  const MarkdownProseBubbleSegment({
    super.key,
    required this.style,
    required this.isFirst,
    required this.isLast,
    required this.fillWidth,
    required this.child,
    this.gapBefore = false,
    this.gapAfter = false,
    this.isLastBubble = false,
  });

  final MarkdownProseBubble style;

  /// Whether this slice opens its bubble (rounded top, top padding).
  final bool isFirst;

  /// Whether this slice closes its bubble (rounded bottom, bottom padding).
  final bool isLast;

  /// Whether the slice takes the full bubble width instead of hugging.
  final bool fillWidth;

  /// Space above the slice, after a details block.
  final bool gapBefore;

  /// Space below the slice, before a details block.
  final bool gapAfter;

  /// Whether this slice closes the reply's last bubble.
  final bool isLastBubble;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final radius = Radius.circular(style.radius);
    final padding = style.padding;
    Widget bubble = MarkdownBubbleWidth(
      factor: style.maxWidthFactor,
      fill: fillWidth,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: style.color,
          borderRadius: BorderRadius.vertical(
            top: isFirst ? radius : Radius.zero,
            bottom: isLast ? radius : Radius.zero,
          ),
        ),
        child: Padding(
          padding: EdgeInsetsDirectional.only(
            start: padding.start,
            end: padding.end,
            top: isFirst ? padding.top : 0,
            bottom: isLast ? padding.bottom : 0,
          ),
          child: child,
        ),
      ),
    );
    final decorate = style.decorate;
    if (decorate != null) {
      bubble = decorate(bubble, isLastBubble: isLastBubble);
    }
    return Padding(
      padding: EdgeInsets.only(
        top: gapBefore ? style.gap : 0,
        bottom: gapAfter ? style.gap : 0,
      ),
      child: bubble,
    );
  }
}

/// Lays its child out at most [factor] of the incoming maximum width, aligned
/// to the leading edge. With [fill] the child takes that whole width. Unlike
/// a [LayoutBuilder] it answers intrinsic and dry layout queries.
class MarkdownBubbleWidth extends SingleChildRenderObjectWidget {
  const MarkdownBubbleWidth({
    super.key,
    required this.factor,
    this.fill = false,
    super.child,
  });

  final double factor;
  final bool fill;

  @override
  RenderMarkdownBubbleWidth createRenderObject(BuildContext context) {
    return RenderMarkdownBubbleWidth(
      factor: factor,
      fill: fill,
      textDirection: Directionality.of(context),
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    RenderMarkdownBubbleWidth renderObject,
  ) {
    renderObject
      ..factor = factor
      ..fill = fill
      ..textDirection = Directionality.of(context);
  }
}

class RenderMarkdownBubbleWidth extends RenderShiftedBox {
  RenderMarkdownBubbleWidth({
    required double factor,
    required bool fill,
    required TextDirection textDirection,
    RenderBox? child,
  }) : _factor = factor,
       _fill = fill,
       _textDirection = textDirection,
       super(child);

  double _factor;
  double get factor => _factor;
  set factor(double value) {
    if (value == _factor) return;
    _factor = value;
    markNeedsLayout();
  }

  bool _fill;
  bool get fill => _fill;
  set fill(bool value) {
    if (value == _fill) return;
    _fill = value;
    markNeedsLayout();
  }

  TextDirection _textDirection;
  TextDirection get textDirection => _textDirection;
  set textDirection(TextDirection value) {
    if (value == _textDirection) return;
    _textDirection = value;
    markNeedsLayout();
  }

  double _limit(double width) => width * _factor;

  BoxConstraints _childConstraints(BoxConstraints constraints) {
    if (!constraints.hasBoundedWidth) {
      return constraints.loosen();
    }
    final maxWidth = _limit(constraints.maxWidth);
    return BoxConstraints(
      minWidth: _fill ? maxWidth : 0,
      maxWidth: maxWidth,
      maxHeight: constraints.maxHeight,
    );
  }

  @override
  double computeMinIntrinsicWidth(double height) =>
      child?.getMinIntrinsicWidth(height) ?? 0;

  @override
  double computeMaxIntrinsicWidth(double height) =>
      child?.getMaxIntrinsicWidth(height) ?? 0;

  @override
  double computeMinIntrinsicHeight(double width) =>
      child?.getMinIntrinsicHeight(width.isFinite ? _limit(width) : width) ?? 0;

  @override
  double computeMaxIntrinsicHeight(double width) =>
      child?.getMaxIntrinsicHeight(width.isFinite ? _limit(width) : width) ?? 0;

  @override
  Size computeDryLayout(covariant BoxConstraints constraints) {
    final child = this.child;
    if (child == null) return constraints.smallest;
    return constraints.constrain(
      child.getDryLayout(_childConstraints(constraints)),
    );
  }

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    child.layout(_childConstraints(constraints), parentUsesSize: true);
    size = constraints.constrain(child.size);
    final dx = _textDirection == TextDirection.rtl
        ? math.max(0.0, size.width - child.size.width)
        : 0.0;
    (child.parentData! as BoxParentData).offset = Offset(dx, 0);
  }
}
