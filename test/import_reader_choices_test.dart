import 'dart:io';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/discovery_filters.dart';
import 'package:wenku8_flutter/font_settings_page.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/library_toolbar.dart';
import 'package:wenku8_flutter/local_books.dart';
import 'package:wenku8_flutter/local_import_batch.dart';
import 'package:wenku8_flutter/local_import_review.dart';
import 'package:wenku8_flutter/reader_tools.dart';
import 'support/visual_review.dart';
import 'cloud_library_ui_test.dart' show ioSettle;

void phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await loadReviewFonts();
    await (FontLoader('SourceHanSerifCN')..addFont(
          rootBundle.load('assets/fonts/SourceHanSerifCN-Regular.otf'),
        ))
        .load();
  });
  late LibraryState state;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    state = await LibraryState.load();
  });
  tearDown(() => state.dispose());
  testWidgets(
    'failed files have distinct cards with readable names and reasons',
    (tester) async {
      phone(tester);
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('import-cards-'),
      ))!;
      addTearDown(() => root.delete(recursive: true));
      final books = LocalBookStore(root);
      addTearDown(books.dispose);
      await tester.runAsync(books.load);
      final boundary = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: novelTheme(Brightness.light),
          home: RepaintBoundary(
            key: boundary,
            child: LocalImportReview(
              books: books,
              library: state,
              report: const LocalImportReport(
                bookIds: [],
                added: 0,
                existing: 0,
                failures: [
                  (name: '某个很长的系列名称 第一卷.epub', message: '文件不完整，请重新下载原书后导入'),
                  (name: '另一部作品.mobi', message: '不支持受 DRM 保护的 Kindle 电子书'),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (var i = 0; i < 2; i++) {
        expect(find.byKey(ValueKey('import-failure-$i')), findsOneWidget);
      }
      await captureReview(tester, boundary, 'failed-import-cards');
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('sort is an inline button group, not a nested menu', (
    tester,
  ) async {
    phone(tester);
    var sort = 'recentRead';
    final boundary = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        theme: novelTheme(Brightness.light),
        home: RepaintBoundary(
          key: boundary,
          child: Scaffold(
            body: LibraryViewOptions(
              shelf: false,
              reading: 'all',
              sort: sort,
              onView: (_) {},
              onReading: (_) {},
              onSort: (v) => sort = v,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('library-option-排列顺序-title')));
    expect(sort, 'title');
    expect(find.byType(GlassMenuItem), findsNothing);
    await captureReview(tester, boundary, 'library-visible-options');
    expect(tester.takeException(), isNull);
  });
  testWidgets('discovery exposes real book tags and applies selected tags', (
    tester,
  ) async {
    phone(tester);
    DiscoverySelection? selection;
    final boundary = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        theme: novelTheme(Brightness.light),
        home: Builder(
          builder: (context) => TextButton(
            child: const Text('筛选'),
            onPressed: () async {
              selection = await Navigator.push<DiscoverySelection>(
                context,
                MaterialPageRoute(
                  builder: (_) => RepaintBoundary(
                    key: boundary,
                    child: Scaffold(
                      body: DiscoveryFilters(
                        sort: NovelSort.lastUpdate,
                        books: demoNovels,
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.tap(find.text('筛选'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('标签'));
    await tester.pumpAndSettle();
    await captureReview(tester, boundary, 'discovery-tags');
    await tester.tap(find.byKey(const ValueKey('discover-tag-冒险')));
    await tester.pumpAndSettle();
    expect(selection, isNull);
    await tester.ensureVisible(
      find.byKey(const ValueKey('discover-tags-apply')),
    );
    await tester.tap(find.byKey(const ValueKey('discover-tags-apply')));
    await tester.pumpAndSettle();
    expect(selection?.tags, {'冒险'});
    expect(tester.takeException(), isNull);
  });
  testWidgets('reader font page offers direct sample choices', (tester) async {
    phone(tester);
    final boundary = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        theme: novelTheme(Brightness.light),
        home: RepaintBoundary(
          key: boundary,
          child: FontSettingsPage(state: state, readerOnly: true),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('select-reader-font')), findsNothing);
    await tester.tap(find.text('系统字体'));
    await ioSettle(tester, until: () => state.readerTypeface == 'system');
    expect(state.readerTypeface, 'system');
    await captureReview(tester, boundary, 'reader-font-options');
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'reader choice groups are visible and have no manual illustration entry',
    (tester) async {
      phone(tester);
      final boundary = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: novelTheme(Brightness.light),
          home: RepaintBoundary(
            key: boundary,
            child: Scaffold(
              body: ReaderTools(
                novel: demoNovels.first,
                state: state,
                position: null,
                onAddBookmark: () async => null,
                onFontSize: (_) {},
                onLineHeight: (_) {},
                onReset: () {},
                onIllustrations: () =>
                    throw StateError('Manual layout must not be exposed'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('reader-mode-scroll')), findsOneWidget);
      expect(find.byKey(const ValueKey('reader-mode-paged')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('reader-illustration-layout')),
        findsNothing,
      );
      // Language follows the app's appearance dropdown. Reading mode and
      // colors remain visible choices, with no other dropdowns in this panel.
      expect(find.byIcon(CupertinoIcons.chevron_down), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('reader-language')),
          matching: find.byIcon(CupertinoIcons.chevron_down),
        ),
        findsOneWidget,
      );
      await captureReview(tester, boundary, 'reader-visible-options');
      expect(tester.takeException(), isNull);
    },
  );
}
