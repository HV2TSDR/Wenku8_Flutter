import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/archive_carousel.dart';
import 'package:wenku8_flutter/book_documents.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/cloud_library_page.dart';
import 'package:wenku8_flutter/cloud_sources.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/local_books.dart';
import 'package:wenku8_flutter/local_library_page.dart';
import 'package:wenku8_flutter/local_library_preferences.dart';
import 'package:wenku8_flutter/local_book_editor.dart';
import 'package:wenku8_flutter/offline_cache.dart';
import 'package:wenku8_flutter/offline_repository.dart';
import 'package:wenku8_flutter/pages.dart';
import 'cloud_sources_test.dart' show MemoryCloudVault, davConfig;
import 'support/visual_review.dart';

class LocalDocumentsFixture extends BookDocuments {
  @override
  Future<Map<String, dynamic>?> info() async => null;
  @override
  Future<String> decodeTextFile(
    String path, {
    String encoding = 'auto',
  }) async => (await File(path).copy('$path.decoded')).path;
}

class FixturePaths extends PathProviderPlatform {
  FixturePaths(this.root);
  final String root;
  @override
  Future<String?> getTemporaryPath() async => root;
}

class BrowserFixture implements CloudBookClient {
  @override
  String get root => 'root';
  bool closed = false;
  @override
  Future<CloudBookListing> list(String folder, {int page = 1}) async =>
      CloudBookListing(
        folder == 'root'
            ? const [
                CloudBookEntry(id: 'folder', name: '科幻小说', folder: true),
                CloudBookEntry(
                  id: 'one',
                  name: '本机导入一.txt',
                  folder: false,
                  size: 60,
                ),
                CloudBookEntry(
                  id: 'two',
                  name: '本机导入二.txt',
                  folder: false,
                  size: 60,
                ),
              ]
            : const [
                CloudBookEntry(id: 'nested', name: '文件夹中的书.txt', folder: false),
              ],
      );
  @override
  Future<void> download(
    CloudBookEntry entry,
    File target, {
    void Function(int, int?)? onProgress,
  }) async {
    await target.writeAsString('第一章\n${entry.name}的完整正文。');
    onProgress?.call(60, 60);
  }

  @override
  void cancel() {
    closed = true;
  }

  @override
  void close() {
    closed = true;
  }
}

Future<void> ioSettle(WidgetTester tester, {bool Function()? until}) async {
  for (var i = 0; i < (until == null ? 14 : 120); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 12)),
    );
    await tester.pump(const Duration(milliseconds: 20));
    if (until?.call() == true) break;
  }
  await tester.pumpAndSettle();
  if (until != null) {
    expect(until(), true, reason: 'cloud operation did not finish');
  }
}

Finder button(String label) =>
    find.byWidgetPredicate((w) => w is GlassIconButton && w.label == label);

