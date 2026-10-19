import 'dart:math' as math;
import 'package:flutter/foundation.dart'
    show precisionErrorTolerance, visibleForTesting;
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// A source anchor with verified, same-layout pixels starts a lazy list nearby.
/// Ordinary scrolling remains Flutter's variable-height SliverList algorithm.
class ReaderScrollAnchor {
  @visibleForTesting
  static bool debugDisableSourceAnchors = false;
  _ReaderScrollRender? _render;
  void restore({
    required int row,
    required double fraction,
    required double inset,
  }) {
    var disabled = false;
    assert(() {
      disabled = debugDisableSourceAnchors;
      return true;
    }());
    if (disabled) return;
    _render?.seed = (row: row, fraction: fraction, inset: inset);
  }
}

typedef _Seed = ({int row, double fraction, double inset});

class ReaderScrollSliver extends SliverList {
  ReaderScrollSliver({
    super.key,
    required this.anchor,
    required IndexedWidgetBuilder itemBuilder,
    required int itemCount,
  }) : super(
         delegate: SliverChildBuilderDelegate(
           itemBuilder,
           childCount: itemCount,
           addAutomaticKeepAlives: false,
         ),
       );
  final ReaderScrollAnchor anchor;
  @override
  RenderSliverList createRenderObject(BuildContext context) =>
      _ReaderScrollRender(
        childManager: context as SliverMultiBoxAdaptorElement,
        anchor: anchor,
      );
  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderSliverList renderObject,
  ) => (renderObject as _ReaderScrollRender).anchor = anchor;
}

class _ReaderScrollRender extends RenderSliverList {
  _ReaderScrollRender({
    required super.childManager,
    required ReaderScrollAnchor anchor,
  }) : _anchor = anchor;
  ReaderScrollAnchor _anchor;
  _Seed? _seed;
  set seed(_Seed value) {
    _seed = value;
    markNeedsLayout();
  }

  set anchor(ReaderScrollAnchor value) {
    if (value == _anchor) return;
    if (attached) _anchor._render = null;
    _anchor = value;
    if (attached) _anchor._render = this;
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _anchor._render = this;
  }

  @override
  void detach() {
    if (identical(_anchor._render, this)) _anchor._render = null;
    _seed = null;
    super.detach();
  }

  @override
  void performLayout() {
    final seed = _seed;
    _seed = null;
    // At the actual chapter start use the true first row, including after an
    // indexed resume. Never manufacture a preceding row or a negative extent.
    final atStart =
        constraints.scrollOffset + constraints.cacheOrigin <=
        precisionErrorTolerance;
    if (atStart && firstChild != null && indexOf(firstChild!) > 0) {
      collectGarbage(childCount, 0);
    } else if (seed != null && seed.row > 0 && !atStart) {
      var visible = false;
      for (
        RenderBox? child = firstChild;
        child != null;
        child = childAfter(child)
      ) {
        if (indexOf(child) == seed.row) {
          visible = true;
          break;
        }
      }
      if (!visible) {
        collectGarbage(childCount, 0);
        if (addInitialChild(
          index: seed.row,
          layoutOffset: constraints.scrollOffset,
        )) {
          final child = firstChild!;
          child.layout(constraints.asBoxConstraints(), parentUsesSize: true);
          final height = paintExtentOf(child);
          final point = seed.fraction.clamp(0.0, 1.0) * height;
          (child.parentData! as SliverMultiBoxAdaptorParentData).layoutOffset =
              math.max(0.0, constraints.scrollOffset + seed.inset - point);
        }
      }
    }
    super.performLayout();
  }
}
