import 'package:flutter/gestures.dart';

/// Horizontal drag recognizer used by the responsive drawer's prioritized
/// opening arenas.
final class DrawerOpenDragGestureRecognizer
    extends HorizontalDragGestureRecognizer {
  DrawerOpenDragGestureRecognizer({super.debugOwner});

  double minimumLocalX = 0.0;
  double maximumLocalX = double.infinity;
  double axisBias = 1.0;
  bool Function(PointerEvent event)? isPositionAllowed;
  int? _trackedPointer;
  Offset? _pointerOrigin;
  double _verticalDistance = 0.0;
  bool _directionDisqualified = false;

  @override
  bool isPointerAllowed(PointerEvent event) {
    final dx = event.localPosition.dx;
    if (dx < minimumLocalX ||
        dx >= maximumLocalX ||
        (_trackedPointer != null && _trackedPointer != event.pointer) ||
        isPositionAllowed?.call(event) == false) {
      return false;
    }
    return super.isPointerAllowed(event);
  }

  @override
  void addAllowedPointer(PointerDownEvent event) {
    _trackedPointer = event.pointer;
    _pointerOrigin = event.position;
    _verticalDistance = 0.0;
    _directionDisqualified = false;
    super.addAllowedPointer(event);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event.pointer == _trackedPointer && event is PointerMoveEvent) {
      final delta = event.position - _pointerOrigin!;
      final dxAbs = delta.dx.abs();
      _verticalDistance = delta.dy.abs();
      final touchSlop = computeHitSlop(event.kind, gestureSettings);
      if ((_verticalDistance > touchSlop && _verticalDistance > dxAbs) ||
          (delta.dx < -touchSlop && dxAbs > _verticalDistance)) {
        _directionDisqualified = true;
      }
    }
    super.handleEvent(event);
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    super.didStopTrackingLastPointer(pointer);
    _trackedPointer = null;
    _pointerOrigin = null;
    _verticalDistance = 0.0;
    _directionDisqualified = false;
  }

  @override
  bool isPointerPanZoomAllowed(PointerPanZoomStartEvent event) => false;

  @override
  bool hasSufficientGlobalDistanceToAccept(
    PointerDeviceKind pointerDeviceKind,
    double? deviceTouchSlop,
  ) =>
      !_directionDisqualified &&
      globalDistanceMoved >
          computeHitSlop(pointerDeviceKind, gestureSettings) &&
      globalDistanceMoved > _verticalDistance * axisBias;

  @override
  String get debugDescription => 'drawer open horizontal drag';
}

/// Horizontal drag recognizer on the open mobile drawer panel.
///
/// While [rightwardAllowed] is false (the drawer is fully open, so a drag to
/// the right cannot move it) a rightward drag is left to the drawer's rows,
/// such as a chat row's swipe. Leftward drags close the drawer as before.
final class DrawerPanelDragGestureRecognizer
    extends HorizontalDragGestureRecognizer {
  DrawerPanelDragGestureRecognizer({super.debugOwner});

  bool Function() rightwardAllowed = _always;
  Offset? _pointerOrigin;
  bool _directionDisqualified = false;

  static bool _always() => true;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    _pointerOrigin = event.position;
    _directionDisqualified = false;
    super.addAllowedPointer(event);
  }

  @override
  void handleEvent(PointerEvent event) {
    final origin = _pointerOrigin;
    if (event is PointerMoveEvent && origin != null) {
      final delta = event.position - origin;
      final touchSlop = computeHitSlop(event.kind, gestureSettings);
      if (delta.dx > touchSlop &&
          delta.dx > delta.dy.abs() &&
          !rightwardAllowed()) {
        _directionDisqualified = true;
      }
    }
    super.handleEvent(event);
  }

  @override
  bool hasSufficientGlobalDistanceToAccept(
    PointerDeviceKind pointerDeviceKind,
    double? deviceTouchSlop,
  ) =>
      !_directionDisqualified &&
      super.hasSufficientGlobalDistanceToAccept(
        pointerDeviceKind,
        deviceTouchSlop,
      );

  @override
  void didStopTrackingLastPointer(int pointer) {
    super.didStopTrackingLastPointer(pointer);
    _pointerOrigin = null;
    _directionDisqualified = false;
  }

  @override
  String get debugDescription => 'drawer panel horizontal drag';
}
