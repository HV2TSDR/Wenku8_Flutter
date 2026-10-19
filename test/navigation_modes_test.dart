import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/glass_dock.dart';
import 'package:wenku8_flutter/home_navigation.dart';
import 'package:wenku8_flutter/library_backup.dart';
import 'package:wenku8_flutter/library_search_repository.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/local_books.dart';
import 'package:wenku8_flutter/local_library_page.dart';
import 'package:wenku8_flutter/network_status.dart';
import 'package:wenku8_flutter/offline_cache.dart';
import 'package:wenku8_flutter/offline_repository.dart';
import 'package:wenku8_flutter/pages.dart';

import 'support/visual_review.dart';

class _Remote extends DemoNovelRepository {
  int finds = 0, details = 0, directories = 0, bodies = 0, lists = 0;
  @override
  Future<Novel?> find(int id) async {
    finds++;
    return super.find(id);
  }

  @override
  Future<Novel> detail(Novel book) async {
    details++;
    return book;
  }

  @override
  Future<List<NovelChapter>> chapters(int id) async {
    directories++;
    return super.chapters(id);
  }

  @override
  Future<String> chapterContent(int id, NovelChapter chapter) async {
    bodies++;
    return chapter.content;
  }

  @override
  Future<List<Novel>> list() async {
    lists++;
    return super.list();
  }
}

class _Fixture {
  _Fixture(
    this.root,
    this.state,
    this.network,
    this.cache,
    this.local,
    this.remote,
    this.repository,
    this.cached,
    this.uncached,
    this.imported,
  );
  final Directory root;
  final LibraryState state;
  final NetworkStatus network;
  final OfflineCacheStore cache;
  final LocalBookStore local;
  final _Remote remote;
  final OfflineNovelRepository repository;
  final Novel cached, uncached, imported;

  static Future<_Fixture> create() async {
    SharedPreferences.setMockInitialValues({'shelfLayout': 'list'});
    final state = await LibraryState.load();
    final root = await Directory.systemTemp.createTemp('wenku-mode-test-');
    final network = NetworkStatus(initial: NetworkReachability.offline);
    final cache = OfflineCacheStore(Directory('${root.path}/cache'));
    final local = LocalBookStore(Directory('${root.path}/books'));
    final remote = _Remote();
    final repository = OfflineNovelRepository(
      remote: remote,
      cache: cache,
      local: local,
      network: network,
    );
    final cached = demoNovels.first.withChapters(const [
      NovelChapter('已缓存的第一章', '', id: 11),
      NovelChapter('尚未缓存的第二章', '', id: 12),
    ]);
    final uncached = demoNovels[1].withChapters(const [
      NovelChapter('只有目录，没有正文', '', id: 21),
    ]);
    await cache.saveBook(cached, epoch: cache.epochFor(cached.id));
    await cache.saveChapter(
      cached.id,
      11,
      '真实缓存路径中的正文。',
      epoch: cache.epochFor(cached.id),
    );
    await cache.saveBook(uncached, epoch: cache.epochFor(uncached.id));
    final bytes = Uint8List.fromList(utf8.encode('第一章\n本地原书正文。'));
    final imported = await local.import(LocalBookInput('本地原书.txt', bytes));
    for (final book in [cached, uncached, imported]) {
      await state.setShelfMembership(book.id, true, novel: book);
    }
    return _Fixture(
      root,
      state,
      network,
      cache,
      local,
      remote,
      repository,
      cached,
      uncached,
      imported,
    );
  }

  Future<void> close() async {
    repository.dispose();
    cache.dispose();
    local.dispose();
    state.dispose();
    network.dispose();
    await root.delete(recursive: true);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadReviewFonts);

  testWidgets(
    'default-network handovers debounce and do not invent an outage on errors',
    (tester) async {
      final network = NetworkStatus();
      addTearDown(network.dispose);
      network.accept('offline', initial: true);
      expect(network.offline, true);
      network.accept('online');
      network.accept('offline');
      await tester.pump(const Duration(milliseconds: 400));
      network.accept('online');
      await tester.pump(const Duration(seconds: 2));
      expect(network.value, NetworkReachability.online);
      network.accept('checking');
      await tester.pump(const Duration(milliseconds: 1799));
      expect(network.offline, false);
      await tester.pump(const Duration(milliseconds: 1));
      expect(network.offline, true);
      network.accept(null);
      expect(network.value, NetworkReachability.unknown);
    },
  );

