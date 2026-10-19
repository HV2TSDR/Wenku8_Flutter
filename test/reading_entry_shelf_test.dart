import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/reader_panels.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/book_source_badge.dart';
import 'package:wenku8_flutter/bookshelf_scope.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/glass_dock.dart';
import 'package:wenku8_flutter/home_navigation.dart';
import 'package:wenku8_flutter/legacy_wenku_repository.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/library_search_repository.dart';
import 'package:wenku8_flutter/local_books.dart';
import 'package:wenku8_flutter/local_book_editor.dart';
import 'package:wenku8_flutter/local_series_actions.dart';
import 'package:wenku8_flutter/network_status.dart';
import 'package:wenku8_flutter/offline_cache.dart';
import 'package:wenku8_flutter/offline_repository.dart';
import 'package:wenku8_flutter/pages.dart';
import 'package:wenku8_flutter/reader_paged_view.dart';
import 'package:wenku8_flutter/reader_catalogue.dart';
import 'package:wenku8_flutter/reader_preferences.dart';
import 'reader_modes_test.dart' show settleReader;
import 'cloud_library_ui_test.dart' show ioSettle;
import 'support/visual_review.dart';

final _book = Novel(
  id: 91,
  title: '连续阅读',
  author: '测试作者',
  genre: '奇幻 冒险 奇幻',
  summary: '简介',
  colors: const [Colors.grey, Colors.black],
  chapters: [
    for (var i = 0; i < 3; i++)
      NovelChapter(
        '章节${i + 1}',
        List.generate(
          8,
          (p) => '章节${i + 1}第${p + 1}段。${'静静地读完这一段文字。' * 12}',
        ).join('\n\n'),
        id: 101 + i,
      ),
  ],
);

class _Remote extends DemoNovelRepository {
  final calls = <int, int>{};
  @override
  Future<Novel> detail(Novel novel) async => novel;
  @override
  Future<List<NovelChapter>> chapters(int id) async => _book.chapters;
  @override
  Future<String> chapterContent(int id, NovelChapter chapter) async {
    calls.update(chapter.id, (n) => n + 1, ifAbsent: () => 1);
    return chapter.content;
  }
}

