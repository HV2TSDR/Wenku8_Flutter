import 'dart:math' as math;
import 'package:flutter/widgets.dart';

/// A short deliberate stroke commits one page; a small adjustment returns to
/// its origin. Distance is bounded in logical pixels, not half a tablet screen.
class ReaderPagePhysics extends PageScrollPhysics {
  const ReaderPagePhysics({required this.origin, super.parent});
  final int? Function() origin;
  static double commitDistance(double viewport) =>
      (viewport * .1).clamp(28, 48);

  @override
  ReaderPagePhysics applyTo(ScrollPhysics? ancestor) =>
      ReaderPagePhysics(origin: origin, parent: buildParent(ancestor));

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) {
    if (position is! PageMetrics ||
        position.pixels < position.minScrollExtent ||
        position.pixels > position.maxScrollExtent ||
        position.pixels <= position.minScrollExtent && velocity <= 0 ||
        position.pixels >= position.maxScrollExtent && velocity >= 0) {
      return super.createBallisticSimulation(position, velocity);
    }
    final gestureOrigin = origin();
    if (gestureOrigin == null) {
      return super.createBallisticSimulation(position, velocity);
    }
    final page = position.page ?? 0;
    final start = gestureOrigin.toDouble();
    final width = position.viewportDimension * position.viewportFraction;
    final distance = (page - start) * width;
    final reversing = velocity.abs() >= 360 && velocity.sign != distance.sign;
    final fast = !reversing && velocity.abs() >= 360 && distance.abs() >= 8;
    final commit =
        !reversing && (distance.abs() >= commitDistance(width) || fast);
    final direction = distance.sign;
    final destination = (commit ? start + direction : start).clamp(
      position.minScrollExtent / width,
      position.maxScrollExtent / width,
    );
    final pixels = destination * width;
    final tolerance = toleranceFor(position);
    if ((pixels - position.pixels).abs() < tolerance.distance) return null;
    return _ReaderPageSnap(
      ScrollSpringSimulation(
        spring,
        position.pixels,
        pixels,
        math.max(-2400.0, math.min(2400.0, velocity)),
        tolerance: tolerance,
      ),
      from: position.pixels,
      to: pixels,
    );
  }
}

/// A fast release near the landing must not overshoot into the following page
/// and momentarily expose its text or illustration before bouncing back.
class _ReaderPageSnap extends Simulation {
  _ReaderPageSnap(this.spring, {required this.from, required this.to})
    : super(tolerance: spring.tolerance);
  final ScrollSpringSimulation spring;
  final double from, to;
  @override
  bool isDone(double time) =>
      spring.isDone(time) ||
      (to > from ? spring.x(time) >= to : spring.x(time) <= to);
  @override
  double x(double time) => isDone(time) ? to : spring.x(time);
  @override
  double dx(double time) => isDone(time) ? 0 : spring.dx(time);
}