  test(
    'mode preferences persist, restore and override only navigation',
    () async {
      SharedPreferences.setMockInitialValues({});
      final state = await LibraryState.load();
      final network = NetworkStatus(initial: NetworkReachability.offline);
      final navigation = HomeNavigation(state, network);
      addTearDown(() {
        navigation.dispose();
        network.dispose();
        state.dispose();
      });
      var appearance = 0;
      state.applicationChanges.addListener(() => appearance++);
      expect(navigation.tabs, [1, 2, 3]);
      expect(navigation.destination(0), 1);
      await state.setNavigationMode(localReaderMode: true);
      expect(navigation.tabs, [2, 3]);
      expect(navigation.destination(1), 2);
      expect(navigation.destination(3), 3);
      final backup = await state.createBackup();
      await state.setNavigationMode(
        localReaderMode: false,
        adaptWhenOffline: false,
      );
      expect(navigation.tabs, [0, 1, 2, 3]);
      expect(appearance, 0);
      await state.restoreBackup(backup, importPreferences: true);
      expect(state.localReaderMode, true);
      expect(state.adaptWhenOffline, true);
      final restored = await LibraryState.load();
      addTearDown(restored.dispose);
      expect(restored.localReaderMode, true);
      await expectLater(
        LibraryBackup.fromRecords({'localReaderMode': 'true'}),
        throwsFormatException,
      );
    },
  );