Future<LibraryState> _state() async {
  SharedPreferences.setMockInitialValues({
    'readerChromeVisible': true,
    'readerChromeHintSeen': true,
    'reduceMotion': true,
    'shelfLayout': 'list',
  });
  return LibraryState.load();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadReviewFonts);

  test(
    'new preferences default off and survive restart and backup restore',
    () async {
      final state = await _state();
      addTearDown(state.dispose);
      expect(state.directReading, false);
      expect(state.combinedShelf, false);
      await state.setDirectReading(true);
      await state.setNavigationMode(combinedShelf: true, localReaderMode: true);
      final backup = await state.createBackup();
      final restarted = await LibraryState.load();
      addTearDown(restarted.dispose);
      expect(restarted.directReading, true);
      expect(restarted.combinedShelf, true);
      await restarted.setDirectReading(false);
      await restarted.setNavigationMode(combinedShelf: false);
      await restarted.restoreBackup(backup, importPreferences: true);
      expect(restarted.directReading, true);
      expect(restarted.combinedShelf, true);
    },
  );

  test(
    'merged shelf navigation covers offline and reader mode reversibly',
    () async {
      final state = await _state();
      final network = NetworkStatus(initial: NetworkReachability.online);
      final nav = HomeNavigation(state, network);
      addTearDown(() {
        nav.dispose();
        network.dispose();
        state.dispose();
      });
      expect(nav.tabs, [0, 1, 2, 3]);
      await state.setNavigationMode(combinedShelf: true);
      expect(nav.tabs, [0, 1, 3]);
      expect(nav.destination(2), 1);
      expect(nav.destination(3), 3);
      network.value = NetworkReachability.offline;
      expect(nav.tabs, [1, 3]);
      await state.setNavigationMode(adaptWhenOffline: false);
      expect(nav.tabs, [0, 1, 3]);
      await state.setNavigationMode(adaptWhenOffline: true);
      await state.setNavigationMode(localReaderMode: true);
      expect(nav.tabs, [1, 3]);
      expect(nav.destination(2), 1);
      expect(nav.readableShelfOnly, true);
      await state.setNavigationMode(combinedShelf: false);
      expect(nav.tabs, [2, 3]);
      expect(nav.destination(1), 2);
      await state.setNavigationMode(localReaderMode: false);
      expect(nav.tabs, [1, 2, 3]);
      network.value = NetworkReachability.online;
      expect(nav.tabs, [0, 1, 2, 3]);
    },
  );

  testWidgets(
    'union and search include originals and cached nonfavorites without changing membership',
    (tester) async {
      final state = await _state();
      final fixture = (await tester.runAsync(() async {
        final root = await Directory.systemTemp.createTemp('wenku-merged-');
        final local = LocalBookStore(Directory('${root.path}/local'));
        await local.load();
        final imported = await local.import(
          LocalBookInput(
            '本地冒险.txt',
            Uint8List.fromList(utf8.encode('第一章\n本地正文。')),
            text: '第一章\n本地正文。',
          ),
        );
        final cache = OfflineCacheStore(Directory('${root.path}/cache'));
        final cached = demoNovels.first.withChapters(const [
          NovelChapter('缓存章', '', id: 11),
          NovelChapter('未缓存章', '', id: 12),
        ]);
        await cache.saveBook(cached, epoch: cache.epochFor(cached.id));
        await cache.saveChapter(
          cached.id,
          11,
          '缓存正文。',
          epoch: cache.epochFor(cached.id),
        );
        await cache.saveBook(
          demoNovels[2].withChapters(const [NovelChapter('只有目录', '', id: 31)]),
          epoch: cache.epochFor(demoNovels[2].id),
        );
        return (root, local, imported, cache, cached);
      }))!;
      final (root, local, imported, cache, cached) = fixture;
      final offline = OfflineNovelRepository(
        remote: const DemoNovelRepository(),
        cache: cache,
        local: local,
      );
      addTearDown(() async {
        offline.dispose();
        cache.dispose();
        local.dispose();
        state.dispose();
        await root.delete(recursive: true);
      });
      await state.setShelfMembership(2, true, novel: demoNovels[1]);
      expect(bookshelfIds(state, offline), {2});
      await state.setNavigationMode(combinedShelf: true);
      expect(bookshelfIds(state, offline), {cached.id, 2, imported.id});
      expect(bookshelfIds(state, offline, readableOnly: true), {
        cached.id,
        imported.id,
      });
      final search = LibrarySearchRepository(
        source: offline,
        state: state,
        local: local,
      );
      final found = await tester.runAsync(() => search.search('本地冒险'));
      expect(found!.single.id, imported.id);
      final capture = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: novelTheme(Brightness.light),
          home: RepaintBoundary(
            key: capture,
            child: Scaffold(
              body: ShelfPage(
                books: const [],
                state: state,
                repository: offline,
              ),
            ),
          ),
        ),
      );
      await ioSettle(tester);
      expect(find.byKey(const ValueKey('shelf-import-book')), findsOneWidget);
      expect(find.byType(BookSourceBadge), findsNWidgets(3));
      await captureReview(tester, capture, 'combined-shelf');
      const visuals = String.fromEnvironment('REVIEW_ARTIFACTS');
      if (visuals.isNotEmpty) {
        await state.setShelfView(layout: 'shelf');
        await tester.pumpAndSettle();
        await captureReview(tester, capture, 'combined-shelf-3d');
        await state.setShelfView(layout: 'list');
        await tester.pumpAndSettle();
      }
      await tester.tap(
        find.byWidgetPredicate(
          (w) => w is GlassIconButton && w.label == '${imported.title}书架操作',
        ),
      );
      await ioSettle(tester);
      expect(find.byType(LocalBookEditor), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await state.setNavigationMode(combinedShelf: false);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('shelf-import-book')), findsNothing);
      expect(find.byKey(ValueKey('shelf-book-${imported.id}')), findsNothing);
      expect(state.shelf, {2});
      expect(local.book(imported.id), isNotNull);
      expect(cache.book(cached.id)!.cachedCount, 1);
      expect(tester.takeException(), isNull);
      final network = NetworkStatus(initial: NetworkReachability.offline);
      final remote = _Remote();
      final offlineReader = OfflineNovelRepository(
        remote: remote,
        cache: cache,
        local: local,
        network: network,
      );
      addTearDown(() {
        offlineReader.dispose();
        network.dispose();
      });
      await state.savePosition(
        novel: cached,
        chapter: 1,
        offset: 0,
        maximum: 100,
        width: 390,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: novelTheme(Brightness.light),
          home: ReaderLoaderPage(
            novel: cached,
            state: state,
            repository: offlineReader,
          ),
        ),
      );
      await ioSettle(
        tester,
        until: () => find.textContaining('缓存正文').evaluate().isNotEmpty,
      );
      expect(
        tester.widget<ReaderPage>(find.byType(ReaderPage)).initialChapter,
        0,
        reason:
            'offline resume uses an available chapter rather than failing on an uncached one',
      );
      expect(remote.calls, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'direct entry resumes and top details return to the same reader',
    (tester) async {
      final state = await _state();
      addTearDown(state.dispose);
      await state.setDirectReading(true);
      await state.savePosition(
        novel: _book,
        chapter: 1,
        offset: 0,
        maximum: 100,
        width: 390,
      );
      final remote = _Remote();
      final capture = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: novelTheme(Brightness.light),
          home: RepaintBoundary(
            key: capture,
            child: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => openDetail(context, _book, state, remote),
                  child: const Text('点书'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('点书'));
      await settleReader(tester);
      expect(find.byType(DetailPage), findsNothing);
      expect(
        tester.widget<ReaderPage>(find.byType(ReaderPage)).initialChapter,
        1,
      );
      final dock = tester.widget<GlassDock>(
        find.byKey(const ValueKey('reader-liquid-dock')),
      );
      expect(dock.items.map((item) => item.label), ['上一章', '2 / 3', '下一章']);
      expect(dock.items[1].id, 'reader-catalogue');
      await tester.tap(readerPanelControl('进入详情页'));
      await tester.pumpAndSettle();
      expect(find.byType(DetailPage), findsOneWidget);
      expect(find.byKey(const ValueKey('detail-book-tags')), findsOneWidget);
      await captureReview(tester, capture, 'reader-details-tags');
      await tester.tap(find.textContaining('继续阅读').first);
      await settleReader(tester);
      expect(find.byType(DetailPage), findsNothing);
      expect(find.byType(ReaderPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'direct reading changes only the header detail entry without reloading text',
    (tester) async {
      final state = await _state();
      addTearDown(state.dispose);
      final remote = _Remote();
      await tester.pumpWidget(
        MaterialApp(
          theme: novelTheme(Brightness.light),
          home: ReaderPage(
            novel: _book,
            state: state,
            repository: remote,
            initialChapter: 0,
          ),
        ),
      );
      await settleReader(tester);
      GlassDock dock() => tester.widget<GlassDock>(
        find.byKey(const ValueKey('reader-liquid-dock')),
      );
      expect(dock().items.length, 3);
      expect(dock().items[1].id, 'reader-catalogue');
      expect(find.text('详情'), findsNothing);
      await tester.tapAt(
        tester.getCenter(find.byKey(const ValueKey('reader-liquid-dock'))),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ReaderCatalogue), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      final reader = tester.element(find.byType(ReaderPage));
      final requests = Map.of(remote.calls);
      await state.setDirectReading(true);
      await tester.pumpAndSettle();
      expect(dock().items.map((item) => item.label), ['上一章', '1 / 3', '下一章']);
      await tester.tap(readerPanelControl('进入详情页'));
      await tester.pumpAndSettle();
      expect(find.byType(DetailPage), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await state.setDirectReading(false);
      await tester.pumpAndSettle();
      expect(dock().items.length, 3);
      expect(dock().items[1].id, 'reader-catalogue');
      expect(find.byKey(const ValueKey('reader-details-entry')), findsNothing);
      expect(tester.element(find.byType(ReaderPage)), same(reader));
      expect(remote.calls, requests);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'reader details preserve edited local metadata and close after original deletion',
    (tester) async {
      final state = await _state();
      await state.setDirectReading(true);
      final fixture = (await tester.runAsync(() async {
        final root = await Directory.systemTemp.createTemp(
          'wenku-reader-editor-',
        );
        final books = LocalBookStore(Directory('${root.path}/books'));
        await books.load();
        const text = '第一章\n原书内容。';
        final book = await books.import(
          LocalBookInput(
            '原来的书名.txt',
            Uint8List.fromList(utf8.encode(text)),
            text: text,
          ),
        );
        return (root, books, book);
      }))!;
      final (root, books, book) = fixture;
      final cache = OfflineCacheStore(Directory('${root.path}/cache'));
      final repository = OfflineNovelRepository(
        remote: const DemoNovelRepository(),
        cache: cache,
        local: books,
      );
      addTearDown(() async {
        repository.dispose();
        cache.dispose();
        books.dispose();
        state.dispose();
        await root.delete(recursive: true);
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: novelTheme(Brightness.light),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => openDetail(context, book, state, repository),
                child: const Text('打开本地书'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开本地书'));
      await ioSettle(
        tester,
        until: () => find.textContaining('原书内容').evaluate().isNotEmpty,
      );
      await tester.tap(readerPanelControl('进入详情页'));
      await tester.pumpAndSettle();
      final renamed = await tester.runAsync(
        () => books.updateMetadata(
          book.id,
          title: '改好的书名',
          author: '新作者',
          summary: '新简介',
        ),
      );
      await state.rememberNovel(renamed!);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('改好的书名'), findsOneWidget);
      await tester.tap(readerPanelControl('进入详情页'));
      await tester.pumpAndSettle();
      expect(state.cachedNovel(book.id)!.title, '改好的书名');
      var removed = false;
      unawaited(
        removeLocalBook(
          books: books,
          library: state,
          id: book.id,
        ).then((_) => removed = true),
      );
      await ioSettle(tester, until: () => removed);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(ReaderPage), findsNothing);
      expect(find.text('打开本地书'), findsOneWidget);
      expect(books.book(book.id), isNull);
      expect(state.positionFor(book.id), isNotNull);
      expect(state.cachedNovel(book.id)!.title, '改好的书名');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final mode in ReaderMode.values) {
    testWidgets(
      '${mode.name} automatically crosses both chapter boundaries, prefetches once',
      (tester) async {
        final state = await _state();
        addTearDown(state.dispose);
        await state.setReaderPreferences(ReaderPreferences(mode: mode));
        final remote = _Remote();
        await tester.pumpWidget(
          MaterialApp(
            theme: novelTheme(Brightness.light),
            home: ReaderPage(
              novel: _book,
              state: state,
              repository: remote,
              initialChapter: 0,
            ),
          ),
        );
        await settleReader(tester);
        expect(state.positionFor(_book.id)?.chapter ?? 0, 0);
        expect(
          remote.calls[102],
          1,
          reason: 'neighbor is ready before turning',
        );
        if (mode == ReaderMode.scroll) {
          final view = tester.widget<CustomScrollView>(
            find.byKey(const ValueKey('reader-scroll')),
          );
          view.controller!.jumpTo(view.controller!.position.maxScrollExtent);
          await tester.pumpAndSettle();
          expect(
            state.positionFor(_book.id)?.chapter ?? 0,
            0,
            reason: 'programmatic jump never auto advances',
          );
          await tester.drag(
            find.byKey(const ValueKey('reader-scroll')),
            const Offset(0, -160),
          );
        } else {
          final controller = tester
              .widget<ReaderPagedView>(find.byType(ReaderPagedView))
              .controller;
          controller.seek(1);
          await settleReader(tester);
          expect(controller.page, controller.pageCount - 1);
          await tester.drag(
            find.byType(PageView),
            Offset(mode == ReaderMode.vertical ? 220 : -220, 0),
          );
        }
        await settleReader(tester);
        await tester.pump(const Duration(milliseconds: 200));
        expect(state.positionFor(_book.id)!.chapter, 1);
        expect(remote.calls[102], 1);
        if (mode == ReaderMode.scroll) {
          await tester.drag(
            find.byKey(const ValueKey('reader-scroll')),
            const Offset(0, 160),
          );
        } else {
          await tester.drag(
            find.byType(PageView),
            Offset(mode == ReaderMode.vertical ? -220 : 220, 0),
          );
        }
        await settleReader(tester);
        await tester.pump(const Duration(milliseconds: 200));
        expect(state.positionFor(_book.id)!.chapter, 0);
        expect(remote.calls[101], 1);
        expect(tester.takeException(), isNull);
      },
    );
  }

  test(
    'server Tags survive sparse full-meta and serialize without invented labels',
    () async {
      final repo = LegacyWenkuRepository(
        request: (action) async {
          if (action.startsWith('action=novellist')) {
            return '<result><page num="1"/><item aid="91"><data name="Title" value="连续阅读"/><data name="Tags" value="奇幻 冒险 奇幻"/></item></result>';
          }
          if (action.contains('do=intro')) return '作品简介';
          return '<metadata><data name="Title" value="连续阅读"/></metadata>';
        },
      );
      final fromMeta = await repo.find(91);
      expect(fromMeta!.tags, isEmpty);
      final fromList = (await repo.browse()).items.single;
      final detail = await repo.detail(fromList);
      expect(detail.tags, ['奇幻', '冒险']);
      expect(Novel.fromSnapshot(detail.toSnapshot()).tags, detail.tags);
      expect((await repo.detail(_book.withGenre('轻小说'))).tags, detail.tags);
    },
  );

  for (final mode in [ReaderMode.paged, ReaderMode.vertical]) {
    testWidgets(
      '${mode.name} one-spread chapters can cross by swipe and stop at book end',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final state = await _state();
        addTearDown(state.dispose);
        await state.setReaderPreferences(ReaderPreferences(mode: mode));
        final short = _book.withChapters([
          for (var i = 0; i < 3; i++)
            NovelChapter('短章${i + 1}', '只有一段的短章正文。', id: 501 + i),
        ]);
        await tester.pumpWidget(
          MaterialApp(
            theme: novelTheme(Brightness.light),
            home: ReaderPage(
              novel: short,
              state: state,
              repository: _Remote(),
              initialChapter: 1,
            ),
          ),
        );
        await settleReader(tester);
        final pager = tester
            .widget<ReaderPagedView>(find.byType(ReaderPagedView))
            .controller;
        expect(pager.pageCount, 1);
        expect(pager.pagesPerSpread, 2);
        final next = Offset(mode == ReaderMode.vertical ? 200 : -200, 0);
        await tester.drag(find.byType(PageView), -next);
        await settleReader(tester);
        await tester.pump(const Duration(milliseconds: 200));
        expect(state.positionFor(short.id)!.chapter, 0);
        for (final chapter in [1, 2, 2]) {
          await tester.drag(find.byType(PageView), next);
          await settleReader(tester);
          await tester.pump(const Duration(milliseconds: 200));
          expect(state.positionFor(short.id)!.chapter, chapter);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
}
