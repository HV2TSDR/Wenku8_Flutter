import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';
import 'package:liquid_glass_easy/src/widgets/lens/render_liquid_glass_lens.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'scene geometry reuse preserves clipped, moving, fading and filtered glass pixels',
    (tester) async {
      await LiquidGlassShaders.ensureLoaded();
      expect(ui.ImageFilter.isShaderFilterSupported, true);
      addTearDown(
        () => RenderLiquidGlassLens.debugDisableSceneGeometry = false,
      );
      final frames = <List<List<int>>>[];
      for (final baseline in [true, false]) {
        RenderLiquidGlassLens.debugDisableSceneGeometry = baseline;
        final boundary = GlobalKey();
        final source = ValueNotifier(.4);
        final phase = ValueNotifier(0);
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundary,
            child: MaterialApp(
              home: Scaffold(
                body: Stack(
                  children: [
                    Positioned.fill(
                      child: CustomPaint(painter: _LiveBackground(source)),
                    ),
                    Positioned(
                      left: 25,
                      top: 90,
                      width: 280,
                      height: 240,
                      child: ValueListenableBuilder<int>(
                        valueListenable: phase,
                        builder: (_, value, _) {
                          final alpha = [1.0, .55, .8, 1.0][value];
                          return Transform.translate(
                            offset: Offset(
                              [0.0, 11.25, -27.5, 8.75][value],
                              value * 2.3,
                            ),
                            child: Opacity(
                              opacity: alpha,
                              child: ImageFiltered(
                                enabled: value == 2,
                                imageFilter: ui.ImageFilter.blur(
                                  sigmaX: 1.5,
                                  sigmaY: 1.5,
                                ),
                                child: ClipRect(
                                  child: Transform.rotate(
                                    angle: value * .015,
                                    child: LiquidGlassBatch(
                                      child: Stack(
                                        children: [
                                          Positioned.fill(
                                            child: CustomPaint(
                                              painter: _LiveBackground(source),
                                            ),
                                          ),
                                          for (var i = 0; i < 9; i++)
                                            Positioned(
                                              left: (i % 3) * 90.0,
                                              top: (i ~/ 3) * 80.0,
                                              width: 72,
                                              height: 58,
                                              child: LiquidGlassLens(
                                                physicalOptics: i.isEven,
                                                style: LiquidGlassStyle(
                                                  shape:
                                                      const LiquidGlassShape.roundedRectangle(
                                                        cornerRadius: 12,
                                                      ),
                                                  refractionIndex: 1.03,
                                                  refractionWidth: 12,
                                                  blur: [
                                                    8.0,
                                                    8.0,
                                                    2.0,
                                                    12.0,
                                                  ][value],
                                                  color: const Color(
                                                    0x1afffdf8,
                                                  ),
                                                  specular:
                                                      const LiquidGlassLight.specular(
                                                        intensity: 0,
                                                      ),
                                                  glow:
                                                      const LiquidGlassLight.glow(
                                                        intensity: 0,
                                                      ),
                                                ),
                                                child: const SizedBox.expand(),
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        final outputs = <List<int>>[];
        for (var value = 0; value < 4; value++) {
          phase.value = value;
          await tester.pumpAndSettle();
          final image =
              await (boundary.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage(pixelRatio: 1);
          outputs.add(
            (await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            ))!.buffer.asUint8List().toList(),
          );
          image.dispose();
        }
        expect(outputs[0], isNot(outputs[1]));
        frames.add(outputs);
        await tester.pumpWidget(const SizedBox.shrink());
        source.dispose();
        phase.dispose();
      }
      var maximum = 0;
      for (var frame = 0; frame < frames[0].length; frame++) {
        for (var i = 0; i < frames[0][frame].length; i++) {
          final error = (frames[0][frame][i] - frames[1][frame][i]).abs();
          if (error > maximum) maximum = error;
        }
      }
      debugPrint(
        'GLASS_SCENE_GEOMETRY_PARITY scenes=4 max_channel_error=$maximum',
      );
      expect(maximum, 0);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('retained lens uniforms preserve live pixels and moving geometry', (
    tester,
  ) async {
    await LiquidGlassShaders.ensureLoaded();
    expect(ui.ImageFilter.isShaderFilterSupported, true);
    addTearDown(
      () => RenderLiquidGlassLens.debugDisableUniformRetention = false,
    );
    final outputs = <List<int>>[];
    final packs = <int>[];
    for (final baseline in [true, false]) {
      RenderLiquidGlassLens.debugDisableUniformRetention = baseline;
      final boundary = GlobalKey();
      final source = ValueNotifier(0.0), move = ValueNotifier(0.0);
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: MaterialApp(
            home: Scaffold(
              body: Stack(
                children: [
                  Positioned.fill(
                    child: CustomPaint(painter: _LiveBackground(source)),
                  ),
                  Positioned(
                    top: 140,
                    left: 40,
                    child: AnimatedBuilder(
                      animation: move,
                      child: LiquidGlassBatch(
                        child: SizedBox(
                          width: 260,
                          height: 150,
                          child: LiquidGlassLens(
                            style: const LiquidGlassStyle(
                              blur: 8,
                              refractionIndex: 1.022,
                              refractionWidth: 20,
                              color: Color(0x0afffdf8),
                              shape: LiquidGlassShape.roundedRectangle(
                                cornerRadius: 28,
                              ),
                              specular: LiquidGlassLight.specular(intensity: 0),
                              glow: LiquidGlassLight.glow(intensity: 0),
                            ),
                            child: const SizedBox.expand(),
                          ),
                        ),
                      ),
                      builder: (_, child) => Transform.translate(
                        offset: Offset(move.value, 0),
                        child: child,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final render = tester.renderObject<RenderLiquidGlassLens>(
        find.byElementPredicate(
          (element) =>
              element is RenderObjectElement &&
              element.renderObject is RenderLiquidGlassLens,
        ),
      );
      final before = render.debugUniformPackCount;
      Future<List<int>> pixels() async {
        final image =
            await (boundary.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary)
                .toImage(pixelRatio: 1);
        final data = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!.buffer.asUint8List().toList();
        image.dispose();
        return data;
      }

      final initial = await pixels();
      for (var i = 1; i <= 16; i++) {
        source.value = i / 16;
        await tester.pump(const Duration(milliseconds: 16));
      }
      final live = await pixels();
      expect(
        live,
        isNot(initial),
        reason: 'A retained filter must keep sampling live content.',
      );
      packs.add(render.debugUniformPackCount - before);
      final stationary = render.debugUniformPackCount;
      move.value = 17.3;
      await tester.pump();
      await tester.pump();
      expect(
        render.debugUniformPackCount,
        greaterThan(stationary),
        reason: 'Ancestor movement must repack in the same frame.',
      );
      outputs.add(await pixels());
      await tester.pumpWidget(const SizedBox.shrink());
      source.dispose();
      move.dispose();
    }
    var maximum = 0;
    for (var i = 0; i < outputs[0].length; i++) {
      final error = (outputs[0][i] - outputs[1][i]).abs();
      if (error > maximum) maximum = error;
    }
    debugPrint(
      'GLASS_UNIFORM_RETENTION baseline_repack=${packs[0]} retained_repack=${packs[1]} max_channel_error=$maximum',
    );
    expect(packs[0], greaterThanOrEqualTo(16));
    expect(packs[1], 0);
    expect(maximum, 0);
    expect(tester.takeException(), isNull);
  });
}

class _LiveBackground extends CustomPainter {
  _LiveBackground(this.phase) : super(repaint: phase);
  final ValueNotifier<double> phase;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawColor(
      Color.lerp(
        const Color(0xff193044),
        const Color(0xffdc5471),
        phase.value,
      )!,
      BlendMode.src,
    );
    for (var y = 0.0; y < size.height; y += 20) {
      canvas.drawRect(
        Rect.fromLTWH(phase.value * 28, y, size.width * .7, 7),
        Paint()..color = const Color(0xffe6d59a),
      );
    }
  }

  @override
  bool shouldRepaint(_LiveBackground old) => old.phase != phase;
}
