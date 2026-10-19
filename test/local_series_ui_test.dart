import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/app_interactions.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/local_books.dart';
import 'package:wenku8_flutter/local_book_media.dart';
import 'package:wenku8_flutter/local_series_editor.dart';
import 'package:wenku8_flutter/local_series_actions.dart';
import 'cloud_library_ui_test.dart' show ioSettle;
import 'support/local_series_fixture.dart';
import 'support/visual_review.dart';

void main({
  bool native = false,
  Future<void> Function(WidgetTester, GlobalKey, String)? capture,
}) {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (!native) setUpAll(loadReviewFonts);
  Future<({LocalBookStore books, LibraryState library, List<Novel> originals})>
  fixture(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({'reduceMotion': true});
    final library = await LibraryState.load();
    addTearDown(library.dispose);
    final books = (await tester.runAsync(() async {
      final dir = await Directory.systemTemp.createTemp('series-editor-ui-');
      final store = LocalBookStore(dir);
      await store.load();
      for (var n = 1; n <= 4; n++) {
        await store.import(
          LocalBookInput('星海图书馆.$n.epub', seriesEpubFixture(n)),
        );
      }
      return store;
    }))!;
    LocalBookMedia.root = books.directory;
    addTearDown(books.dispose);
    addTearDown(() async {
      LocalBookMedia.root = null;
      await books.directory.delete(recursive: true);
    });
    return (books: books, library: library, originals: books.originals);
  }

  Future<GlobalKey> mount(
    WidgetTester tester,
    Widget child, {
    Size size = const Size(390, 844),
    double scale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
    tester.view.viewPadding = tester.view.padding;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);
    final boundary = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: novelTheme(Brightness.light),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(scale),
              disableAnimations: true,
            ),
            child: child!,
          ),
          home: child,
        ),
      ),
    );
    await ioSettle(tester);
    return boundary;
  }

  Future<void> shot(WidgetTester tester, GlobalKey key, String name) async {
    if (capture != null) {
      await capture(tester, key, name);
    } else {
      await captureReview(tester, key, name);
    }
  }

  Future<void> reach(WidgetTester tester, Finder target) async {
    final scrollable = find
        .descendant(
          of: find.byType(LocalSeriesEditor),
          matching: find.byWidgetPredicate(
            (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
          ),
        )
        .first;
    // The center may be an editable field. Scroll from the page gutter, as a
    // field's selection gestures are intentionally not the page's drag target.
    for (var i = 0; i < 20 && target.evaluate().isEmpty; i++) {
      final viewport = tester.getRect(scrollable);
      await tester.dragFrom(
        Offset(viewport.left + 8, viewport.center.dy),
        const Offset(0, -240),
      );
      await tester.pump(const Duration(milliseconds: 80));
    }
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'local EPUB merge suggests volumes, supports drag order and saves grouped chapters',
    (tester) async {
      final f = await fixture(tester);
      LocalSeriesEditResult? result;
      await mount(
        tester,
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async =>
                  result = await pushNovelPage<LocalSeriesEditResult>(
                    context,
                    LocalSeriesEditor(
                      book: f.originals.last,
                      books: f.books,
                      library: f.library,
                      suggested: true,
                    ),
                    reduceMotion: true,
                  ),
              child: const Text('打开分卷合并'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开分卷合并'));
      await ioSettle(tester);
      expect(find.text('阅读顺序 · 4 卷'), findsOneWidget);
      final first = ValueKey('series-volume-${f.originals[0].id}');
      final second = ValueKey('series-volume-${f.originals[1].id}');
      final handle = find.byKey(
        ValueKey('series-reorder-${f.originals[0].id}'),
      );
      await reach(tester, handle);
      expect(SliverReorderableList.maybeOf(tester.element(handle)), isNotNull);
      final distance =
          tester.getRect(find.byKey(second)).bottom -
          tester.getRect(find.byKey(first)).top +
          2;
      final gesture = await tester.startGesture(tester.getCenter(handle));
      await tester.pump(const Duration(milliseconds: 80));
      await gesture.moveBy(const Offset(0, 24));
      await tester.pump(const Duration(milliseconds: 80));
      await gesture.moveBy(Offset(0, distance - 24));
      await tester.pump(const Duration(milliseconds: 250));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.byKey(first)).dy,
        greaterThan(tester.getTopLeft(find.byKey(second)).dy),
      );
      await reach(tester, find.byKey(const ValueKey('series-save')));
      await tester.tap(find.byKey(const ValueKey('series-save')));
      await ioSettle(
        tester,
        until: () => find.byType(LocalSeriesEditor).evaluate().isEmpty,
      );
      expect(result?.bookId, isNotNull);
      expect(f.books.books.single.chapters.length, 8);
      expect(f.books.series.single.volumes.first.bookId, f.originals[1].id);
      expect(f.library.shelf, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'local EPUB management adapts narrow large text and centered tablet layouts',
    (tester) async {
      final f = await fixture(tester);
      for (final (size, scale, name) in [
        (const Size(348, 754), 1.6, 'local-series-narrow-large-text'),
        (const Size(1318, 824), 1.0, 'local-series-tablet'),
      ]) {
        final key = await mount(
          tester,
          LocalSeriesEditor(
            key: ValueKey(name),
            book: f.originals.last,
            books: f.books,
            library: f.library,
            suggested: true,
          ),
          size: size,
          scale: scale,
        );
        final field = tester.getRect(
          find.byKey(const ValueKey('series-title')),
        );
        expect(field.width, lessThanOrEqualTo(712));
        expect(field.center.dx, closeTo(size.width / 2, .1));
        await shot(tester, key, name);
        await reach(tester, find.byKey(const ValueKey('series-save')));
        final save = tester.getRect(find.byKey(const ValueKey('series-save')));
        expect(save.left, greaterThanOrEqualTo(24));
        expect(save.right, lessThanOrEqualTo(size.width - 24));
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets(
    'local EPUB management edits labels, appends an imported volume and restores independent books',
    (tester) async {
      final f = await fixture(tester);
      Novel? merged;
      Object? failure;
      saveLocalSeries(
        books: f.books,
        library: f.library,
        title: '星海图书馆',
        volumes: [
          for (var i = 0; i < 3; i++)
            (bookId: f.originals[i].id, title: '第 ${i + 1} 卷'),
        ],
      ).then((value) => merged = value, onError: (Object e) => failure = e);
      await ioSettle(tester, until: () => merged != null || failure != null);
      expect(failure, isNull);
      LocalSeriesEditResult? result;
      await mount(
        tester,
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async =>
                  result = await pushNovelPage<LocalSeriesEditResult>(
                    context,
                    LocalSeriesEditor(
                      book: f.books.book(merged!.id)!,
                      books: f.books,
                      library: f.library,
                    ),
                    reduceMotion: true,
                  ),
              child: const Text('打开分卷管理'),
            ),
          ),
        ),
      );
      Future<void> open() async {
        await tester.tap(find.text('打开分卷管理'));
        await ioSettle(tester);
      }

      await open();
      final label = find.byKey(
        ValueKey('series-label-${f.originals.first.id}'),
      );
      await tester.enterText(label, '第一卷 · 初见');
      final add = find.byKey(ValueKey('series-add-${f.originals.last.id}'));
      await reach(tester, add);
      await tester.tap(add);
      await tester.pumpAndSettle();
      await reach(tester, find.byKey(const ValueKey('series-save')));
      await tester.tap(find.byKey(const ValueKey('series-save')));
      await ioSettle(
        tester,
        until: () => find.byType(LocalSeriesEditor).evaluate().isEmpty,
      );
      expect(result!.bookId, merged!.id);
      expect(f.books.series.single.volumes.length, 4);
      expect(f.books.series.single.volumes.first.title, '第一卷 · 初见');
      await open();
      await reach(tester, find.byKey(const ValueKey('series-dissolve')));
      await tester.tap(find.byKey(const ValueKey('series-dissolve')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('恢复独立书籍'));
      await ioSettle(
        tester,
        until: () => find.byType(LocalSeriesEditor).evaluate().isEmpty,
      );
      expect(result!.dissolved, isTrue);
      expect(f.books.books.length, 4);
      expect(tester.takeException(), isNull);
    },
  );
}
