import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/reader_content.dart';
import 'package:wenku8_flutter/reader_paged_view.dart';
import 'package:wenku8_flutter/reader_preferences.dart';
import 'package:wenku8_flutter/reader_reflow.dart';
import 'package:wenku8_flutter/reader_turn_motion.dart';
import 'package:wenku8_flutter/reader_vertical_text.dart';
import 'reader_modes_test.dart' as fixture;
import 'support/visual_review.dart';

void main({
  bool configureView = true,
  Future<void> Function(WidgetTester, GlobalKey, String)? capture,
}) {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadReviewFonts);
  for (final mode in [ReaderMode.paged, ReaderMode.vertical]) {
    testWidgets(
      '${mode.name} reflow keeps the current page and reveals only the extension',
      (tester) async {
        if (configureView) {
          tester.view.physicalSize = const Size(348, 754);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
        }
        final padding = ValueNotifier(
          const EdgeInsets.fromLTRB(24, 108, 24, 110),
        );
        final controller = ReaderPagedController();
        final cache = ReaderGlyphCache();
        addTearDown(cache.dispose);
        addTearDown(padding.dispose);
        final content = ReaderContent(fixture.paragraphs);
        final boundary = GlobalKey();
        const style = TextStyle(
          fontSize: 19,
          height: 1.72,
          color: Colors.black,
          inherit: false,
        );
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundary,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: novelTheme(Brightness.light),
              home: ColoredBox(
                color: const Color(0xfff4f2eb),
                child: ValueListenableBuilder(
                  valueListenable: padding,
                  builder: (context, value, _) => ReaderPagedView(
                    content: content,
                    preferences: ReaderPreferences(mode: mode),
                    style: style,
                    controller: controller,
                    title: '同一页的增量过渡',
                    padding: value,
                    onReady: () {},
                    onChanged: () {},
                    onUserScroll: () {},
                    onBoundary: (_) {},
                    pageBuilder: (page) => mode == ReaderMode.vertical
                        ? ReaderVerticalText(
                            page: page,
                            style: style,
                            glyphCache: cache,
                          )
                        : Stack(
                            children: [
                              for (final f in page.fragments)
                                Positioned.fromRect(
                                  rect: f.rect,
                                  child: Text(
                                    '${f.indent ? '\u3000\u3000' : ''}${f.text}',
                                    style: style,
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
        await fixture.settleReader(tester);
        controller.seek(.4);
        await fixture.settleReader(tester);
        final old = controller.debugLeaf!, oldSize = controller.pageSize!;
        final generation = controller.debugLayoutGeneration;
        final oldOrigin = tester.getTopLeft(find.byType(PageView));
        padding.value = const EdgeInsets.fromLTRB(24, 40, 24, 32);
        for (var i = 0; i < 100; i++) {
          await tester.pump(const Duration(milliseconds: 1));
          if (controller.ready &&
              controller.debugLayoutGeneration > generation) {
            break;
          }
        }
        expect(controller.ready, true);
        expect(controller.anchor!.paragraph, old.anchor.paragraph);
        expect(controller.anchor!.offset, old.anchor.offset);
        expect(find.byType(RevealFromTop), findsNothing);
        expect(find.byType(ReaderSkeleton), findsNothing);
        final morphFinder = find.byType(ReaderIncrementalViewport);
        var morph = tester.widget<ReaderIncrementalViewport>(morphFinder);
        expect(morph.fromSize, Size(oldSize.width + 48, oldSize.height));
        expect(morph.toSize.height, greaterThan(oldSize.height));
        expect(
          tester.getTopLeft(morphFinder) + morph.viewportAt(0).topLeft,
          oldOrigin,
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 80));
        morph = tester.widget<ReaderIncrementalViewport>(morphFinder);
        if (morph.animation.value < 1) {
          expect(morph.animation.value, greaterThan(0));
          expect(
            morph.viewportAt(morph.animation.value).height,
            inExclusiveRange(oldSize.height, morph.toSize.height),
          );
          if (mode == ReaderMode.vertical) {
            final next = controller.debugLeaf!;
            final before = {
              for (final g in old.glyphs)
                (g.paragraph, g.sourceStart, g.sourceEnd): g,
            };
            final first = next.glyphs.first;
            expect(
              first.rect,
              before[(first.paragraph, first.sourceStart, first.sourceEnd)]!
                  .rect,
            );
            final render = tester.renderObject<RenderReaderVerticalText>(
              find.byType(ReaderVerticalText).first,
            );
            expect(render.debugColumnCount, greaterThan(1));
            expect(
              render.debugColumnProgress(0),
              greaterThan(
                render.debugColumnProgress(render.debugColumnCount - 1),
              ),
            );
            expect(
              render.debugColumnDisplacement(render.debugColumnCount - 1),
              isNot(Offset.zero),
            );
          }
          await capture?.call(
            tester,
            boundary,
            '${mode.name}-incremental-extension',
          );
        }
        await fixture.settleReader(tester);
        expect(controller.debugLayoutGeneration, generation + 1);
        await capture?.call(
          tester,
          boundary,
          '${mode.name}-incremental-complete',
        );
        padding.value = const EdgeInsets.fromLTRB(24, 108, 24, 110);
        await fixture.settleReader(tester);
        expect(controller.anchor!.paragraph, old.anchor.paragraph);
        expect(controller.anchor!.offset, old.anchor.offset);
        expect(controller.debugLayoutGeneration, generation + 2);
        expect(find.byType(RevealFromTop), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  for (final mode in [ReaderMode.paged, ReaderMode.vertical]) {
    testWidgets(
      '${mode.name} tap-page staggers content without a masked page plane or repagination',
      (tester) async {
        final state = await fixture.library(mode);
        addTearDown(state.dispose);
        await state.setReduceMotion(false);
        await tester.pumpWidget(fixture.app(state));
        await fixture.settleReader(tester);
        final controller = tester
            .widget<ReaderPagedView>(find.byType(ReaderPagedView))
            .controller;
        final generation = controller.debugLayoutGeneration;
        expect(controller.pageBy(1), true);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 70));
        final incoming = find.byKey(const ValueKey('reader-turn-incoming'));
        expect(incoming, findsOneWidget);
        final transition = tester
            .widgetList<ReaderTurnScope>(find.byType(ReaderTurnScope))
            .firstWhere((scope) => scope.enabled && !scope.outgoing);
        expect(transition.animation.value, inExclusiveRange(0, 1));
        expect(transition.direction, mode == ReaderMode.vertical ? -1 : 1);
        expect(controller.debugLayoutGeneration, generation);
        await fixture.settleReader(tester);
        expect(controller.page, controller.pagesPerSpread);
        expect(
          find.byWidgetPredicate((w) => w is ReaderTurnScope && w.enabled),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'hidden scrolling clips text below the persistent status-bar safe area',
    (tester) async {
      if (configureView) {
        tester.view.physicalSize = const Size(348, 754);
        tester.view.devicePixelRatio = 1;
        tester.view.padding = const FakeViewPadding(top: 32, bottom: 24);
        tester.view.viewPadding = const FakeViewPadding(top: 32, bottom: 24);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPadding);
        addTearDown(tester.view.resetViewPadding);
      }
      final state = await fixture.library(ReaderMode.scroll);
      addTearDown(state.dispose);
      final boundary = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(key: boundary, child: fixture.app(state)),
      );
      await fixture.settleReader(tester);
      await tester.tapAt(const Offset(174, 340));
      await fixture.settleReader(tester);
      final safe = find.byKey(const ValueKey('reader-scroll-safe-viewport'));
      final top = MediaQuery.viewPaddingOf(tester.element(safe)).top;
      expect(
        tester.getTopLeft(safe).dy,
        top + state.readerPreferences.marginTop,
      );
      expect(
        tester.renderObject<RenderClipRect>(safe).clipBehavior,
        Clip.hardEdge,
      );
      final scroll = find.byKey(const ValueKey('reader-scroll'));
      await tester.drag(scroll, const Offset(0, -483));
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(scroll).dy,
        top + state.readerPreferences.marginTop,
      );
      await capture?.call(tester, boundary, 'scroll-hidden-status-safe-area');
      expect(tester.takeException(), isNull);
    },
  );
}
