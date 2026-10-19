import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/reader_panels.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/listening/controller.dart';
import 'package:wenku8_flutter/listening/store.dart';
import 'package:wenku8_flutter/listening/widgets.dart';
import 'package:wenku8_flutter/reader_paged_view.dart';
import 'package:wenku8_flutter/reader_chrome.dart';
import 'package:wenku8_flutter/reader_preferences.dart';
import 'package:wenku8_flutter/reader_vertical_text.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/pages.dart';
import 'reader_modes_test.dart' as fixture;
import 'support/listening_fixture.dart';
import 'support/visual_review.dart';

Finder control(String label) =>
    find.byWidgetPredicate((w) => w is GlassIconButton && w.label == label);
Finder key(String value) => find.byKey(ValueKey(value));

void main({
  Future<void> Function(WidgetTester, GlobalKey, String)? capture,
  bool configureView = true,
}) {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadReviewFonts);
  Future<GlobalKey> showReader(
    WidgetTester tester,
    LibraryState state, {
    double scale = 1,
    ListeningController? listening,
  }) async {
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
    final boundary = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: novelTheme(Brightness.light),
          scrollBehavior: const NovelScrollBehavior(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: ListeningScope(controller: listening, child: child!),
          ),
          home: ReaderPage(
            novel: fixture.book,
            state: state,
            repository: const DemoNovelRepository(),
            initialChapter: 0,
          ),
        ),
      ),
    );
    await fixture.settleReader(tester);
    return boundary;
  }

  for (final mode in [ReaderMode.paged, ReaderMode.vertical]) {
    testWidgets(
      '${mode.name} expands once as chrome starts hiding, without blocking its blur motion',
      (tester) async {
        final state = await fixture.library(mode);
        addTearDown(state.dispose);
        await state.setReduceMotion(false);
        final boundary = await showReader(tester, state);
        final controller = tester
            .widget<ReaderPagedView>(find.byType(ReaderPagedView))
            .controller;
        final size = controller.pageSize!;
        final generation = controller.debugLayoutGeneration;
        final media = MediaQuery.of(
          tester.element(find.byType(ReaderPagedView)),
        );
        expect(
          size.height,
          greaterThan((media.size.height - media.padding.vertical) * .65),
        );
        expect(
          size.width,
          media.size.width -
              media.padding.horizontal -
              state.readerPreferences.margin * 2,
        );
        final pageRect = tester.getRect(find.byType(PageView));
        expect(
          pageRect.top,
          greaterThan(tester.getRect(key('reader-chrome-header')).bottom),
        );
        expect(
          pageRect.bottom,
          lessThanOrEqualTo(tester.getRect(key('reader-chrome-dock')).top),
          reason:
              'The page may meet the dock boundary but must never overlap it.',
        );
        if (capture != null) {
          await capture(tester, boundary, '${mode.name}-chrome');
        }
        final chrome = tester
            .widget<ReaderChromeLayer>(key('reader-chrome-header'))
            .animation;
        var sawIntermediateBlur = false;
        await tester.tapAt(const Offset(174, 340));
        for (var frame = 0; frame < 20; frame++) {
          await tester.pump(const Duration(milliseconds: 12));
          final header = key('reader-chrome-header');
          for (final opacity
              in find
                  .descendant(of: header, matching: find.byType(Opacity))
                  .evaluate()) {
            expect(
              (opacity.widget as Opacity).opacity,
              anyOf(0.0, 1.0),
              reason:
                  'No fractional-opacity subpass may surround live toolbar glass.',
            );
          }
          // The content starts expanding alongside the toolbar fade. Repeated
          // blur-animation ticks must not repaginate the chapter again.
          expect(
            controller.debugLayoutGeneration,
            inInclusiveRange(generation, generation + 1),
          );
          final blurs = find.descendant(
            of: find.byType(ReaderEdgeBlur),
            matching: find.byType(ProgressiveBlur),
          );
          if (blurs.evaluate().isNotEmpty) {
            final sigma = tester.widget<ProgressiveBlur>(blurs.first).maxSigma;
            sawIntermediateBlur |= sigma > 0 && sigma < 8;
          }
          if (capture != null &&
              chrome.status != AnimationStatus.dismissed &&
              [1, 8, 14].contains(frame)) {
            await capture(tester, boundary, '${mode.name}-hiding-$frame');
          }
        }
        expect(sawIntermediateBlur, true);
        await fixture.settleReader(tester);
        expect(control('阅读设置'), findsNothing);
        expect(controller.debugLayoutGeneration, generation + 1);
        expect(
          controller.pageSize!.height,
          greaterThan((media.size.height - media.padding.vertical) * .85),
        );
        expect(
          find.descendant(
            of: find.byType(ReaderEdgeBlur),
            matching: find.byType(ProgressiveBlur),
          ),
          findsNothing,
        );
        if (capture != null) {
          await capture(tester, boundary, '${mode.name}-full-page');
        }
        await tester.tapAt(const Offset(174, 340));
        await fixture.settleReader(tester);
        expect(control('阅读设置'), findsOneWidget);
        expect(controller.debugLayoutGeneration, generation + 2);
        expect(controller.pageSize, size);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'every horizontal fragment contains its complete rendered lines',
    (tester) async {
      final state = await fixture.library(ReaderMode.paged);
      addTearDown(state.dispose);
      await showReader(tester, state);
      final controller = tester
          .widget<ReaderPagedView>(find.byType(ReaderPagedView))
          .controller;
      for (var page = 0; page < controller.pageCount; page++) {
        controller.seek(
          controller.pageCount == 1 ? 0 : page / (controller.pageCount - 1),
        );
        await fixture.settleReader(tester);
        final paragraphs = find.descendant(
          of: find.byType(PageView),
          matching: find.byType(RichText),
        );
        for (final element in paragraphs.evaluate()) {
          final render = element.renderObject! as RenderParagraph;
          final naturalHeight = render.getMaxIntrinsicHeight(render.size.width);
          expect(naturalHeight, lessThanOrEqualTo(render.size.height + .1));
        }
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'narrow reader settings remain aligned at double system text size',
    (tester) async {
      final state = await fixture.library(ReaderMode.vertical);
      addTearDown(state.dispose);
      await showReader(tester, state, scale: 2);
      await tester.tap(control('阅读设置'));
      await fixture.settleReader(tester);
      final panel = tester.getRect(find.byType(GlassOverlaySurface));
      for (final button
          in find
              .descendant(
                of: find.byType(GlassOverlaySurface),
                matching: find.byType(GlassTextButton),
              )
              .evaluate()) {
        final render = button.renderObject! as RenderBox;
        final rect = render.localToGlobal(Offset.zero) & render.size;
        expect(rect.left, greaterThanOrEqualTo(panel.left));
        expect(rect.right, lessThanOrEqualTo(panel.right));
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'settings keep their panel, choice buttons and active slider fixed during adjustments',
    (tester) async {
      final state = await fixture.library(ReaderMode.paged);
      addTearDown(state.dispose);
      final boundary = await showReader(tester, state);
      await tester.tap(control('阅读设置'));
      await fixture.settleReader(tester);
      final sheet = find.byType(GlassOverlaySurface);
      final panel = tester.getRect(sheet);
      final choice = tester.getRect(key('reader-mode-vertical'));
      await tester.tap(key('reader-mode-vertical'));
      await fixture.settleReader(tester);
      expect(tester.getRect(sheet), panel);
      expect(tester.getRect(key('reader-mode-vertical')), choice);
      final slider = key('reader-font-slider');
      await tester.ensureVisible(slider);
      await tester.pumpAndSettle();
      final element = tester.element(slider);
      final rect = tester.getRect(slider);
      final start = Offset(rect.left + rect.width * .4, rect.center.dy);
      final pointer = await tester.startGesture(start);
      await tester.pump();
      for (var frame = 0; frame < 12; frame++) {
        await pointer.moveTo(start + Offset(frame * 5.0, 0));
        await tester.pump(const Duration(milliseconds: 16));
        expect(tester.element(slider), same(element));
        expect(tester.getRect(slider), rect);
        expect(tester.getRect(sheet), panel);
        expect(
          find.descendant(
            of: find.byType(ReaderPagedView),
            matching: find.byType(ReaderSkeleton),
          ),
          findsNothing,
        );
      }
      expect(tester.widget<GlassOverlaySurface>(sheet).transparent, isTrue);
      if (capture != null) {
        await capture(tester, boundary, 'font-adjustment-stable');
      }
      await pointer.up();
      await fixture.settleReader(tester);
      expect(tester.widget<GlassOverlaySurface>(sheet).transparent, isFalse);
      expect(tester.getRect(slider), rect);
      if (capture != null) {
        await capture(tester, boundary, 'reader-settings-stable');
      }
      await tester.tap(control('关闭阅读设置'));
      await fixture.settleReader(tester);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'listening panel stays anchored while speed, follow and timer change',
    (tester) async {
      final state = await fixture.library(ReaderMode.scroll);
      addTearDown(state.dispose);
      final listening = ListeningController(
        repository: const DemoNovelRepository(),
        audio: FakeSpeechAudio(),
        store: ListeningStore(await SharedPreferences.getInstance()),
        outputFactory: (_) async => FakeListeningOutput(),
      );
      final boundary = await showReader(tester, state, listening: listening);
      await openReaderPanel(tester, tab: '听书');
      await fixture.settleReader(tester);
      final sheet = find.byType(GlassOverlaySurface);
      final panel = tester.getRect(sheet);
      final speed = key('listening-speed');
      await tester.ensureVisible(speed);
      await tester.pumpAndSettle();
      final original = tester.getRect(speed);
      final slider = tester.widget<AppGlassSlider>(speed);
      slider.onChangeStart!(slider.value);
      slider.onChanged!(1.35);
      await tester.pump();
      expect(tester.getRect(speed), original);
      slider.onChangeEnd!(1.35);
      await fixture.listeningIo(tester);
      expect(tester.getRect(sheet), panel);
      expect(tester.getRect(speed), original);
      await listening.setFollow(false);
      listening.setSleep(duration: const Duration(minutes: 15));
      await fixture.listeningIo(tester);
      expect(tester.getRect(sheet), panel);
      expect(tester.getRect(speed), original);
      if (capture != null) {
        await capture(tester, boundary, 'listening-controls-stable');
      }
      await tester.pumpWidget(const SizedBox.shrink());
      final closing = listening.dispose();
      await fixture.listeningIo(tester);
      await closing;
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('adjacent vertical pages share a bounded glyph-shaping cache', (
    tester,
  ) async {
    final state = await fixture.library(ReaderMode.vertical);
    addTearDown(state.dispose);
    await showReader(tester, state);
    final first = tester.widget<ReaderVerticalText>(
      find.byType(ReaderVerticalText).first,
    );
    final cache = first.glyphCache!;
    final shaped = cache.debugShapeCount;
    expect(shaped, greaterThan(0));
    final controller = tester
        .widget<ReaderPagedView>(find.byType(ReaderPagedView))
        .controller;
    controller.pageBy(1);
    await fixture.settleReader(tester);
    expect(
      tester
          .widget<ReaderVerticalText>(find.byType(ReaderVerticalText).first)
          .glyphCache,
      same(cache),
    );
    expect(
      cache.debugShapeCount - shaped,
      lessThan(12),
      reason: 'Repeated body glyphs must not be reshaped for each new page.',
    );
    debugPrint(
      'READER_GLYPH_CACHE first_page=$shaped next_page_new=${cache.debugShapeCount - shaped}',
    );
    expect(tester.takeException(), isNull);
  });
}
