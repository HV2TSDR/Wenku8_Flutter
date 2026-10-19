import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/book_documents.dart';
import 'package:wenku8_flutter/book_import_limits.dart';
import 'package:wenku8_flutter/local_book_scanner.dart';
import 'package:wenku8_flutter/local_import_batch.dart';
import 'package:wenku8_flutter/local_scan_page.dart';
import 'support/visual_review.dart';
import 'package:wenku8_flutter/local_scan_selection.dart';

Future<LocalScanResult> scanSelectedFixture({
  required BookDocuments documents,
  required Future<LocalImportReport> Function(BookDocumentSelection)
  importSource,
  required bool Function() current,
  void Function(int, int)? onProgress,
}) async {
  final snapshot = await documents.scanBooks();
  return scanLocalBooks(
    documents: documents,
    snapshot: snapshot,
    selectedTokens: snapshot.books.map((e) => e.token).toSet(),
    importSource: importSource,
    current: current,
    onProgress: onProgress,
  );
}

class ScanDocuments extends BookDocuments {
  Set<String> formats = bookFormatLabels.keys.toSet();
  @override
  Future<Set<String>> scanFormats() async => formats;
  @override
  Future<void> setScanFormats(Set<String> value) async {
    formats = value;
  }

  BookScanFolder? folder;
  final marked = <String>{}, staged = <String>{}, released = <String>[];
  final sources = <BookScanEntry>[
    (token: 'one', name: '同一系列 第一卷.epub'),
    (token: 'two', name: '同一系列 第二卷.zip'),
    (token: 'three', name: '其他作品.mobi'),
  ];
  bool denied = false;
  int picks = 0, peakStaging = 0;
  @override
  Future<void> finishBookScan() async {}
  @override
  Future<BookScanFolder?> selectAllScan() async =>
      folder = const BookScanFolder(
        name: '全部共享存储',
        automatic: true,
        readable: true,
        allStorage: true,
      );
  @override
  Future<BookScanFolder?> scanFolderInfo() async => folder;
  @override
  Future<BookScanFolder?> selectScanFolder() async {
    picks++;
    return folder = const BookScanFolder(
      name: '我的书籍',
      automatic: true,
      readable: true,
    );
  }

  @override
  Future<void> setScanAutomatic(bool value) async {
    folder = BookScanFolder(
      name: folder!.name,
      automatic: value,
      readable: folder!.readable,
    );
  }

  @override
  Future<void> disconnectScanFolder() async {
    folder = null;
  }

  @override
  Future<BookScanSnapshot> scanBooks() async {
    if (denied) throw PlatformException(code: 'document', message: '文件夹权限已失效');
    return BookScanSnapshot(
      books: sources.where((s) => !marked.contains(s.token)).toList(),
      total: sources.length,
      unchanged: marked.length,
    );
  }

  @override
  Future<BookDocumentSelection> stageScanBook(String token) async {
    staged.add(token);
    peakStaging = staged.length > peakStaging ? staged.length : peakStaging;
    return BookDocumentSelection(
      name: sources.firstWhere((s) => s.token == token).name,
      path: token,
    );
  }

  @override
  Future<void> markScanBook(String token) async {
    marked.add(token);
  }

