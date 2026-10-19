import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/reader_panels.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/glass_palette.dart';
import 'package:wenku8_flutter/listening/controller.dart';
import 'package:wenku8_flutter/listening/store.dart';
import 'package:wenku8_flutter/listening/widgets.dart';
import 'package:wenku8_flutter/reader_appearance.dart';
import 'package:wenku8_flutter/reader_book_layout.dart';
import 'package:wenku8_flutter/reader_paged_view.dart';
import 'package:wenku8_flutter/reader_preferences.dart';
import 'package:wenku8_flutter/reader_tools.dart';
import 'package:wenku8_flutter/reader_turn_motion.dart';

import 'reader_modes_test.dart' as fixture;
import 'support/listening_fixture.dart';
import 'support/visual_review.dart';

void main({
  bool native = false,
  Future<void> Function(WidgetTester, GlobalKey, String)? capture,
}) {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (!native) setUpAll(loadReviewFonts);
  void window(WidgetTester tester, Size size) {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    tester.view.padding = const FakeViewPadding(top: 28, bottom: 24);
    tester.view.viewPadding = tester.view.padding;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);
  }

  Future<void> shot(WidgetTester tester, GlobalKey key, String name) async {
    if (capture == null) {
      await captureReview(tester, key, name);
    } else {
      await capture(tester, key, name);
    }
  }

  for (final brightness in Brightness.values) {
    testWidgets(
      '${brightness.name} reader paper colors update chrome and an open settings surface',
      (tester) async {
        window(tester, const Size(390, 844));
        final library = await fixture.library(ReaderMode.paged);
        addTearDown(library.dispose);
        final key = GlobalKey();
        final app = fixture.app(library) as MaterialApp;
        await tester.pumpWidget(
          RepaintBoundary(
            key: key,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: novelTheme(brightness),
              home: app.home,
            ),
          ),
        );
        await fixture.settleReader(tester);
        final paged = tester
            .widget<ReaderPagedView>(find.byType(ReaderPagedView))
            .controller;
        final generation = paged.debugLayoutGeneration;
        await tester.tap(
          find.byWidgetPredicate(
            (w) => w is GlassIconButton && w.label == '阅读设置',
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(ReaderTools), findsOneWidget);
        for (final paper in [
          ReaderPaper.parchment,
          ReaderPaper.sage,
          ReaderPaper.night,
          ReaderPaper.milk,
          ReaderPaper.system,
        ]) {
          await library.setReaderPreferences(
            library.readerPreferences.copyWith(paper: paper),
          );
          await fixture.settleReader(tester);
          final expected = readerTheme(
            novelTheme(brightness),
            library.readerPreferences,
          );
          final dock = Theme.of(
            tester.element(find.byKey(const ValueKey('reader-liquid-dock'))),
          );
          final sheet = Theme.of(tester.element(find.byType(ReaderTools)));
          expect(dock.colorScheme.surface, expected.colorScheme.surface);
          expect(sheet.colorScheme.surface, expected.colorScheme.surface);
          expect(sheet.brightness, expected.brightness);
          expect(
            dock.extension<GlassPalette>()!.tint,
            expected.extension<GlassPalette>()!.tint,
          );
          final slider = tester.widget<AppGlassSlider>(
            find.byKey(const ValueKey('reader-font-slider')),
          );
          expect(slider.thumbColor, expected.extension<GlassPalette>()!.thumb);
          expect(
            slider.style.color.withValues(alpha: 1),
            expected.extension<GlassPalette>()!.tint,
          );
          expect(
            paged.debugLayoutGeneration,
            generation,
            reason:
                'Paper colors repaint text; they do not paginate a chapter again.',
          );
          if (paper == ReaderPaper.night || paper == ReaderPaper.sage) {
            await shot(
              tester,
              key,
              'paper-${brightness.name}-${paper.name}-settings',
            );
          }
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('reader paper colors update an open listening surface', (
    tester,
  ) async {
    window(tester, const Size(390, 844));
    final library = await fixture.library(ReaderMode.paged);
    addTearDown(library.dispose);
    final controller = ListeningController(
      repository: const DemoNovelRepository(),
      audio: FakeSpeechAudio(),
      store: ListeningStore(await SharedPreferences.getInstance()),
      outputFactory: (_) async => FakeListeningOutput(),
    );
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: ListeningScope(
          controller: controller,
          child: fixture.app(library),
        ),
      ),
    );
    await fixture.settleReader(tester);
    await openReaderPanel(tester, tab: '听书');
    for (final paper in [ReaderPaper.night, ReaderPaper.parchment]) {
      await library.setReaderPreferences(
        library.readerPreferences.copyWith(paper: paper),
      );
      await fixture.settleReader(tester);
      final expected = readerTheme(
        novelTheme(Brightness.light),
        library.readerPreferences,
      );
      final panel = Theme.of(tester.element(find.byType(ListeningPanel)));
      expect(panel.colorScheme.surface, expected.colorScheme.surface);
      expect(panel.colorScheme.onSurface, expected.colorScheme.onSurface);
      final speed = tester.widget<AppGlassSlider>(
        find.byKey(const ValueKey('listening-speed')),
      );
      expect(speed.thumbColor, expected.extension<GlassPalette>()!.thumb);
      expect(
        speed.style.color.withValues(alpha: 1),
        expected.extension<GlassPalette>()!.tint,
      );
      await shot(tester, key, 'paper-${paper.name}-listening');
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    final closing = controller.dispose();
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1)),
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
    await closing;
  });

  for (final wide in [false, true]) {
    testWidgets(
      '${wide ? 'book' : 'phone'} horizontal vertical mode switch retains the old layout and animates new parts',
      (tester) async {
        window(tester, Size(wide ? 1024 : 390, 844));
        final library = await fixture.library(ReaderMode.paged);
        await library.setReduceMotion(false);
        addTearDown(library.dispose);
        final key = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(key: key, child: fixture.app(library)),
        );
        await fixture.settleReader(tester);
        final paged = tester
            .widget<ReaderPagedView>(find.byType(ReaderPagedView))
            .controller;
        paged.seek(.3);
        await fixture.settleReader(tester);
        var previous = ReaderMode.paged;
        for (final mode in [ReaderMode.vertical, ReaderMode.paged]) {
          final anchor = paged.anchor!,
              generation = paged.debugLayoutGeneration;
          await library.setReaderPreferences(
            library.readerPreferences.copyWith(mode: mode),
          );
          for (var i = 0; i < 200; i++) {
            await tester.pump(const Duration(milliseconds: 1));
            if (paged.ready && paged.debugLayoutGeneration > generation) break;
          }
          await tester.pump();
          final incoming = find.byKey(const ValueKey('reader-mode-incoming'));
          expect(incoming, findsOneWidget);
          final scope = tester.widget<ReaderTurnScope>(incoming);
          expect(scope.animation.value, lessThan(1));
          final oldBook = tester.widget<ReaderBookSpread>(
            find.descendant(
              of: find.byKey(const ValueKey('reader-mode-outgoing')),
              matching: find.byType(ReaderBookSpread),
            ),
          );
          expect(oldBook.rightToLeft, previous == ReaderMode.vertical);
          expect(find.byType(ReaderSkeleton), findsNothing);
          await tester.pump(const Duration(milliseconds: 120));
          await shot(
            tester,
            key,
            'mode-${wide ? 'book' : 'phone'}-${mode.name}',
          );
          await tester.pumpAndSettle();
          expect(
            paged.debugLeaf!.fragments.any(
              (f) =>
                  f.paragraph == anchor.paragraph &&
                  f.start <= anchor.offset &&
                  anchor.offset < f.end,
            ),
            true,
          );
          expect(paged.debugLayoutGeneration, generation + 1);
          expect(
            find.byKey(const ValueKey('reader-mode-outgoing')),
            findsNothing,
          );
          expect(tester.binding.transientCallbackCount, 0);
          previous = mode;
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
