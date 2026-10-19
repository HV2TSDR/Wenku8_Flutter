import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/reader_content.dart';
import 'package:wenku8_flutter/reader_illustrations.dart';
import 'package:wenku8_flutter/reader_page_anchor.dart';
import 'package:wenku8_flutter/reader_page_physics.dart';
import 'package:wenku8_flutter/reader_paged_view.dart';
import 'package:wenku8_flutter/reader_preferences.dart';
import 'package:wenku8_flutter/reader_sheet_motion.dart';
import 'package:wenku8_flutter/reader_reflow.dart';
import 'package:wenku8_flutter/reader_vertical_text.dart';
import 'reader_modes_test.dart' show settleReader;
import 'support/cover_fixture.dart';
import 'support/visual_review.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadReviewFonts);
  test(
    'old preferences retain the default; effects do not invalidate pagination',
    () {
      final old = ReaderPreferences.fromJson({'mode': 'paged', 'margin': 30});
      expect(old.pageEffect, ReaderPageEffect.staggered);
      for (final effect in ReaderPageEffect.values) {
        final next = old.copyWith(pageEffect: effect);
        expect(next.layoutKey, old.layoutKey);
        expect(ReaderPreferences.fromJson(next.toJson()).pageEffect, effect);
      }
    },
  );

  for (final direction in [-1.0, 1.0]) {
    testWidgets('idle cover keeps hit testing aligned for $direction', (
      tester,
    ) async {
      var presses = 0;
      final child = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 300,
              height: 400,
              child: ReaderSheetMotion(
                animation: const AlwaysStoppedAnimation(1),
                effect: ReaderPageEffect.cover,
                direction: direction,
                incoming: false,
                front: true,
                active: false,
                paper: Colors.white,
                child: GestureDetector(
                  key: child,
                  behavior: HitTestBehavior.opaque,
                  onLongPress: () => presses++,
                  child: const Text('已落定的正文'),
                ),
              ),
            ),
          ),
        ),
      );
      final sheet = find.byType(ReaderSheetMotion);
      final geometry = tester.renderObject<ReaderSheetMotionRender>(sheet);
      expect(geometry.displacement, Offset.zero);
      expect(tester.getTopLeft(find.byKey(child)), tester.getTopLeft(sheet));
      await tester.longPressAt(tester.getCenter(sheet));
      expect(presses, 1);
    });
  }

  for (final width in [390.0, 1280.0]) {
    test('short stroke commits and tiny adjustment cancels at width $width', () {
      final physics = ReaderPagePhysics(origin: () => 2);
      PageMetrics metrics(double dx) => PageMetrics(
        minScrollExtent: 0,
        maxScrollExtent: width * 5,
        pixels: width * 2 + dx,
        viewportDimension: width,
        axisDirection: AxisDirection.right,
        viewportFraction: 1,
        devicePixelRatio: 1,
      );
      double end(double dx, [double velocity = 0]) =>
          physics.createBallisticSimulation(metrics(dx), velocity)!.x(30);
      expect(end(60), closeTo(width * 3, .1));
      expect(end(-60), closeTo(width, .1));
      expect(end(12), closeTo(width * 2, .1));
      expect(end(-12), closeTo(width * 2, .1));
      expect(end(15, 500), closeTo(width * 3, .1));
      expect(
        end(60, -500),
        closeTo(width * 2, .1),
        reason:
            'Reversing before crossing the origin cancels, not skips to the previous page.',
      );
      for (final sign in [-1.0, 1.0]) {
        final snap = physics.createBallisticSimulation(
          metrics(sign * (width - 5)),
          sign * 2400,
        )!;
        final target = width * (2 + sign);
        for (var i = 0; i < 120; i++) {
          expect(
            (snap.x(i / 120) - target) * sign,
            lessThanOrEqualTo(.0001),
            reason: 'A landing never exposes a third page.',
          );
        }
      }
      final idle = ReaderPagePhysics(
        origin: () => null,
      ).createBallisticSimulation(metrics(width * .8), 0)!;
      expect(idle.x(30), closeTo(width * 3, .1));
    });
  }

  Future<int> paintedPixels(WidgetTester tester, GlobalKey key) async {
    final render =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await render.toImage(pixelRatio: .5);
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    var colored = 0;
    for (var i = 0; i < bytes.lengthInBytes; i += 4) {
      // The decoded fixture's blue/green ink, not the blank reading paper.
      if (bytes.getUint8(i + 1) - bytes.getUint8(i) > 12 &&
          bytes.getUint8(i) < 180) {
        colored++;
      }
    }
    image.dispose();
    return colored;
  }

  for (final mode in [ReaderMode.paged, ReaderMode.vertical]) {
    testWidgets(
      'low-performance ${mode.name} keeps the new illustration painted after a swipe',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final bytes = (await tester.runAsync(coverFixtureBytes))!;
        final cache = ReaderIllustrationCache(request: (_) async => bytes);
        final controller = ReaderPagedController();
        final boundary = GlobalKey();
        final content = ReaderContent([
          for (var i = 0; i < 3; i++)
            '<!--image-->https://www.wenku8.net/fixture-$i.png<!--image-->',
        ]);
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: const MediaQueryData(
                size: Size(390, 844),
                disableAnimations: true,
              ),
              child: RepaintBoundary(
                key: boundary,
                child: Material(
                  color: const Color(0xfff6f5ef),
                  child: ReaderPagedView(
                    content: content,
                    preferences: ReaderPreferences(mode: mode),
                    style: const TextStyle(fontSize: 19, height: 1.72),
                    controller: controller,
                    title: '插图',
                    padding: const EdgeInsets.fromLTRB(26, 56, 26, 40),
                    reduceMotion: true,
                    onReady: () {},
                    onChanged: () {},
                    onUserScroll: () {},
                    onBoundary: (_) {},
                    pageBuilder: (page) => ReaderIllustration(
                      url: readerIllustrationUrl(page.fragments.single.text)!,
                      cache: cache,
                      fitPage: true,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await settleReader(tester);
        Future<void> decode() async {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 100)),
          );
          await tester.pumpAndSettle();
        }

        await decode();
        expect(controller.pageCount, 3);
        expect(
          await tester.runAsync(() => paintedPixels(tester, boundary)),
          greaterThan(1000),
        );
        final view = find.byType(PageView);
        final gesture = await tester.startGesture(tester.getCenter(view));
        await gesture.moveBy(Offset(mode == ReaderMode.vertical ? 90 : -90, 0));
        await tester.pump(const Duration(milliseconds: 200));
        await gesture.up();
        await settleReader(tester);
        await decode();
        expect(controller.page, 1);
        final visible = tester
            .widgetList<ReaderPageAnchor>(find.byType(ReaderPageAnchor))
            .where((a) => a.visible)
            .toList();
        expect(visible.map((a) => a.index), [1]);
        expect(
          await tester.runAsync(() => paintedPixels(tester, boundary)),
          greaterThan(1000),
        );
        await tester.pump(const Duration(seconds: 2));
        expect(
          await tester.runAsync(() => paintedPixels(tester, boundary)),
          greaterThan(1000),
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'reduced-motion illustration gallery retains decoded images after paging and rebuild',
    (tester) async {
      final bytes = (await tester.runAsync(coverFixtureBytes))!;
      final cache = ReaderIllustrationCache(request: (_) async => bytes);
      final boundary = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: novelTheme(Brightness.light),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!,
          ),
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
      Future<void> decodeGallery() async {
        for (var i = 0; i < 4; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)),
          );
          await tester.pumpAndSettle();
        }
      }

      await decodeGallery();
      await captureReview(tester, boundary, 'low-performance-gallery');
      expect(
        await tester.runAsync(() => paintedPixels(tester, boundary)),
        greaterThan(1000),
      );
      await tester.drag(find.byType(PageView), const Offset(-500, 0));
      await tester.pumpAndSettle();
      await decodeGallery();
      expect(find.text('IMAGE / 2 OF 2'), findsOneWidget);
      expect(
        await tester.runAsync(() => paintedPixels(tester, boundary)),
        greaterThan(1000),
      );
      await tester.pump(const Duration(seconds: 2));
      expect(
        await tester.runAsync(() => paintedPixels(tester, boundary)),
        greaterThan(1000),
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final effect in ReaderPageEffect.values) {
    for (final mode in [ReaderMode.paged, ReaderMode.vertical]) {
      testWidgets(
        '${effect.name} ${mode.name} turns horizontally and retains its laid-out leaves',
        (tester) async {
          tester.view.physicalSize = Size(
            mode == ReaderMode.vertical ? 390 : 1280,
            844,
          );
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final controller = ReaderPagedController();
          final glyphs = ReaderGlyphCache();
          addTearDown(glyphs.dispose);
          final boundary = GlobalKey();
          const style = TextStyle(
            fontFamily: 'Roboto',
            fontSize: 19,
            height: 1.72,
            color: Color(0xff36383b),
          );
          await tester.pumpWidget(
            MaterialApp(
              theme: novelTheme(Brightness.light),
              home: RepaintBoundary(
                key: boundary,
                child: Material(
                  color: const Color(0xffede2ca),
                  child: ReaderPagedView(
                    content: ReaderContent(
                      List.generate(
                        160,
                        (i) =>
                            '第 ${i + 1} 段。风吹过书页，故事沿着阅读的顺序展开。翻过这一页，下一段故事安静地接续。',
                      ),
                    ),
                    preferences: ReaderPreferences(
                      mode: mode,
                      pageEffect: effect,
                      paper: ReaderPaper.parchment,
                    ),
                    style: style,
                    controller: controller,
                    title: '书页与光',
                    padding: const EdgeInsets.fromLTRB(26, 56, 26, 40),
                    onReady: () {},
                    onChanged: () {},
                    onUserScroll: () {},
                    onBoundary: (_) {},
                    pageBuilder: (leaf) => mode == ReaderMode.vertical
                        ? ReaderVerticalText(
                            page: leaf,
                            style: style,
                            glyphCache: glyphs,
                          )
                        : Stack(
                            children: [
                              for (final (i, fragment)
                                  in leaf.fragments.indexed)
                                Positioned.fromRect(
                                  rect: fragment.rect,
                                  child: ReaderFragmentMotion(
                                    fragment: fragment,
                                    index: i,
                                    count: leaf.fragments.length,
                                    child: Text(fragment.text, style: style),
                                  ),
                                ),
                            ],
                          ),
                  ),
                ),
              ),
            ),
          );
          await settleReader(tester);
          final generation = controller.debugLayoutGeneration;
          final measurements = controller.debugParagraphMeasurements;
          final view = find.byType(PageView);
          expect(
            tester.widget<PageView>(view).scrollDirection,
            Axis.horizontal,
          );
          final gesture = await tester.startGesture(tester.getCenter(view));
          final dx = mode == ReaderMode.vertical ? 1.0 : -1.0;
          await gesture.moveBy(
            Offset(tester.getSize(view).width * .47 * dx, 0),
          );
          await tester.pump();
          await tester.pump();
          if (effect == ReaderPageEffect.paper ||
              effect == ReaderPageEffect.cover) {
            final folds = tester
                .renderObjectList<ReaderSheetMotionRender>(
                  find.byType(ReaderSheetMotion),
                )
                .toList();
            final layouts = folds.map((f) => f.debugLayoutCount).toList();
            await captureReview(
              tester,
              boundary,
              '${effect.name}-${mode.name}-half',
            );
            await gesture.moveBy(Offset(12 * dx, 0));
            await tester.pump();
            expect(folds.map((f) => f.debugLayoutCount).toList(), layouts);
          }
          await gesture.up();
          await tester.pumpAndSettle();
          expect(controller.page, controller.pagesPerSpread);
          expect(controller.debugLayoutGeneration, generation);
          expect(controller.debugParagraphMeasurements, measurements);
          controller.pageBy(-1);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 180));
          if (effect == ReaderPageEffect.paper ||
              effect == ReaderPageEffect.cover) {
            await captureReview(
              tester,
              boundary,
              '${effect.name}-${mode.name}-back',
            );
          }
          await tester.pumpAndSettle();
          expect(controller.page, 0);
          expect(controller.debugLayoutGeneration, generation);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
