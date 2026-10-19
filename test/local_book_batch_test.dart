import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/local_book_batch_page.dart';
import 'package:wenku8_flutter/local_book_removal.dart';
import 'package:wenku8_flutter/local_books.dart';
import 'package:wenku8_flutter/local_library_page.dart';
import 'package:wenku8_flutter/local_series_actions.dart';
import 'package:wenku8_flutter/offline_cache.dart';
import 'package:wenku8_flutter/offline_repository.dart';
import 'package:wenku8_flutter/pages.dart';
import 'cloud_library_ui_test.dart' show ioSettle;
import 'support/visual_review.dart';

class _FailingBooks extends LocalBookStore {
  _FailingBooks(super.directory);
  int? failing;
  @override
  Future<void> remove(int id) async {
    if (id == failing) throw const FileSystemException('fixture');
    await super.remove(id);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadReviewFonts);
  late Directory root;
  late _FailingBooks books;
  late LibraryState library;
  setUp(() async {
    SharedPreferences.setMockInitialValues({'reduceMotion': true});
    root = await Directory.systemTemp.createTemp('book-batch-');
    books = _FailingBooks(Directory('${root.path}/books'));
    await books.load();
    library = await LibraryState.load();
  });
  tearDown(() async {
    books.dispose();
    library.dispose();
    await root.delete(recursive: true);
  });
  Future<Novel> add(String title) async {
    final text = '第一章\n这是$title 的正文，仍可继续阅读。';
    return books.import(
      LocalBookInput(
        '$title.txt',
        Uint8List.fromList(utf8.encode(text)),
        text: text,
      ),
    );
  }

  test(
    'batch shelf removal commits once, survives restart and retains all files',
    () async {
      final first = await add('第一本'),
          second = await add('第二本'),
          keep = await add('保留');
      var notifications = 0;
      library.shelfViewChanges.addListener(() => notifications++);
      final result = await removeLocalBooks(
        ids: [first.id, second.id, first.id, 1],
        choice: LocalBookRemoval.shelfOnly,
        books: books,
        library: library,
      );
      expect(result.removed, {first.id, second.id});
      expect(result.failed, isEmpty);
      expect(notifications, 1);
      expect(books.books, hasLength(3));
      expect(library.localBookVisible(keep.id), true);
      final reloaded = await LibraryState.load();
      expect(reloaded.hiddenLocalBooks, {first.id, second.id});
      reloaded.dispose();
      expect((await books.original(first.id)).bytes, isNotEmpty);
    },
  );

  test(
    'batch file removal deduplicates series, preserves other books, records and external originals',
    () async {
      final first = await add('第一卷'), second = await add('第二卷');
      final third = await add('另一本'), keep = await add('不删除');
      final external = File('${root.path}/downloaded-original.epub');
      await external.writeAsString('external original');
      await library.savePosition(
        novel: first,
        chapter: 0,
        offset: 25,
        maximum: 100,
        width: 390,
      );
      final series = await saveLocalSeries(
        books: books,
        library: library,
        title: '合订本',
        volumes: [
          (bookId: first.id, title: '第一卷'),
          (bookId: second.id, title: '第二卷'),
        ],
      );
      final progress = <(int, int)>[];
      final result = await removeLocalBooks(
        ids: [series.id, first.id, third.id, 42],
        choice: LocalBookRemoval.files,
        books: books,
        library: library,
        onProgress: (done, total) => progress.add((done, total)),
      );
      expect(result.removed, {series.id, third.id});
      expect(result.failed, isEmpty);
      expect(progress, [(1, 2), (2, 2)]);
      expect(books.contains(series.id), false);
      expect(books.contains(first.id), false);
      expect(books.contains(second.id), false);
      expect(books.contains(keep.id), true);
      expect(
        await Directory('${books.directory.path}/${first.id}').exists(),
        false,
      );
      expect(await external.readAsString(), 'external original');
      expect(library.positionFor(first.id), isNotNull);
    },
  );

  test(
    'one file error retains its book while the remaining selection completes',
    () async {
      final first = await add('失败的书'), second = await add('可以删除');
      books.failing = first.id;
      final result = await removeLocalBooks(
        ids: [first.id, second.id],
        choice: LocalBookRemoval.files,
        books: books,
        library: library,
      );
      expect(result.failed, {first.id});
      expect(result.removed, {second.id});
      expect(books.contains(first.id), true);
      expect(books.contains(second.id), false);
    },
  );

  testWidgets(
    'local entry supports filtered select-all, cancel confirmation and shelf-only removal',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final items = (await tester.runAsync(
        () async => [await add('远行第一卷'), await add('远行第二卷'), await add('留下的书')],
      ))!;
      final capture = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: capture,
          child: MaterialApp(
            theme: novelTheme(Brightness.light),
            home: LocalLibraryPage(
              books: books,
              state: library,
              onOpen: (_, _) {},
            ),
          ),
        ),
      );
      await ioSettle(tester);
      await tester.tap(find.byKey(const ValueKey('local-manage')));
      await tester.pumpAndSettle();
      expect(find.byType(LocalBookBatchPage), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('local-batch-search')),
        '远行',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('local-batch-all')));
      await tester.pumpAndSettle();
      expect(find.text('移除 2 本书'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('local-batch-search')),
        '',
      );
      await tester.pumpAndSettle();
      await captureReview(tester, capture, 'batch-selection-phone');
      await tester.tap(find.byKey(const ValueKey('local-batch-remove')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('local-remove-files')));
      await tester.pumpAndSettle();
      expect(find.text('删除 2 本书的本机文件？'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await ioSettle(tester);
      expect(books.books, hasLength(3));
      expect(find.text('移除 2 本书'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('local-batch-remove')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('local-remove-shelf-only')));
      await ioSettle(tester);
      expect(library.hiddenLocalBooks, {items[0].id, items[1].id});
      expect(books.books, hasLength(3));
      expect(
        find.byKey(ValueKey('local-batch-book-${items[2].id}')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('combined shelf retains the same local-only batch entry', (
    tester,
  ) async {
    await tester.runAsync(() => add('合并后也能管理'));
    final cache = OfflineCacheStore(Directory('${root.path}/cache'));
    await tester.runAsync(cache.load);
    final repository = OfflineNovelRepository(
      remote: const DemoNovelRepository(),
      cache: cache,
      local: books,
    );
    addTearDown(repository.dispose);
    addTearDown(cache.dispose);
    await tester.runAsync(() async {
      await library.setNavigationMode(combinedShelf: true);
      await library.setShelfView(layout: 'list');
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: novelTheme(Brightness.light),
        home: Scaffold(
          body: ShelfPage(
            books: const [],
            state: library,
            repository: repository,
          ),
        ),
      ),
    );
    await ioSettle(tester);
    await tester.tap(find.byKey(const ValueKey('shelf-manage-local')));
    await tester.pumpAndSettle();
    expect(find.byType(LocalBookBatchPage), findsOneWidget);
    expect(find.text('合并后也能管理'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
