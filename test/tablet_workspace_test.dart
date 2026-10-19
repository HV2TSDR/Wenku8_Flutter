import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/book_collection_layout.dart';
import 'package:wenku8_flutter/archive_shelf.dart';
import 'package:wenku8_flutter/archive_shelf_geometry.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/pages.dart';
import 'package:wenku8_flutter/reader_content.dart';
import 'package:wenku8_flutter/reader_paged_view.dart';
import 'package:wenku8_flutter/reader_pagination.dart';
import 'package:wenku8_flutter/reader_preferences.dart';
import 'package:wenku8_flutter/reader_turn_motion.dart';

import 'reader_modes_test.dart' show settleReader;
import 'support/visual_review.dart';

class _TabletBooks extends DemoNovelRepository {
  const _TabletBooks();
  @override
  Future<List<Novel>> list() async => [
    ...demoNovels,
    for (var i = 0; i < 32; i++)
      Novel(
        id: 72000 + i,
        title: ['风与远山的来信', '星海图书馆', '长夜之后，故事继续', '玻璃海岸'][i % 4],
        author: ['青木', '星野', '林见舟', '藤原'][i % 4],
        genre: '轻小说',
        summary: '尺寸适配用的本地测试目录。',
        colors: const [Color(0xFF373737), Color(0xFF686868)],
      ),
  ];
}

