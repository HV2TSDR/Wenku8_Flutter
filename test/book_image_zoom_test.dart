import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/reader_illustrations.dart';

import 'support/cover_fixture.dart';
import 'support/visual_review.dart';

void main() {
  setUpAll(loadReviewFonts);
  for (final drift in [0.0, -30.0]) {
    testWidgets('two fingers zoom the image after first finger drift $drift', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final boundary = GlobalKey();
      final bytes = (await tester.runAsync(coverFixtureBytes))!;
      final cache = ReaderIllustrationCache(request: (_) async => bytes);
      await tester.pumpWidget(
        MaterialApp(
          theme: novelTheme(Brightness.light),
          home: RepaintBoundary(
            key: boundary,
            child: ReaderIllustrationGallery(
              urls: const [
                'https://www.wenku8.net/a.png',
                'https://www.wenku8.net/b.png',
              ],
              initialUrl: 'https://www.wenku8.net/a.png',
              cache: cache,
            ),
          ),
        ),
      );
      for (var i = 0; i < 3; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pumpAndSettle();
      }
      final viewer = find.byType(InteractiveViewer).first;
      final transform = tester
          .widget<InteractiveViewer>(viewer)
          .transformationController!;
      final start = transform.value.entry(0, 0);
      if (drift == 0) await captureReview(tester, boundary, 'gallery-fitted');
      final center = tester.getCenter(viewer);
      final first = await tester.startGesture(
        center - const Offset(40, 0),
        pointer: 1,
        kind: ui.PointerDeviceKind.touch,
      );
      if (drift != 0) {
        await first.moveBy(Offset(drift, 0));
        await tester.pump(const Duration(milliseconds: 30));
      }
      final second = await tester.startGesture(
        center + const Offset(40, 0),
        pointer: 2,
        kind: ui.PointerDeviceKind.touch,
      );
      await tester.pump();
      for (var i = 1; i <= 5; i++) {
        await first.moveTo(center - Offset(40 + i * 15, 0));
        await second.moveTo(center + Offset(40 + i * 15, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(transform.value.entry(0, 0), greaterThan(start * 1.4));
      await first.up();
      await second.up();
      await tester.pumpAndSettle();
      expect(find.text('IMAGE / 1 OF 2'), findsOneWidget);
      if (drift == 0) await captureReview(tester, boundary, 'gallery-pinched');
      // Shrinking below fit must use the real 2D scale, not a Z axis stuck at 1.
      final shrink1 = await tester.startGesture(
        center - const Offset(100, 0),
        pointer: 3,
      );
      final shrink2 = await tester.startGesture(
        center + const Offset(100, 0),
        pointer: 4,
      );
      await tester.pump();
      for (var i = 1; i <= 4; i++) {
        await shrink1.moveTo(center - Offset(100 - i * 20, 0));
        await shrink2.moveTo(center + Offset(100 - i * 20, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await shrink1.up();
      await shrink2.up();
      await tester.pumpAndSettle();
      expect(transform.value.entry(0, 0), inInclusiveRange(.25, .89));
      if (drift == 0) await captureReview(tester, boundary, 'gallery-shrunk');
      expect(tester.takeException(), isNull);
    });
  }
}