  test(
    'offline metadata, directory and body never wait for a remote failure',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.close);
      expect((await f.repository.find(f.cached.id))!.chapters.length, 2);
      expect((await f.repository.detail(f.cached)).chapters.length, 2);
      expect((await f.repository.chapters(f.cached.id)).length, 2);
      expect(
        await f.repository.chapterContent(f.cached.id, f.cached.chapters.first),
        contains('缓存路径'),
      );
      await expectLater(
        f.repository.chapterContent(f.cached.id, f.cached.chapters.last),
        throwsFormatException,
      );
      expect(
        await f.repository.repairChapterIllustrations(
          f.cached.id,
          f.cached.chapters.first,
        ),
        isNull,
      );
      expect(
        [
          f.remote.finds,
          f.remote.details,
          f.remote.directories,
          f.remote.bodies,
        ],
        [0, 0, 0, 0],
      );
      expect(f.repository.availableOffline(f.cached.id), true);
      expect(f.repository.availableOffline(f.uncached.id), false);
      expect(f.repository.availableOffline(f.imported.id), true);
      final search = LibrarySearchRepository(
        source: f.repository,
        state: f.state,
        local: f.local,
        cachedOnly: () => true,
      );
      expect((await search.list()).map((book) => book.id).toSet(), {
        f.cached.id,
      });
      f.network.value = NetworkReachability.online;
      await f.repository.detail(f.cached);
      expect(f.remote.details, 1);
    },
  );

  testWidgets(
    'offline tabs, cached search and local-reader switching retain page identities',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final f = (await tester.runAsync(_Fixture.create))!;
      final capture = GlobalKey();
      try {
        await tester.pumpWidget(
          RepaintBoundary(
            key: capture,
            child: MaterialApp(
              theme: novelTheme(Brightness.light),
              home: HomeShell(
                state: f.state,
                repository: f.repository,
                network: f.network,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        GlassDock dock() => tester.widget<GlassDock>(find.byType(GlassDock));
        List<String> labels() =>
            dock().items.map((item) => item.label).toList();
        expect(labels(), ['书架', '本地', '我的']);
        expect(
          find.byKey(ValueKey('shelf-book-${f.cached.id}')),
          findsOneWidget,
        );
        expect(
          find.byKey(ValueKey('shelf-book-${f.uncached.id}')),
          findsNothing,
        );
        expect(
          find.byKey(ValueKey('shelf-book-${f.imported.id}')),
          findsNothing,
        );
        expect(f.remote.lists, 0);
        await captureReview(tester, capture, 'offline-cached-shelf');

        final shelfElement = tester.element(find.byType(ShelfPage));
        final width = tester.getSize(find.byType(GlassDock)).width;
        f.network.value = NetworkReachability.online;
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 150));
        final midWidth = tester.getSize(find.byType(GlassDock)).width;
        expect(midWidth, greaterThan(width));
        expect(midWidth, lessThan(4 * (184 / 3) + 12));
        expect(
          find.descendant(
            of: find.byKey(ValueKey('shelf-resolve-${f.cached.id}')),
            matching: find.byType(BookRowSkeleton),
          ),
          findsNothing,
          reason: 'A navigation change must not re-show the warm row skeleton',
        );
        await tester.pumpAndSettle();
        expect(labels(), ['发现', '书架', '本地', '我的']);
        expect(
          find.byKey(ValueKey('shelf-book-${f.uncached.id}')),
          findsOneWidget,
        );
        expect(
          identical(tester.element(find.byType(ShelfPage)), shelfElement),
          true,
        );

        await tester.tap(
          find.descendant(
            of: find.byType(GlassDock),
            matching: find.text('我的'),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('my-settings')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('settings-usage-entry')));
        await tester.pumpAndSettle();
        final toggle = find.byKey(const ValueKey('settings-local-reader-mode'));
        await tester.ensureVisible(toggle);
        await tester.tap(toggle);
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pumpAndSettle();
        expect(tester.widget<AppGlassSwitch>(toggle).value, true);
        final settingsRect = tester.getRect(
          find.byKey(const PageStorageKey('settings-usage')),
        );
        // Scroll from the list gutter, not a thumb that deliberately captures
        // its pointer for the package's grab-and-carry interaction.
        await tester.dragFrom(
          Offset(settingsRect.left + 8, settingsRect.center.dy),
          const Offset(0, 900),
        );
        await tester.pumpAndSettle();
        await captureReview(tester, capture, 'local-reader-settings');
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(labels(), ['本地', '我的']);
        expect(dock().selectedIndex, 1);

        await tester.tap(
          find.descendant(
            of: find.byType(GlassDock),
            matching: find.text('本地'),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('本地原书'), findsWidgets);
        await captureReview(tester, capture, 'local-reader-library');
        final localElement = tester.element(find.byType(LocalLibraryPage));
        await f.state.setNavigationMode(combinedShelf: true);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 120));
        expect(labels(), ['书架', '我的']);
        expect(dock().selectedIndex, 0);
        await captureReview(tester, capture, 'combined-navigation-changing');
        await tester.pumpAndSettle();
        expect(
          find.byKey(ValueKey('shelf-book-${f.imported.id}')),
          findsOneWidget,
        );
        await captureReview(tester, capture, 'combined-navigation-reader');
        await tester.tap(find.byKey(const ValueKey('shelf-import-book')));
        await tester.pumpAndSettle();
        expect(find.text('导入书籍'), findsWidgets);
        expect(find.text('从网盘导入'), findsOneWidget);
        await tester.tap(find.text('本地分类与同步'));
        await tester.pumpAndSettle();
        expect(find.byType(LocalLibraryPage), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('local-display')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('更多本地设置'));
        await tester.pumpAndSettle();
        expect(find.text('书库设置'), findsOneWidget);
        expect(find.text('跨设备同步设置'), findsOneWidget);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        await f.state.setNavigationMode(localReaderMode: false);
        await tester.pumpAndSettle();
        expect(labels(), ['发现', '书架', '我的']);
        expect(dock().selectedIndex, 1);
        await captureReview(tester, capture, 'combined-navigation-online');
        f.network.value = NetworkReachability.offline;
        await tester.pumpAndSettle();
        expect(labels(), ['书架', '我的']);
        expect(dock().selectedIndex, 0);
        await f.state.setNavigationMode(combinedShelf: false);
        await tester.pumpAndSettle();
        expect(labels(), ['书架', '本地', '我的']);
        await tester.tap(
          find.descendant(
            of: find.byType(GlassDock),
            matching: find.text('本地'),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          tester.element(find.byType(LocalLibraryPage)),
          same(localElement),
        );
        expect(f.remote.lists, 0);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(f.close);
      }
    },
  );

  for (final brightness in Brightness.values) {
    testWidgets('mode settings fit narrow large-text ${brightness.name}', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({});
      final state = await LibraryState.load();
      final capture = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: capture,
          child: MaterialApp(
            theme: novelTheme(brightness),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(1.5)),
              child: child!,
            ),
            home: Scaffold(body: SettingsPage(state: state)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings-usage-entry')));
      await tester.pumpAndSettle();
      final offline = tester.getRect(
        find.byKey(const ValueKey('settings-adapt-offline')),
      );
      final local = tester.getRect(
        find.byKey(const ValueKey('settings-local-reader-mode')),
      );
      expect(offline.overlaps(local), false);
      final description = tester.getRect(find.text('断网后隐藏发现，书架只显示已缓存的收藏'));
      expect(description.overlaps(offline), false);
      expect(description.right, lessThanOrEqualTo(320 - 24));
      expect(tester.takeException(), isNull);
      await captureReview(
        tester,
        capture,
        'mode-settings-large-${brightness.name}',
      );
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    });
  }
}