void main({
  bool native = false,
  Future<void> Function(WidgetTester, GlobalKey, String)? capture,
}) {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (!native) setUpAll(loadReviewFonts);
  setUp(
    () => SharedPreferences.setMockInitialValues({
      'readerChromeVisible': true,
      'readerChromeHintSeen': true,
      'reduceMotion': false,
    }),
  );
  Future<GlobalKey> mount(
    WidgetTester tester,
    Widget page, {
    Size size = const Size(1318, 824),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
    tester.view.viewPadding = tester.view.padding;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: novelTheme(Brightness.light),
          home: page,
        ),
      ),
    );
    await tester.pumpAndSettle();
    return key;
  }

  Future<void> shot(WidgetTester tester, GlobalKey key, String name) async {
    if (capture != null) {
      await capture(tester, key, name);
    } else {
      await captureReview(tester, key, name);
    }
  }

  testWidgets(
    'tablet centered browse becomes retained master detail and reader stays full window',
    (tester) async {
      final state = await LibraryState.load();
      expect(state.reduceMotion, false);
      addTearDown(state.dispose);
      final key = await mount(
        tester,
        HomeShell(state: state, repository: const _TabletBooks()),
      );
      final master = find.byKey(const ValueKey('library-master-pane'));
      expect(tester.getRect(master).center.dx, closeTo(659, .1));
      expect(tester.getSize(master).width, 1200);
      final discover = tester.element(find.byType(DiscoverPage));
      final bank = find.byWidgetPredicate(
        (widget) => widget.runtimeType.toString() == '_ShelfRow',
      );
      expect(tester.getSize(bank).width, ArchiveShelfGeometry.maxViewportWidth);
      final box = tester.renderObject<ArchiveBoxDepthRender>(
        find
            .byWidgetPredicate(
              (widget) => widget.runtimeType.toString() == '_BookVolume',
            )
            .first,
      );
      final coverSize = box.lastChild!.size;
      expect(box.debugTransform.entry(0, 0), ArchiveShelfGeometry.depthX);
      expect(box.debugTransform.entry(1, 0), ArchiveShelfGeometry.depthY);
      await shot(tester, key, 'tablet-browse-centered');
      await tester.ensureVisible(find.text('更多书籍'));
      await tester.pumpAndSettle();
      final rows = find.byType(NovelRow);
      expect(rows, findsAtLeastNWidgets(3));
      expect(tester.getRect(rows.at(0)).top, tester.getRect(rows.at(1)).top);
      expect(tester.getRect(rows.at(1)).top, tester.getRect(rows.at(2)).top);
      await shot(tester, key, 'tablet-browse-three-columns');
      final row = find.byKey(const ValueKey('archive-shelf-open')).first;
      await Scrollable.ensureVisible(tester.element(row), alignment: .5);
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(of: row, matching: find.byType(InkWell)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      await shot(tester, key, 'tablet-detail-entering');
      await tester.pumpAndSettle();
      final detail = find.byKey(const ValueKey('library-detail-pane'));
      expect(detail, findsOneWidget);
      expect(tester.getSize(master).width, tester.getSize(detail).width);
      expect(tester.getSize(bank).width, ArchiveShelfGeometry.maxViewportWidth);
      expect(box.lastChild!.size, coverSize);
      expect(tester.element(find.byType(DiscoverPage)), same(discover));
      expect(
        tester.getRect(master).right + 24,
        closeTo(tester.getRect(detail).left, .1),
      );
      expect(find.byType(DetailPage), findsOneWidget);
      expect(
        tester.widget<DetailPage>(find.byType(DetailPage)).novel.chapters,
        isNotEmpty,
      );
      await shot(tester, key, 'tablet-browse-detail');
      await tester.ensureVisible(
        find.byKey(const ValueKey('detail-read-button')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('detail-read-button')));
      await settleReader(tester);
      expect(find.byType(ReaderPage), findsOneWidget);
      expect(tester.getSize(find.byType(ReaderPage)).width, 1318);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(detail, findsOneWidget);
      AnimationController? closeClock;
      Duration? closeDuration;
      if (capture != null) {
        final transition = tester.widget<ArchivePlaneTransition>(
          find
              .descendant(
                of: detail,
                matching: find.byType(ArchivePlaneTransition),
              )
              .first,
        );
        final animation = transition.animation as CurvedAnimation;
        closeClock = animation.parent as AnimationController;
        closeDuration = closeClock.reverseDuration;
        // Native debug layout/capture can outlast a short exit. Sample its
        // actual transform at a held phase, not a screenshot after dismissal.
        closeClock.reverseDuration = const Duration(seconds: 10);
      }
      await tester.tap(
        find
            .byWidgetPredicate((w) => w is GlassIconButton && w.label == '返回')
            .last,
      );
      await tester.pump();
      if (closeClock != null) {
        closeClock.stop();
        closeClock.value = .9;
        await tester.pump();
      } else {
        await tester.pump(const Duration(milliseconds: 40));
      }
      await shot(tester, key, 'tablet-detail-leaving');
      if (closeClock != null) {
        closeClock.reverseDuration = closeDuration;
        closeClock.reverse();
      }
      await tester.pumpAndSettle();
      expect(detail, findsNothing);
      expect(tester.getSize(master).width, 1200);
      expect(tester.element(find.byType(DiscoverPage)), same(discover));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'tablet collections adapt to one two three columns without distorting covers or clipping actions',
    (tester) async {
      final books = await const _TabletBooks().list();
      int? opened;
      for (final (width, columns) in [(390.0, 1), (824.0, 2), (1318.0, 3)]) {
        final key = await mount(
          tester,
          Scaffold(
            body: BookCollectionView.builder(
              padding: const EdgeInsets.fromLTRB(24, 40, 24, 40),
              itemCount: books.length,
              itemBuilder: (context, index) => NovelRow(
                key: ValueKey('grid-book-$index'),
                novel: books[index],
                onTap: () => opened = index,
                trailing: SizedBox(
                  width: 74,
                  child: GlassIconButton(
                    icon: Icons.more_horiz,
                    label: '书籍操作',
                    onPressed: () => opened = index,
                  ),
                ),
              ),
            ),
          ),
          size: Size(width, 824),
        );
        final first = find.byKey(const ValueKey('grid-book-0'));
        final next = find.byKey(const ValueKey('grid-book-1'));
        final firstRect = tester.getRect(first);
        final nextRect = tester.getRect(next);
        expect(
          nextRect.top,
          columns == 1 ? greaterThan(firstRect.top) : firstRect.top,
        );
        final nextRow = tester.getRect(
          find.byKey(ValueKey('grid-book-$columns')),
        );
        expect(nextRow.top, greaterThan(firstRect.top));
        for (final cover in find.byType(NovelCover).evaluate()) {
          expect((cover.renderObject! as RenderBox).size, const Size(56, 76));
        }
        opened = null;
        await tester.tap(
          find.descendant(of: first, matching: find.byType(InkWell)).first,
        );
        expect(opened, 0);
        if (columns > 1) {
          await shot(tester, key, 'tablet-list-$columns-columns');
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
  );

  for (final mode in [ReaderMode.paged, ReaderMode.vertical]) {
    final paragraphs = List.generate(
      100,
      (i) =>
          '第${i + 1}段。${List.filled(10, '书页随着光影轻轻移动，保留每一段文字的位置与阅读顺序。').join()}',
    );
    test(
      '$mode height reflow reuses shaping and matches uncached pagination',
      () async {
        final content = ReaderContent(paragraphs);
        final prefs = ReaderPreferences(mode: mode);
        final cache = ReaderTextLayoutCache();
        Future<ReaderPagination?> layout(
          double height, {
          ReaderTextLayoutCache? use,
        }) => paginateReader(
          content: content,
          size: Size(580, height),
          style: const TextStyle(fontSize: 19, height: 1.72),
          preferences: prefs,
          scaler: TextScaler.noScaling,
          current: () => true,
          cache: use,
        );
        await layout(550, use: cache);
        final measures = cache.paragraphMeasurements;
        final cold = Stopwatch()..start();
        final baseline = (await layout(680))!;
        cold.stop();
        final warm = Stopwatch()..start();
        final result = (await layout(680, use: cache))!;
        warm.stop();
        expect(cache.paragraphMeasurements, measures);
        expect(result.pages.length, baseline.pages.length);
        for (var p = 0; p < result.pages.length; p++) {
          expect(
            result.pages[p].fragments.map(
              (f) => (f.paragraph, f.start, f.end, f.rect),
            ),
            baseline.pages[p].fragments.map(
              (f) => (f.paragraph, f.start, f.end, f.rect),
            ),
          );
        }
        debugPrint(
          'REFLOW_B24 mode=${mode.name} chars=${paragraphs.join().length} uncachedUs=${cold.elapsedMicroseconds} cachedUs=${warm.elapsedMicroseconds} shaped=$measures',
        );
      },
    );

    testWidgets(
      '$mode tablet chrome starts incremental reflow immediately and both leaves use phone cadence',
      (tester) async {
        final state = await LibraryState.load();
        addTearDown(state.dispose);
        await state.setReaderPreferences(ReaderPreferences(mode: mode));
        final book = Novel(
          id: 71001,
          title: '双页阅读',
          author: '',
          genre: '',
          summary: '',
          colors: const [Colors.grey, Colors.black],
          chapters: [NovelChapter('段落与书页', paragraphs.join('\n\n'))],
        );
        final key = await mount(
          tester,
          ReaderPage(
            novel: book,
            state: state,
            repository: const DemoNovelRepository(),
            initialChapter: 0,
          ),
        );
        await settleReader(tester);
        final pager = tester
            .widget<ReaderPagedView>(find.byType(ReaderPagedView))
            .controller;
        expect(pager.pagesPerSpread, 2);
        final measures = pager.debugParagraphMeasurements;
        for (var i = 0; i < 3; i++) {
          pager.pageBy(1);
          await settleReader(tester);
        }
        final anchor = pager.debugFirstVisibleAnchor!;
        final oldPadding = tester
            .widget<ReaderPagedView>(find.byType(ReaderPagedView))
            .padding;
        final content = find.byKey(const ValueKey('reader-content-tap'));
        await tester.tapAt(tester.getCenter(content));
        await tester.pump(const Duration(milliseconds: 16));
        expect(
          tester
              .widget<ReaderPagedView>(find.byType(ReaderPagedView))
              .padding
              .top,
          lessThan(oldPadding.top),
        );
        await settleReader(tester);
        expect(pager.debugParagraphMeasurements, measures);
        expect(
          (
            pager.debugFirstVisibleAnchor!.paragraph,
            pager.debugFirstVisibleAnchor!.offset,
          ),
          (anchor.paragraph, anchor.offset),
          reason:
              'A height change must not move the first visible text across the spine.',
        );
        await shot(tester, key, 'tablet-${mode.name}-chrome-hidden');
        pager.pageBy(1);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 280));
        final scopes = tester
            .widgetList<ReaderTurnScope>(find.byType(ReaderTurnScope))
            .where((s) => s.enabled && !s.outgoing)
            .toList();
        expect(scopes.map((s) => s.slot).toSet(), containsAll([0, 1]));
        final first = scopes.firstWhere((s) => s.slot == 0);
        final second = scopes.firstWhere((s) => s.slot == 1);
        expect(first.progressFor(0, 10), greaterThan(first.progressFor(9, 10)));
        expect(
          second.progressFor(0, 10),
          0,
          reason: 'The second reading leaf waits for the first leaf.',
        );
        await shot(tester, key, 'tablet-${mode.name}-turn');
        await settleReader(tester);
        expect(pager.debugParagraphMeasurements, measures);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
