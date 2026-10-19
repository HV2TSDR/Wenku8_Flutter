import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/book_documents.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/local_books.dart';
import 'package:wenku8_flutter/local_book_importer.dart';
import 'package:wenku8_flutter/local_import_review.dart';
import 'package:wenku8_flutter/local_library_preferences.dart';
import 'package:wenku8_flutter/local_scan_page.dart';
import 'package:wenku8_flutter/local_scan_selection.dart';
import 'cloud_library_ui_test.dart' show ioSettle;

class _Documents extends BookDocuments {
  List<BookDocumentSelection> selections = [], released = [];
  @override
  Future<List<BookDocumentSelection>> pickBooks() async => selections;
  @override
  Future<String> decodeTextFile(
    String path, {
    String encoding = 'auto',
  }) async => (await File(path).copy('$path.decoded')).path;
  @override
  Future<void> releaseBooks(Iterable<BookDocumentSelection> books) async {
    released = books.toList();
  }
}

class _ScanDocuments extends _Documents {
  bool automatic = false;
  int scans = 0, staged = 0;
  final marked = <String>{};
  final releasedPaths = <String>{};
  @override
  Future<BookScanFolder?> scanFolderInfo() async => automatic
      ? const BookScanFolder(name: '书籍', automatic: true, readable: true)
      : null;
  @override
  Future<BookScanSnapshot> scanBooks() async {
    scans++;
    return BookScanSnapshot(
      books: [
        for (final (i, book) in selections.indexed)
          (token: '$i', name: book.name),
      ],
      total: selections.length,
    );
  }

  @override
  Future<BookDocumentSelection> stageScanBook(String token) async {
    staged++;
    return selections[int.parse(token)];
  }

  @override
  Future<void> finishBookScan() async {}
  @override
  Future<void> markScanBook(String token) async {
    marked.add(token);
  }

