import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenku8_flutter/easy_glass.dart';

void registerGlassTintEdgeTests({
  required Future<void> Function(WidgetTester, GlobalKey, String) capture,
}) {
  for (final (name, paper, tint) in [
    ('sage', const Color(0xffe4ebdd), const Color(0xffeaf0e5)),
    ('parchment', const Color(0xffede2ca), const Color(0xfff1e9d7)),
    ('night', const Color(0xff181818), const Color(0xff303030)),
  ]) {
    testWidgets('uniform glass tint has no bright edge on $name paper', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(240, 240);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            home: Scaffold(
              backgroundColor: paper,
              body: Center(
                child: SizedBox(
                  width: 128,
                  height: 64,
                  child: EasyGlassSurface(
                    radius: 24,
                    thickness: 12,
                    blur: 0,
                    refractiveIndex: 1,
                    tint: tint.withValues(alpha: .87),
                    emission: 0,
                    activation: 0,
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await capture(tester, key, 'glass-edge-$name');
      final boundary =
          key.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final bytes = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      final limits = [
        for (final (a, b) in [
          (paper.r, tint.r),
          (paper.g, tint.g),
          (paper.b, tint.b),
        ])
          (math.max(a, b) * 255).round() + 3,
      ];
      var overshoot = 0;
      for (var y = 84; y < 156; y++) {
        for (var x = 52; x < 188; x++) {
          final offset = (y * image.width + x) * 4;
          for (var channel = 0; channel < 3; channel++) {
            overshoot = math.max(
              overshoot,
              bytes.getUint8(offset + channel) - limits[channel],
            );
          }
        }
      }
      image.dispose();
      expect(
        overshoot,
        0,
        reason:
            'Zero optical lights and a uniform backdrop cannot create a '
            'brighter outline than either the paper or the glass tint.',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
