import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/app_interactions.dart';
import 'package:wenku8_flutter/archive_carousel.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/legacy_cover.dart';
import 'package:wenku8_flutter/legacy_import_page.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/local_books.dart';
import 'package:wenku8_flutter/local_library_page.dart';
import 'package:wenku8_flutter/local_platform.dart';
import 'package:wenku8_flutter/pages.dart';
import 'package:wenku8_flutter/main.dart';
import 'package:wenku8_flutter/reader_chrome.dart';
import 'package:wenku8_flutter/reader_content.dart';
import 'package:wenku8_flutter/reader_illustrations.dart';
import 'reader_modes_test.dart' show book, settleReader;
import 'support/visual_review.dart';

class _Books extends LocalBookStore {
  _Books() : super(Directory.systemTemp);
  final values = List.generate(12, (i) => demoNovels.first.copyForTest(i));
  @override
  List<Novel> get books => values;
  @override
  Novel? book(int id) => values.where((b) => b.id == id).firstOrNull;
}

extension on Novel {
  Novel copyForTest(int index) => Novel(
    id: localBookIdStart + index,
    title: '本地藏书 ${index + 1}',
    author: '作者',
    genre: '',
    summary: '',
    colors: colors,
    chapters: chapters,
  );
}

Future<Uint8List> picture() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 200, 300),
    Paint()..color = const Color(0xFFB6C6D5),
  );
  canvas.drawRect(
    const Rect.fromLTWH(8, 8, 184, 284),
    Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3,
  );
  final drawing = recorder.endRecording();
  final image = await drawing.toImage(200, 300);
  final bytes = (await image.toByteData(
    format: ui.ImageByteFormat.png,
  ))!.buffer.asUint8List();
  image.dispose();
  drawing.dispose();
  return bytes;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await loadReviewFonts();
    await ChineseText.prepare();
  });
  setUp(() => SharedPreferences.setMockInitialValues({'reduceMotion': true}));

  test(
    'reader chrome starts hidden and persists without application rebuilds',
    () async {
      final state = await LibraryState.load();
      var rebuilds = 0;
      state.applicationChanges.addListener(() => rebuilds++);
      expect(state.readerChromeVisible, false);
      expect(state.readerChromeHintSeen, false);
      await state.setReaderChromeVisible(true);
      await state.markReaderChromeHintSeen();
      expect(rebuilds, 0);
      final reopened = await LibraryState.load();
      expect(reopened.readerChromeVisible, true);
      expect(reopened.readerChromeHintSeen, true);
      await reopened.setReaderChromeVisible(false);
      final hidden = await LibraryState.load();
      expect(hidden.readerChromeVisible, false);
      state.dispose();
      reopened.dispose();
      hidden.dispose();
    },
  );

  test(
    'HK and TW dictionaries differ; reader offsets and image URLs are stable',
    () {
      const source = '头发在里面，软件可以下载书签。👩‍🚀';
      final hk = ChineseText.convert(source, const Locale('zh', 'HK'));
      final tw = ChineseText.convert(source, const Locale('zh', 'TW'));
      expect(hk, contains('裏面'));
      expect(hk, contains('軟件'));
      expect(tw, contains('裡面'));
      expect(tw, contains('軟體'));
      const marker = '<!--image-->https://pic.wenku8.com/书籍/1.jpg<!--image-->';
      final content = ReaderContent([source, marker]);
      final localized = content.localized(const Locale('zh', 'TW'));
      expect(localized.paragraphs.first.length, source.length);
      expect(localized.paragraphs[1], marker);
      expect(localized.paragraphs.first, contains('頭髮'));
      expect(identical(content.illustrations, content.illustrations), true);
    },
  );

  test(
    'library snapshots are reused and invalidate after import and removal',
    () async {
      final root = await Directory.systemTemp.createTemp('library-snapshot-');
      final books = LocalBookStore(root);
      try {
        await books.load();
        final empty = books.books;
        expect(identical(empty, books.books), true);
        const text = '第一章\n这里是正文。';
        final added = await books.import(
          LocalBookInput(
            '测试.txt',
            Uint8List.fromList(utf8.encode(text)),
            text: text,
          ),
        );
        final snapshot = books.books;
        expect(snapshot.single.id, added.id);
        expect(identical(empty, snapshot), false);
        for (var i = 0; i < 100; i++) {
          expect(identical(snapshot, books.books), true);
        }
        await books.remove(added.id);
        expect(books.books, isEmpty);
        expect(snapshot.length, 1);
      } finally {
        books.dispose();
        await root.delete(recursive: true);
      }
    },
  );

  testWidgets(
    'first reader entry is clean; hint is once and chrome state survives reentry',
    (tester) async {
      final state = await LibraryState.load();
      addTearDown(state.dispose);
      Widget reader() => MaterialApp(
        theme: novelTheme(Brightness.light),
        home: ReaderPage(
          novel: book,
          state: state,
          repository: const DemoNovelRepository(),
          initialChapter: 0,
        ),
      );
      await tester.pumpWidget(reader());
      await settleReader(tester);
      double chrome() => tester
          .widget<ReaderChromeLayer>(
            find.byKey(const ValueKey('reader-chrome-header')),
          )
          .animation
          .value;
      expect(chrome(), 0);
      expect(find.text('点击屏幕显示控件'), findsOneWidget);
      dismissNovelFeedback(tester.element(find.byType(ReaderPage)));
      await tester.tapAt(
        tester.getCenter(find.byKey(const ValueKey('reader-content-tap'))),
      );
      await settleReader(tester);
      expect(chrome(), 1);
      expect(state.readerChromeVisible, true);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(reader());
      await settleReader(tester);
      expect(chrome(), 1);
      expect(find.text('点击屏幕显示控件'), findsNothing);
      await tester.tapAt(
        tester.getCenter(find.byKey(const ValueKey('reader-content-tap'))),
      );
      await settleReader(tester);
      expect(chrome(), 0);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(reader());
      await settleReader(tester);
      expect(chrome(), 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'traditional app copy renders with matching system localization',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final boundary = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('zh', 'TW'),
          supportedLocales: const [Locale('zh', 'TW')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          theme: novelTheme(Brightness.light),
          home: RepaintBoundary(
            key: boundary,
            child: const Scaffold(
              body: Center(child: AppText('软件设置 · 阅读与外观\n书架里面的书签')),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('軟體設定 · 閱讀與外觀\n書架裡面的書籤'), findsOneWidget);
      await captureReview(tester, boundary, 'traditional-taiwan');
    },
  );

  testWidgets(
    'local carousel keeps the same 24 dp outer gutter as discovery and shelf',
    (tester) async {
      tester.view.physicalSize = const Size(390, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final state = await LibraryState.load(), books = _Books();
      addTearDown(state.dispose);
      addTearDown(books.dispose);
      final boundary = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: novelTheme(Brightness.light),
          home: RepaintBoundary(
            key: boundary,
            child: LocalLibraryPage(
              books: books,
              state: state,
              onOpen: (_, _) {},
            ),
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 80)),
      );
      await tester.pumpAndSettle();
      final bounds = tester.getRect(find.byType(ArchiveFileCarousel));
      expect(bounds.left, 24);
      expect(bounds.right, 366);
      await captureReview(tester, boundary, 'local-gutters');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'legacy import opens without networking and reports actionable directory errors',
    (tester) async {
      final state = await LibraryState.load();
      addTearDown(state.dispose);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(LocalPlatform.channel, (call) async {
            if (call.method == 'importLegacyData') {
              throw PlatformException(
                code: 'legacy_empty',
                message: '未找到旧版记录，请选择 saves 目录',
              );
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(LocalPlatform.channel, null),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: novelTheme(Brightness.light),
          home: LegacyImportPage(state: state),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('网络或本地存储'), findsNothing);
      await tester.tap(
        find
            .descendant(
              of: find.byKey(const ValueKey('legacy-choose')),
              matching: find.byType(InkWell),
            )
            .first,
      );
      await tester.pumpAndSettle();
      expect(find.text('未找到旧版记录，请选择 saves 目录'), findsOneWidget);
      expect(state.shelf, isEmpty);
    },
  );

  testWidgets(
    'illustration zoom disables page swipes and saves original bytes',
    (tester) async {
      final bytes = (await tester.runAsync(picture))!;
      Uint8List? exported;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(LocalPlatform.channel, (call) async {
            if (call.method == 'saveBookImage') {
              exported = (call.arguments as Map)['bytes'] as Uint8List;
              return true;
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(LocalPlatform.channel, null),
      );
      final boundary = GlobalKey();
      final cache = ReaderIllustrationCache(request: (_) async => bytes);
      await tester.pumpWidget(
        MaterialApp(
          theme: novelTheme(Brightness.light),
          home: RepaintBoundary(
            key: boundary,
            child: ReaderIllustrationGallery(
              urls: const [
                'https://pic.wenku8.com/1.jpg',
                'https://pic.wenku8.com/2.jpg',
              ],
              initialUrl: 'https://pic.wenku8.com/1.jpg',
              cache: cache,
            ),
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 80)),
      );
      await tester.pumpAndSettle();
      final image = find.byType(InteractiveViewer).first;
      for (var i = 0; i < 30; i++) {
        if (tester
            .widgetList<RawImage>(find.byType(RawImage))
            .any((image) => image.image != null)) {
          break;
        }
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(
        tester
            .widgetList<RawImage>(find.byType(RawImage))
            .any((image) => image.image != null),
        true,
      );
      expect(
        (tester.widget<Image>(find.byType(Image).first).image as ResizeImage)
            .width,
        200,
      );
      await tester.tap(image);
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tap(image);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<InteractiveViewer>(image)
            .transformationController!
            .value
            .getMaxScaleOnAxis(),
        2,
      );
      expect(
        tester.widget<PageView>(find.byType(PageView)).physics,
        isA<NeverScrollableScrollPhysics>(),
      );
      await tester.tap(find.byKey(const ValueKey('book-image-save')));
      await tester.pumpAndSettle();
      expect(exported, bytes);
      await captureReview(tester, boundary, 'illustration-zoom-save');
      dismissNovelFeedback(
        tester.element(find.byType(ReaderIllustrationGallery)),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('detail cover opens the shared viewer', (tester) async {
    final bytes = (await tester.runAsync(picture))!;
    final state = await LibraryState.load();
    addTearDown(state.dispose);
    final original = demoNovels.first;
    final coverBook = Novel(
      id: original.id,
      title: original.title,
      author: original.author,
      genre: original.genre,
      summary: original.summary,
      colors: original.colors,
      chapters: original.chapters,
      coverUrl: 'https://img.wenku8.com/cover.jpg',
    );
    LegacyCover.seedLocalBytes(coverBook.id, bytes);
    await tester.pumpWidget(
      MaterialApp(
        theme: novelTheme(Brightness.light),
        home: DetailPage(
          novel: coverBook,
          state: state,
          repository: const DemoNovelRepository(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('detail-view-cover')));
    await tester.pumpAndSettle();
    expect(find.byType(ReaderIllustrationGallery), findsOneWidget);
    expect(find.text('小说封面'), findsOneWidget);
  });

  testWidgets('language switches the actual app and persists its preference', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final state = await LibraryState.load();
    addTearDown(state.dispose);
    final boundary = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: NovelApp(state: state, repository: const DemoNovelRepository()),
      ),
    );
    await tester.pumpAndSettle();
    Future<void> chooseLanguage(AppLanguage language) async {
      var done = false;
      final selecting = state.setLanguage(language).then((_) => done = true);
      // App start can still be committing catalogue metadata. Drain those
      // real platform turns as well as the fake widget microtask queue.
      for (var i = 0; i < 200 && !done; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 8)),
        );
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(done, true, reason: 'language preference did not commit');
      await selecting;
      await tester.pumpAndSettle();
    }

    await chooseLanguage(AppLanguage.taiwan);
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).locale,
      const Locale('zh', 'TW'),
    );
    expect(find.text('輕小說文庫'), findsOneWidget);
    final restarted = await LibraryState.load();
    addTearDown(restarted.dispose);
    expect(restarted.language, AppLanguage.taiwan);
    await tester.tap(find.byKey(const ValueKey('dock-tab-3')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('my-settings')));
    await tester.tap(find.byKey(const ValueKey('my-settings')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-reading-entry')));
    await tester.pumpAndSettle();
    await captureReview(tester, boundary, 'traditional-settings');
    await chooseLanguage(AppLanguage.hongKong);
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).locale,
      const Locale('zh', 'HK'),
    );
    expect(tester.takeException(), isNull);
  });

  test(
    'backup restores the selected Chinese region when preferences are chosen',
    () async {
      final state = await LibraryState.load();
      addTearDown(state.dispose);
      await state.setLanguage(AppLanguage.taiwan);
      final backup = await state.createBackup();
      expect(backup.records['appLanguage'], 'taiwan');
      await state.setLanguage(AppLanguage.hongKong);
      await state.restoreBackup(backup);
      expect(state.language, AppLanguage.hongKong);
      await state.restoreBackup(backup, importPreferences: true);
      expect(state.language, AppLanguage.taiwan);
    },
  );

  testWidgets(
    'toast uses shared glass, clears promptly and stays above the dock band',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final boundary = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: MaterialApp(
            theme: novelTheme(Brightness.light),
            home: Scaffold(
              body: Builder(
                builder: (context) => Center(
                  child: TextButton(
                    onPressed: () => showNovelFeedback(context, '已保存'),
                    child: const Text('显示提示'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('显示提示'));
      await tester.pumpAndSettle();
      final surface = tester.widget<LiquidGlass>(
        find.byKey(const ValueKey('novel-feedback-surface')),
      );
      expect(surface.tintColor, isNull);
      expect(surface.tintOpacity, isNull);
      expect(
        tester.getBottomRight(find.byType(NovelFeedbackNotice)).dy,
        lessThan(844 - 88),
      );
      await captureReview(tester, boundary, 'toast-visible');
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(find.text('已保存'), findsNothing);
    },
  );
}