void main({
  Future<void> Function(WidgetTester, GlobalKey, String)? capture,
  bool configureView = true,
}) {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadReviewFonts);
  Future<GlobalKey> mount(
    WidgetTester tester,
    Widget child, {
    double scale = 1,
  }) async {
    if (configureView) {
      tester.view.physicalSize = const Size(348, 754);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
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
            child: child!,
          ),
          home: child,
        ),
      ),
    );
    await ioSettle(tester);
    return boundary;
  }

  testWidgets(
    'local tab layout has a 10-book threshold and working view/category controls',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'reduceMotion': true,
        'readerChromeVisible': true,
        'readerChromeHintSeen': true,
      });
      final state = await LibraryState.load();
      addTearDown(state.dispose);
      final dir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('local-home-ui-'),
      ))!;
      addTearDown(() => dir.delete(recursive: true));
      final books = (await tester.runAsync(() async {
        final store = LocalBookStore(dir);
        await store.load();
        return store;
      }))!;
      addTearDown(books.dispose);
      final cloud = CloudSourceSettings(storage: MemoryCloudVault());
      addTearDown(cloud.dispose);
      for (var i = 1; i <= 9; i++) {
        final text = '第一章\n本地书籍 $i 的正文内容。';
        await tester.runAsync(
          () => books.import(
            LocalBookInput(
              '本地书籍$i.txt',
              Uint8List.fromList(utf8.encode(text)),
              text: text,
            ),
          ),
        );
      }
      final boundary = await mount(
        tester,
        LocalLibraryPage(
          books: books,
          state: state,
          documents: LocalDocumentsFixture(),
          cloudSettings: cloud,
          onOpen: (_, _) {},
        ),
      );
      expect(find.byType(ArchiveFileCarousel), findsNothing);
      final searchRect = tester.getRect(
        find.byKey(const ValueKey('local-search')),
      );
      expect(
        searchRect.right,
        closeTo(
          MediaQuery.sizeOf(
                tester.element(find.byType(LocalLibraryPage)),
              ).width -
              24,
          .1,
        ),
      );
      expect(find.text('从网盘导入'), findsNothing);
      expect(button('云同步与网盘导入'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('local-import-book')));
      await tester.pumpAndSettle();
      expect(find.text('导入书籍'), findsOneWidget);
      expect(find.text('从网盘导入'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await capture?.call(tester, boundary, 'local-nine-list');
      await tester.runAsync(() async {
        const text = '第一章\n第十本本地书籍的内容。';
        await books.import(
          LocalBookInput(
            '本地书籍10.txt',
            Uint8List.fromList(utf8.encode(text)),
            text: text,
          ),
        );
      });
      await ioSettle(tester);
      expect(find.byType(ArchiveFileCarousel), findsOneWidget);
      await capture?.call(tester, boundary, 'local-ten-shelf');
      await tester.tap(find.byKey(const ValueKey('local-display')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('仅列表'));
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(ArchiveFileCarousel), findsNothing);
      await tester.tap(find.byKey(const ValueKey('local-category')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('新建分类'));
      await tester.pumpAndSettle();
      final field = find.byType(CupertinoTextField).last;
      await tester.enterText(field, '短篇');
      await tester.tap(find.text('保存分类'));
      await ioSettle(tester);
      await tester.tap(find.byKey(const ValueKey('local-category')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('短篇'));
      await tester.pumpAndSettle();
      expect(find.text('没有符合条件的书籍，换个分类或关键词试试。'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'home uses one scoped search and local detail edits/deletes preserve reading state',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'reduceMotion': true,
        'readerChromeVisible': true,
        'readerChromeHintSeen': true,
      });
      final state = await LibraryState.load();
      addTearDown(state.dispose);
      final dir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('local-profile-ui-'),
      ))!;
      addTearDown(() => dir.delete(recursive: true));
      final books = (await tester.runAsync(() async {
        final value = LocalBookStore(Directory('${dir.path}/books'));
        await value.load();
        const text = '第一章\n本地原书的正文。';
        await value.import(
          LocalBookInput(
            '本地原书.txt',
            Uint8List.fromList(utf8.encode(text)),
            text: text,
          ),
        );
        return value;
      }))!;
      addTearDown(books.dispose);
      final cache = (await tester.runAsync(() async {
        final value = OfflineCacheStore(Directory('${dir.path}/cache'));
        await value.load();
        return value;
      }))!;
      addTearDown(cache.dispose);
      final repository = OfflineNovelRepository(
        remote: const DemoNovelRepository(),
        cache: cache,
        local: books,
      );
      addTearDown(repository.dispose);
      final book = books.books.single;
      await state.setShelfMembership(book.id, true, novel: book);
      await state.savePosition(
        novel: book,
        chapter: 0,
        offset: .4,
        maximum: 1,
        width: 348,
      );
      final progress = state.positionFor(book.id);
      final groups = LocalLibraryPreferences(
        await SharedPreferences.getInstance(),
      )..load();
      addTearDown(groups.dispose);
      final group = await groups.addGroup('短篇');
      final boundary = await mount(
        tester,
        HomeShell(state: state, repository: repository),
      );
      await tester.tapAt(
        tester.getCenter(find.byKey(const ValueKey('dock-tab-1'))),
      );
      await ioSettle(tester);
      final shelfSearch = find.byKey(const ValueKey('shelf-search-entry'));
      final shelfRect = tester.getRect(shelfSearch);
      await capture?.call(tester, boundary, 'shelf-unified-search-entry');
      expect(find.byKey(const ValueKey('shelf-search')), findsNothing);
      await tester.tap(shelfSearch);
      await ioSettle(tester);
      final input = find.byKey(const ValueKey('expanded-search-input'));
      await tester.enterText(input, book.title);
      await tester.pump(const Duration(milliseconds: 350));
      await ioSettle(tester);
      expect(find.text('没有找到相关故事'), findsOneWidget);
      expect(find.text(demoNovels.first.title), findsNothing);
      await tester.tap(find.byKey(const ValueKey('inline-search-close')));
      await tester.pumpAndSettle();
      await tester.tapAt(
        tester.getCenter(find.byKey(const ValueKey('dock-tab-2'))),
      );
      await ioSettle(tester);
      final localSearch = find.byKey(const ValueKey('local-search'));
      expect(tester.getRect(localSearch), shelfRect);
      await capture?.call(tester, boundary, 'local-unified-header');
      await tester.tap(localSearch);
      await ioSettle(tester);
      expect(tester.widget<TextField>(input).controller!.text, isEmpty);
      expect(find.text('本地书籍'), findsWidgets);
      await tester.tap(find.text(book.title).last);
      await ioSettle(tester);
      final config = find.byKey(const ValueKey('local-book-config'));
      expect(config, findsOneWidget);
      await tester.tap(config);
      await ioSettle(tester);
      await tester.enterText(
        find.byKey(const ValueKey('local-edit-书名')),
        '修改后的原书',
      );
      await tester.enterText(
        find.byKey(const ValueKey('local-edit-作者')),
        '本地作者',
      );
      await tester.tap(find.byKey(const ValueKey('local-edit-category')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('短篇'));
      await tester.pumpAndSettle();
      await capture?.call(tester, boundary, 'local-book-profile');
      final save = find.byKey(const ValueKey('local-edit-save'));
      await tester.ensureVisible(save);
      await tester.pumpAndSettle();
      await tester.tap(save);
      await ioSettle(
        tester,
        until: () => find.byType(LocalBookEditor).evaluate().isEmpty,
      );
      expect(books.book(book.id)!.title, '修改后的原书');
      groups.load();
      expect(groups.groupOf(book.id), group);
      expect(state.positionFor(book.id), same(progress));
      await tester.binding.handlePopRoute();
      await ioSettle(tester);
      await tester.tap(find.text('修改后的原书').last);
      await ioSettle(tester);
      await tester.tap(config);
      await ioSettle(tester);
      final delete = find.byKey(const ValueKey('local-edit-delete'));
      await tester.ensureVisible(delete);
      await tester.pumpAndSettle();
      await tester.tap(delete);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('local-remove-files')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除本机文件').last);
      await ioSettle(
        tester,
        until: () => find.byType(LocalBookEditor).evaluate().isEmpty,
      );
      expect(books.books, isEmpty);
      expect(state.contains(book.id), false);
      expect(state.positionFor(book.id), same(progress));
      expect(find.byType(DetailLoaderPage), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'cloud settings fit compact large text and show usable private credential fields',
    (tester) async {
      final settings = CloudSourceSettings(storage: MemoryCloudVault());
      addTearDown(settings.dispose);
      final boundary = await mount(
        tester,
        CloudLibraryPage(
          settings: settings,
          onImport: (_, _) async => demoNovels.first,
        ),
        scale: 1.6,
      );
      await capture?.call(tester, boundary, 'cloud-sources-large-text');
      await tester.tap(find.byKey(const ValueKey('cloud-add-webdav')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('cloud-field-WebDAV 地址')),
        findsOneWidget,
      );
      final password = tester.widget<CupertinoTextField>(
        find.byKey(const ValueKey('cloud-field-密码')),
      );
      expect(password.obscureText, true);
      expect(password.enableSuggestions, false);
      await capture?.call(tester, boundary, 'cloud-webdav-config');
      expect(tester.takeException(), isNull);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('cloud-add-quark')),
        200,
      );
      await tester.tap(find.byKey(const ValueKey('cloud-add-quark')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<CupertinoTextField>(
              find.byKey(const ValueKey('cloud-field-Cookie')),
            )
            .obscureText,
        true,
      );
      await capture?.call(tester, boundary, 'cloud-quark-config');
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'cloud browser navigates folders and batch imports complete files with cleanup',
    (tester) async {
      final dir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('cloud-browser-ui-'),
      ))!;
      addTearDown(() => dir.delete(recursive: true));
      final old = PathProviderPlatform.instance;
      PathProviderPlatform.instance = FixturePaths(dir.path);
      addTearDown(() => PathProviderPlatform.instance = old);
      final settings = CloudSourceSettings(storage: MemoryCloudVault());
      addTearDown(settings.dispose);
      final client = BrowserFixture(), imported = <String>[];
      final boundary = await mount(
        tester,
        CloudBookBrowser(
          config: davConfig,
          settings: settings,
          client: client,
          onImport: (name, path) async {
            expect(await File(path).readAsString(), contains('完整正文'));
            imported.add(name);
            return demoNovels.first;
          },
        ),
      );
      await tester.tap(find.text('科幻小说'));
      await ioSettle(tester);
      expect(find.text('文件夹中的书.txt'), findsOneWidget);
      await tester.tap(button('返回'));
      await ioSettle(tester);
      await tester.tap(button('选择 本机导入一.txt'));
      await tester.pumpAndSettle();
      await tester.tap(button('选择 本机导入二.txt'));
      await tester.pumpAndSettle();
      await capture?.call(tester, boundary, 'cloud-browser-batch');
      await tester.tap(find.text('导入选中的 2 本'));
      await ioSettle(
        tester,
        until: () => find.text('已导入').evaluate().length == 2,
      );
      expect(imported, ['本机导入一.txt', '本机导入二.txt']);
      expect(find.text('已导入'), findsNWidgets(2));
      final leftovers = await tester.runAsync(
        () => Directory('${dir.path}/cloud-book-import').list().toList(),
      );
      expect(leftovers, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'failed archive batch stays retryable and is not marked imported',
    (tester) async {
      final dir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('cloud-archive-ui-'),
      ))!;
      addTearDown(() => dir.delete(recursive: true));
      final old = PathProviderPlatform.instance;
      PathProviderPlatform.instance = FixturePaths(dir.path);
      addTearDown(() => PathProviderPlatform.instance = old);
      final settings = CloudSourceSettings(storage: MemoryCloudVault());
      addTearDown(settings.dispose);
      var attempts = 0;
      await mount(
        tester,
        CloudBookBrowser(
          config: davConfig,
          settings: settings,
          client: BrowserFixture(),
          onImport: (_, _) async =>
              throw StateError('Archive-aware path must be used'),
          onImportBatch: (name, path) async {
            attempts++;
            return attempts == 1
                ? (imported: 0, failed: 1)
                : (imported: 2, failed: 0);
          },
        ),
      );
      await tester.tap(find.text('本机导入一.txt'));
      await ioSettle(tester);
      expect(attempts, 1);
      expect(find.text('已导入'), findsNothing);
      expect(find.textContaining('1 本未导入'), findsOneWidget);
      await tester.tap(find.text('本机导入一.txt'));
      await ioSettle(tester);
      expect(attempts, 2);
      expect(find.text('已导入'), findsOneWidget);
      final leftovers = await tester.runAsync(
        () => Directory('${dir.path}/cloud-book-import').list().toList(),
      );
      expect(leftovers, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
