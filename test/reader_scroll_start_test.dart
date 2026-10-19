import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/pages.dart';
import 'package:wenku8_flutter/reader_content.dart';
import 'package:wenku8_flutter/reader_scroll_sliver.dart';
import 'support/offline_fixture.dart';
import 'support/visual_review.dart';

void main({Future<void> Function(WidgetTester, GlobalKey, String)? capture}) {
  setUpAll(loadReviewFonts);
  testWidgets('deep scroll resume only lays out the restored viewport', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final state = await LibraryState.load();
    addTearDown(state.dispose);
    final book = Novel(
      id: 10601,
      title: 'Long chapter',
      author: '',
      genre: '',
      summary: '',
      colors: const [Colors.grey, Colors.black],
      chapters: [
        NovelChapter(
          'Chapter',
          List.generate(
            600,
            (i) =>
                'Paragraph $i. The morning sunlight falls across the open book. A quiet chapter continues here.',
          ).join('\n\n'),
          id: 101,
        ),
      ],
    );
    final boundary = GlobalKey();
    Future<void> openReader() async {
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: novelTheme(Brightness.light),
            home: ReaderPage(
              novel: book,
              state: state,
              repository: const DemoNovelRepository(),
              initialChapter: 0,
            ),
          ),
        ),
      );
      for (var frame = 0; frame < 20; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.pumpAndSettle();
    }

    ReaderParagraphRegistry registryOf() => tester
        .widget<ReaderParagraph>(find.byType(ReaderParagraph).first)
        .registry;
    ScrollPosition scrollOf() => tester
        .state<ScrollableState>(
          find
              .descendant(
                of: find.byKey(const ValueKey('reader-scroll')),
                matching: find.byType(Scrollable),
              )
              .first,
        )
        .position;
    Future<void> closeReader() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    }

    addTearDown(() => ReaderScrollAnchor.debugDisableSourceAnchors = false);
    // Obtain a real saved position from this exact font, width and content,
    // rather than inventing pixel offsets for a source paragraph.
    await openReader();
    final inset =
        FrostedHeader.toolbarHeight + 12 - state.readerPreferences.marginTop;
    for (var attempt = 0; attempt < 6; attempt++) {
      final target = registryOf().target((index: 400, fraction: .3), inset)!;
      scrollOf().jumpTo(target.offset.clamp(0.0, double.infinity));
      await tester.pumpAndSettle();
      if (target.exact) break;
    }
    final actualPixels = scrollOf().pixels;
    final actualParagraph = tester.getRect(
      find.byKey(const ValueKey('paragraph-400')),
    );
    await closeReader();
    expect(state.positionFor(book.id)!.paragraphIndex, 400);
    ReaderScrollAnchor.debugDisableSourceAnchors = true;
    await openReader();
    final baselineMounts = registryOf().debugParagraphMounts;
    expect(baselineMounts, greaterThan(350));
    if (capture != null) {
      await capture(tester, boundary, 'reader-resume-reference');
    }
    await closeReader();
    ReaderScrollAnchor.debugDisableSourceAnchors = false;
    await openReader();
    final registry = registryOf(), scroll = scrollOf();
    // ignore: avoid_print
    print(
      'READER_RESUME_MOUNTS baseline=$baselineMounts optimized=${registry.debugParagraphMounts}',
    );
    expect(registry.debugParagraphMounts, lessThan(80));
    expect(scroll.pixels, closeTo(actualPixels, 1));
    final landed = tester.getRect(find.byKey(const ValueKey('paragraph-400')));
    expect(landed.top, closeTo(actualParagraph.top, 1));
    expect(landed.top, lessThan(180));
    expect(landed.bottom, greaterThan(80));
    if (capture != null) {
      await capture(tester, boundary, 'reader-indexed-resume');
    } else {
      await captureReview(tester, boundary, 'reader-indexed-resume');
    }
    await tester.drag(
      find.byKey(const ValueKey('reader-scroll')),
      const Offset(0, -480),
    );
    await tester.pumpAndSettle();
    expect(registry.debugParagraphMounts, lessThan(100));
    scroll.jumpTo(0);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('paragraph-0')), findsOneWidget);
    expect(scroll.pixels, 0);
    expect(registry.debugParagraphMounts, lessThan(120));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets(
    'adjacent chapter work waits for the route and paragraph reveal, then completes',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final state = await LibraryState.load();
      final repository = OfflineFixtureRepository();
      final navigator = GlobalKey<NavigatorState>();
      addTearDown(state.dispose);
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          theme: novelTheme(Brightness.light),
          home: const SizedBox(),
        ),
      );
      navigator.currentState!.push(
        softRoute<void>(
          ReaderPage(
            novel: repository.books[71]!,
            state: state,
            repository: repository,
            initialChapter: 1,
          ),
        ),
      );
      for (var frame = 0; frame < 8; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      expect(repository.calls.where((c) => c.startsWith('text:')).length, 1);
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pumpAndSettle();
      expect(repository.calls.where((c) => c.startsWith('text:')).length, 3);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
