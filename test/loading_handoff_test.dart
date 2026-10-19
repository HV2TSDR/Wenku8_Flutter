import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenku8_flutter/app_ui.dart';

void main() {
  testWidgets('small skeleton regions never paint across neighboring fields', (
    tester,
  ) async {
    final capture = GlobalKey();
    for (final layout in [
      SkeletonLayout.actions,
      SkeletonLayout.history,
      SkeletonLayout.detail,
      SkeletonLayout.bookRow,
      SkeletonLayout.readerVertical,
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: novelTheme(Brightness.light),
          home: Center(
            child: RepaintBoundary(
              key: capture,
              child: SizedBox(
                width: 100,
                height: 100,
                child: ColoredBox(
                  color: Colors.white,
                  child: Stack(
                    children: [
                      Positioned(
                        left: 20,
                        top: 20,
                        width: 40,
                        height: 18,
                        child: LoadingSkeleton(layout: layout),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.runAsync(() async {
        final render =
            capture.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final frame = await render.toImage(pixelRatio: 1);
        final data = (await frame.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        for (var y = 0; y < 100; y++) {
          for (var x = 0; x < 100; x++) {
            if (x >= 20 && x < 60 && y >= 20 && y < 38) continue;
            final i = (y * 100 + x) * 4;
            expect(
              data.getUint8(i),
              255,
              reason: '$layout paints outside its field at $x,$y',
            );
          }
        }
        frame.dispose();
      });
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets(
    'vertical reader skeleton is a right-to-left bank of vertical columns',
    (tester) async {
      final capture = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: novelTheme(Brightness.light),
          home: Center(
            child: RepaintBoundary(
              key: capture,
              child: const SizedBox(
                width: 100,
                height: 180,
                child: ColoredBox(
                  color: Colors.white,
                  child: ReaderSkeleton(vertical: true, expand: true),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.runAsync(() async {
        final render =
            capture.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final frame = await render.toImage(pixelRatio: 1);
        final data = (await frame.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        expect(data.getUint8((80 * 100 + 94) * 4), lessThan(255));
        expect(data.getUint8((80 * 100 + 78) * 4), 255);
        frame.dispose();
      });
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'skeleton covers delayed and partially revealed content without a blank frame',
    (tester) async {
      final clock = AnimationController(vsync: tester, value: 0);
      addTearDown(clock.dispose);
      final capture = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: RepaintBoundary(
              key: capture,
              child: SizedBox(
                width: 100,
                height: 100,
                child: RevealFromTop(
                  animation: clock,
                  start: .2,
                  end: .8,
                  placeholder: const ColoredBox(color: Color(0xffff0000)),
                  child: const ColoredBox(color: Color(0xff0000ff)),
                ),
              ),
            ),
          ),
        ),
      );
      final reveal = tester.renderObject<ArchiveRevealRender>(
        find.byType(ArchiveReveal),
      );
      final layouts = reveal.debugLayoutCount;
      for (final t in [0.0, .1, .2, .3, .5, .7, 1.0]) {
        clock.value = t;
        await tester.pump();
        await tester.runAsync(() async {
          final render =
              capture.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final frame = await render.toImage(pixelRatio: 1);
          final pixels = (await frame.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!;
          // A central column must always show skeleton red or actual content blue.
          // There is no all-white intermediate frame, even before the delayed cut.
          for (var y = 0; y < 100; y++) {
            final i = (y * 100 + 50) * 4;
            expect(
              pixels.getUint8(i + 1),
              0,
              reason: 'blank gap at t=$t, y=$y',
            );
            expect(pixels.getUint8(i) + pixels.getUint8(i + 2), 255);
          }
          frame.dispose();
        });
        expect(
          reveal.debugLayoutCount,
          layouts,
          reason: 'handoff is paint-only',
        );
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'shared actions have gutters in wrapped rows and secondary settings columns',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: novelTheme(Brightness.light),
          home: Center(
            child: SizedBox(
              width: 220,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Wrap(
                    spacing: 4,
                    children: [
                      for (final name in ['上下滚动', '横排翻页', '竖排翻页'])
                        GlassTextButton(onPressed: () {}, child: Text(name)),
                    ],
                  ),
                  for (final name in ['导出备份文件', '导入备份文件', '复制备份文本'])
                    GlassTextButton(onPressed: () {}, child: Text(name)),
                ],
              ),
            ),
          ),
        ),
      );
      final plates = find.byType(LiquidGlass).evaluate().map((element) {
        final render = element.renderObject! as RenderBox;
        return render.localToGlobal(Offset.zero) & render.size;
      }).toList();
      for (var i = 0; i < plates.length; i++) {
        for (var j = i + 1; j < plates.length; j++) {
          expect(plates[i].overlaps(plates[j]), isFalse);
          if ((plates[i].left - plates[j].left).abs() < 1) {
            expect(plates[j].top - plates[i].bottom, greaterThanOrEqualTo(8));
          }
        }
      }
      expect(tester.takeException(), isNull);
    },
  );
}