  @override
  Future<void> releaseBooks(Iterable<BookDocumentSelection> books) async {
    for (final book in books) {
      staged.remove(book.path);
      released.add(book.path!);
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadReviewFonts);
  test(
    'unselected candidates are never staged, imported or acknowledged',
    () async {
      final docs = ScanDocuments(),
          snapshot = await ScanDocuments().scanBooks();
      final result = await scanLocalBooks(
        documents: docs,
        snapshot: snapshot,
        selectedTokens: {},
        current: () => true,
        importSource: (_) => throw StateError('Must not import'),
      );
      expect(result.report.added, 0);
      expect(docs.staged, isEmpty);
      expect(docs.marked, isEmpty);
      final subset = await scanLocalBooks(
        documents: docs,
        snapshot: snapshot,
        selectedTokens: {'two'},
        current: () => true,
        importSource: (source) async {
          expect(source.path, 'two');
          return const LocalImportReport(bookIds: [2], added: 1, existing: 0);
        },
      );
      expect(subset.report.added, 1);
      expect(docs.marked, {'two'});
      expect((await docs.scanBooks()).books.map((e) => e.token), [
        'one',
        'three',
      ]);
    },
  );
  testWidgets('scan review starts empty and imports only explicit choices', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final boundary = GlobalKey();
    final snapshot = await ScanDocuments().scanBooks();
    Set<String>? chosen;
    await tester.pumpWidget(
      MaterialApp(
        theme: novelTheme(Brightness.light),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              chosen = await Navigator.push<Set<String>>(
                context,
                MaterialPageRoute(
                  builder: (_) => RepaintBoundary(
                    key: boundary,
                    child: LocalScanSelection(snapshot: snapshot),
                  ),
                ),
              );
            },
            child: const Text('选择书籍'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('选择书籍'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<GlassPillButton>(
            find.byKey(const ValueKey('scan-import-selected')),
          )
          .onPressed,
      isNull,
    );
    await tester.tap(find.byKey(const ValueKey('scan-candidate-two')));
    await tester.pumpAndSettle();
    expect(find.text('导入 1 个文件'), findsOneWidget);
    await captureReview(tester, boundary, 'scan-select-candidates');
    await tester.tap(find.byKey(const ValueKey('scan-import-selected')));
    await tester.pumpAndSettle();
    expect(chosen, {'two'});
    expect(tester.takeException(), isNull);
  });
  test(
    'scan imports one source at a time, keeps partial failures, and skips only acknowledged originals',
    () async {
      final docs = ScanDocuments();
      final progress = <(int, int)>[];
      final first = await scanSelectedFixture(
        documents: docs,
        current: () => true,
        onProgress: (done, total) => progress.add((done, total)),
        importSource: (source) async => switch (source.path) {
          'one' => const LocalImportReport(bookIds: [1], added: 1, existing: 0),
          'two' => const LocalImportReport(
            bookIds: [2],
            added: 1,
            existing: 0,
            failures: [(name: '损坏的一卷.epub', message: '文件损坏')],
          ),
          _ => throw const FormatException('无法解析 MOBI'),
        },
      );
      expect(first.report.bookIds, [1, 2]);
      expect(first.report.failures.length, 2);
      expect(docs.marked, {'one'});
      expect(docs.released, ['one', 'two', 'three']);
      expect(docs.peakStaging, 1);
      expect(progress, [(0, 3), (1, 3), (2, 3), (3, 3)]);
      final retried = <String>[];
      final second = await scanSelectedFixture(
        documents: docs,
        current: () => true,
        importSource: (source) async {
          retried.add(source.path!);
          return const LocalImportReport(bookIds: [2], added: 0, existing: 1);
        },
      );
      expect(retried, ['two', 'three']);
      expect(second.unchanged, 1);
      expect(docs.marked, {'one', 'two', 'three'});
      expect(docs.staged, isEmpty);
      final empty = await scanSelectedFixture(
        documents: docs,
        current: () => true,
        importSource: (_) async => throw StateError('Already imported'),
      );
      expect(empty.summary, contains('没有新增书籍'));
      expect(empty.unchanged, 3);
    },
  );
  test(
    'leaving automatic scan retains finished imports and resumes unacknowledged files',
    () async {
      final docs = ScanDocuments();
      var active = true;
      final first = await scanSelectedFixture(
        documents: docs,
        current: () => active,
        importSource: (_) async {
          active = false;
          return const LocalImportReport(bookIds: [1], added: 1, existing: 0);
        },
      );
      expect(first.interrupted, true);
      expect(first.report.added, 1);
      expect(docs.marked, {'one'});
      expect(docs.released, ['one']);
      expect(docs.staged, isEmpty);
    },
  );
  test('revoked folder is an actionable failure, not an empty scan', () async {
    final docs = ScanDocuments()..denied = true;
    await expectLater(
      scanSelectedFixture(
        documents: docs,
        current: () => true,
        importSource: (_) async => throw StateError('Must not import'),
      ),
      throwsA(isA<PlatformException>()),
    );
    expect(docs.marked, isEmpty);
  });
  for (final compact in [false, true]) {
    testWidgets(
      '${compact ? 'compact dark' : 'phone'} scanner selects once, exposes automatic switch and disconnects without deleting books',
      (tester) async {
        tester.view.physicalSize = Size(
          compact ? 320 : 390,
          compact ? 700 : 844,
        );
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final docs = ScanDocuments(),
            changes = ValueNotifier(0),
            boundary = GlobalKey();
        addTearDown(changes.dispose);
        var scans = 0;
        LocalScanResult? result;
        await tester.pumpWidget(
          MaterialApp(
            theme: novelTheme(compact ? Brightness.dark : Brightness.light),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(compact ? 1.4 : 1)),
              child: RepaintBoundary(key: boundary, child: child),
            ),
            home: LocalScanPage(
              documents: docs,
              changes: changes,
              isBusy: () => false,
              progress: () => null,
              result: () => result,
              failure: () => null,
              onScan: (_) async {
                scans++;
                result = const LocalScanResult(
                  report: LocalImportReport(
                    bookIds: [1, 2],
                    added: 2,
                    existing: 0,
                  ),
                  total: 2,
                  unchanged: 0,
                );
                changes.value++;
              },
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.byKey(const ValueKey('scan-select-folder')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('scan-select-folder')));
        await tester.pumpAndSettle();
        expect(docs.picks, 1);
        expect(scans, 1);
        expect(find.text('我的书籍'), findsOneWidget);
        expect(find.byKey(const ValueKey('scan-automatic')), findsOneWidget);
        final toggle = find.byKey(const ValueKey('scan-automatic'));
        await tester.ensureVisible(toggle);
        await tester.pumpAndSettle();
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(docs.folder!.automatic, false);
        await captureReview(
          tester,
          boundary,
          'scan-${compact ? 'compact-dark' : 'phone'}',
        );
        final remove = find.text('停止自动扫描');
        await tester.ensureVisible(remove);
        await tester.pumpAndSettle();
        await tester.tap(remove);
        await tester.pumpAndSettle();
        expect(docs.folder, isNull);
        expect(find.byKey(const ValueKey('scan-automatic')), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