  @override
  Future<void> releaseBooks(Iterable<BookDocumentSelection> books) async {
    releasedPaths.addAll(books.map((b) => b.path).whereType<String>());
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('automatic scan waits for foreground and active library', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'reduceMotion': true});
    final library = await LibraryState.load();
    final root = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('wenku-scan-lifecycle-'),
    ))!;
    final store = LocalBookStore(root),
        docs = _ScanDocuments()..automatic = true;
    final importer = LocalBookImporter(
      books: store,
      library: library,
      documents: docs,
    );
    final active = ValueNotifier(false);
    late BuildContext page;
    addTearDown(() async {
      importer.dispose();
      library.dispose();
      store.dispose();
      active.dispose();
      await root.delete(recursive: true);
    });
    await tester.pumpWidget(
      MaterialApp(
        home: ValueListenableBuilder<bool>(
          valueListenable: active,
          builder: (context, value, child) => TickerMode(
            enabled: value,
            child: Builder(
              builder: (context) {
                page = context;
                return const SizedBox();
              },
            ),
          ),
        ),
      ),
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.runAsync(() => importer.scanOnEntry(page, resumed: true));
    expect(docs.scans, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.runAsync(() => importer.scanOnEntry(page, resumed: true));
    expect(docs.scans, 0);
    active.value = true;
    docs.selections.add(
      const BookDocumentSelection(
        name: '不是小说.txt',
        path: '/must-not-stage-or-read',
      ),
    );
    await tester.pump();
    await tester.runAsync(() => importer.scanOnEntry(page, resumed: true));
    await tester.pumpAndSettle();
    expect(docs.scans, 1);
    expect(importer.busy, false);
    expect(importer.scanResult!.total, 1);
    expect(importer.scanResult!.pending, 1);
    expect(docs.staged, 0);
    expect(store.books, isEmpty);
    expect(docs.marked, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'scan menu uses the shared durable import and one final series review',
    (tester) async {
      SharedPreferences.setMockInitialValues({'reduceMotion': true});
      final library = await LibraryState.load();
      final fixture = (await tester.runAsync(() async {
        final root = await Directory.systemTemp.createTemp(
          'wenku-scanned-books-',
        );
        final store = LocalBookStore(Directory('${root.path}/books'));
        await store.load();
        final docs = _ScanDocuments();
        for (var i = 1; i <= 2; i++) {
          final file = File('${root.path}/$i.txt');
          await file.writeAsString('第一章\n卷内的完整正文，序号$i。');
          docs.selections.add(
            BookDocumentSelection(name: '扫描系列 第$i卷.txt', path: file.path),
          );
        }
        return (root, store, docs);
      }))!;
      final (root, store, docs) = fixture;
      final importer = LocalBookImporter(
        books: store,
        library: library,
        documents: docs,
      );
      addTearDown(() async {
        importer.dispose();
        library.dispose();
        store.dispose();
        await root.delete(recursive: true);
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: novelTheme(Brightness.light),
          home: Scaffold(
            body: GlassMenuAnchor(
              child: Builder(
                builder: (context) => TextButton(
                  onPressed: () => importer.showMenu(context),
                  child: const Text('导入菜单'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('导入菜单'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(GlassMenuItem, '扫描本地文件夹'));
      await tester.pumpAndSettle();
      expect(find.byType(LocalScanPage), findsOneWidget);
      final pageContext = tester.element(find.byType(LocalScanPage));
      final scan = importer.run(pageContext, fromScan: true);
      await ioSettle(
        tester,
        until: () => find.byType(LocalScanSelection).evaluate().isNotEmpty,
      );
      expect(store.books, isEmpty);
      expect(docs.staged, 0);
      await tester.tap(find.byKey(const ValueKey('scan-select-all')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('scan-import-selected')));
      await ioSettle(
        tester,
        until: () => find.byType(LocalImportReview).evaluate().isNotEmpty,
      );
      final report = tester
          .widget<LocalImportReview>(find.byType(LocalImportReview))
          .report;
      await tester.binding.handlePopRoute();
      await ioSettle(tester, until: () => !importer.busy);
      await tester.runAsync(() => scan);
      expect(store.books.length, 2, reason: report.failures.toString());
      expect(docs.marked, {'0', '1'});
      expect(
        docs.releasedPaths.length,
        4,
        reason: 'Both source files and streamed UTF-8 staging are released',
      );
      expect(library.shelf, isEmpty);
      expect(importer.scanResult!.report.added, 2);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'shared import keeps batch review, categories, partial errors and staging cleanup',
    (tester) async {
      SharedPreferences.setMockInitialValues({'reduceMotion': true});
      final library = await LibraryState.load();
      final preferences = LocalLibraryPreferences(
        await SharedPreferences.getInstance(),
      )..load();
      final group = await preferences.addGroup('私藏');
      await preferences.select(group);
      final fixture = (await tester.runAsync(() async {
        final root = await Directory.systemTemp.createTemp(
          'wenku-shared-import-',
        );
        final store = LocalBookStore(Directory('${root.path}/books'));
        await store.load();
        final docs = _Documents();
        for (var i = 1; i <= 2; i++) {
          final file = File('${root.path}/volume$i.txt');
          await file.writeAsString('第一章\n卷内的完整正文，序号$i。');
          docs.selections.add(
            BookDocumentSelection(name: '同一系列 第$i卷.txt', path: file.path),
          );
        }
        docs.selections.add(
          const BookDocumentSelection(name: '损坏的.epub', error: '文件无法读取'),
        );
        return (root, store, docs);
      }))!;
      final (root, store, docs) = fixture;
      final importer = LocalBookImporter(
        books: store,
        library: library,
        documents: docs,
      );
      addTearDown(() async {
        importer.dispose();
        preferences.dispose();
        library.dispose();
        store.dispose();
        await root.delete(recursive: true);
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: novelTheme(Brightness.light),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => importer.run(context),
                child: const Text('开始导入'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('开始导入'));
      await ioSettle(
        tester,
        until: () => find.byType(LocalImportReview).evaluate().isNotEmpty,
      );
      expect(
        store.books.length,
        2,
        reason: tester
            .widget<LocalImportReview>(find.byType(LocalImportReview))
            .report
            .failures
            .toString(),
      );
      expect(library.shelf, isEmpty);
      preferences.refresh();
      for (final book in store.books) {
        expect(preferences.groupOf(book.id), group);
      }
      expect(find.textContaining('损坏的.epub'), findsWidgets);
      await tester.binding.handlePopRoute();
      await ioSettle(tester, until: () => !importer.busy);
      expect(docs.released.length, 3);
      expect(importer.progress, isNull);
      expect(importer.error, isNull);
      docs.selections = [];
      await tester.tap(find.text('开始导入'));
      await ioSettle(tester, until: () => !importer.busy);
      expect(store.books.length, 2);
      expect(docs.released, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
