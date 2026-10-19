import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';
import 'package:wenku8_flutter/easy_glass.dart';

void main({bool native = false}) {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'edge input batching preserves live Gaussian pixels and independent feather masks',
    (tester) async {
      if (native) expect(ui.ImageFilter.isShaderFilterSupported, isTrue);
      final key = GlobalKey();
      Future<ByteData> render(
        bool shared, {
        double shift = 0,
        double height = 600,
        double opacity = 1,
      }) async {
        await tester.pumpWidget(
          RepaintBoundary(
            key: key,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              home: Scaffold(
                body: Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: 330,
                    height: height,
                    child: LiquidGlassScrollEdgeGroup(
                      enabled: shared,
                      child: Opacity(
                        opacity: opacity,
                        child: Stack(
                          children: [
                            Positioned.fill(
                              child: CustomPaint(
                                painter: EdgeInputPattern(shift),
                              ),
                            ),
                            const Positioned(
                              left: 0,
                              right: 0,
                              top: 0,
                              height: 140,
                              child: EasyScrollEdge(
                                blur: 8,
                                plateau: 30,
                                fromBottom: false,
                                child: SizedBox.expand(),
                              ),
                            ),
                            const Positioned(
                              left: 0,
                              right: 0,
                              bottom: 0,
                              height: 90,
                              child: EasyScrollEdge(
                                blur: 1.28,
                                plateau: 20,
                                fromBottom: true,
                                child: SizedBox.expand(),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final planes = find.byWidgetPredicate(
          (w) => w.runtimeType.toString() == 'LiquidGlassEdgeBackdrop',
        );
        expect(planes, findsNWidgets(2));
        final expectedShared = shared && height == 600 && opacity == 1;
        final keys = <Object?>[];
        for (final element in planes.evaluate()) {
          final dynamic render = element.renderObject!;
          expect(render.debugSharesEdgeInput, expectedShared);
          keys.add(render.debugEdgeInputKey);
        }
        if (expectedShared) expect(keys[0], same(keys[1]));
        expect(find.byType(ShaderMask), findsNothing);
        final image =
            (key.currentContext!.findRenderObject() as RenderRepaintBoundary)
                .toImageSync(pixelRatio: 1);
        late ByteData pixels;
        if (native) {
          pixels = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!;
        } else {
          pixels = (await tester.runAsync(
            () async =>
                (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!,
          ))!;
        }
        const output = String.fromEnvironment('REVIEW_ARTIFACTS');
        if (!native &&
            output.isNotEmpty &&
            shared &&
            shift == 0 &&
            expectedShared) {
          await tester.runAsync(() async {
            await Directory(output).create(recursive: true);
            final png = (await image.toByteData(
              format: ui.ImageByteFormat.png,
            ))!;
            await File(
              '$output/edge-input-shared.png',
            ).writeAsBytes(png.buffer.asUint8List());
          });
        }
        image.dispose();
        expect(tester.takeException(), isNull);
        return pixels;
      }

      final baseline = await render(false);
      final grouped = await render(true);
      var maximum = 0, sum = 0;
      for (var i = 0; i < baseline.lengthInBytes; i++) {
        final error = (baseline.getUint8(i) - grouped.getUint8(i)).abs();
        if (error > maximum) maximum = error;
        sum += error;
      }
      debugPrint(
        'EDGE_INPUT_PIXEL_PARITY native=$native max=$maximum mean=${sum / baseline.lengthInBytes}',
      );
      expect(maximum, lessThanOrEqualTo(2));
      expect(sum / baseline.lengthInBytes, lessThan(.05));
      final moved = await render(true, shift: 9);
      var changed = 0;
      for (var i = 0; i < grouped.lengthInBytes; i += 4) {
        if (grouped.getUint8(i) != moved.getUint8(i)) changed++;
      }
      expect(changed, greaterThan(100));
      await render(true, height: 200);
      await render(true, opacity: .5);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

class EdgeInputPattern extends CustomPainter {
  const EdgeInputPattern(this.shift);
  final double shift;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawColor(const Color(0xfff6f4ee), BlendMode.src);
    const colors = [Color(0xff26394b), Color(0xffb86f79), Color(0xff70948c)];
    for (var y = -20.0; y < size.height; y += 13) {
      for (var x = -20.0; x < size.width; x += 15) {
        canvas.drawRect(
          Rect.fromLTWH(x + shift, y + shift, 6, 8),
          Paint()..color = colors[((x / 15 + y / 13).floor()).abs() % 3],
        );
      }
    }
  }

  @override
  bool shouldRepaint(EdgeInputPattern oldDelegate) =>
      shift != oldDelegate.shift;
}
