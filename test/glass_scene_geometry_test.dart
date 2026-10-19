import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_easy/src/widgets/lens/liquid_glass_transform_tracking.dart';

class _Counter extends SingleChildRenderObjectWidget {
  const _Counter({required super.child});
  @override
  RenderObject createRenderObject(BuildContext context) => _CounterRender();
}

class _CounterRender extends RenderProxyBox {
  int calls = 0;
  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    calls++;
    super.applyPaintTransform(child, transform);
  }
}

void main() {
  testWidgets(
    'scene geometry shares prefixes but matches live transforms and subpasses exactly',
    (tester) async {
      final leaves = List.generate(12, (_) => GlobalKey());
      final pose = ValueNotifier((alpha: 1.0, filter: false, x: 0.0));
      addTearDown(pose.dispose);
      Widget children = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < leaves.length; i++)
            Transform.rotate(
              angle: i * .01,
              child: SizedBox(key: leaves[i], width: 80, height: 24),
            ),
        ],
      );
      for (var i = 0; i < 10; i++) {
        children = _Counter(
          child: Padding(padding: const EdgeInsets.all(.2), child: children),
        );
      }
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: ValueListenableBuilder(
              valueListenable: pose,
              child: children,
              builder: (context, value, child) => Transform.translate(
                offset: Offset(value.x, 3.25),
                child: Opacity(
                  opacity: value.alpha,
                  child: ImageFiltered(
                    enabled: value.filter,
                    imageFilter: ui.ImageFilter.blur(sigmaX: 2, sigmaY: 2),
                    child: child,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final counters = tester.allRenderObjects
          .whereType<_CounterRender>()
          .toList();
      for (final value in [
        (alpha: 1.0, filter: false, x: 7.5),
        (alpha: .5, filter: false, x: -9.25),
        (alpha: .8, filter: true, x: 31.75),
        (alpha: 1.0, filter: false, x: -14.5),
      ]) {
        pose.value = value;
        await tester.pumpAndSettle();
        final sources = leaves
            .map((key) => key.currentContext!.findRenderObject()!)
            .toList();
        for (final counter in counters) {
          counter.calls = 0;
        }
        final expected = [
          for (final source in sources)
            source.getTransformTo(liquidGlassFilterSubpassAncestor(source)),
        ];
        final baseline = counters.fold<int>(0, (n, c) => n + c.calls);
        for (final counter in counters) {
          counter.calls = 0;
        }
        final scene = ui.SceneBuilder();
        final geometry = LiquidGlassSceneGeometry.forScene(scene);
        for (var i = 0; i < sources.length; i++) {
          final surface = geometry.surfaceFor(sources[i]);
          expect(surface, same(liquidGlassFilterSubpassAncestor(sources[i])));
          expect(
            geometry.transformFor(sources[i], surface).storage,
            expected[i].storage,
          );
        }
        final optimized = counters.fold<int>(0, (n, c) => n + c.calls);
        expect(optimized, lessThan(baseline ~/ 2));
        // ignore: avoid_print
        print(
          'GLASS_SCENE_PREFIX_STEPS baseline=$baseline optimized=$optimized',
        );
        scene.build().dispose();
      }
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
