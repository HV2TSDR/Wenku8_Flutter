import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/bookshelf_scope.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/library_search_repository.dart';
import 'package:wenku8_flutter/local_books.dart';
import 'package:wenku8_flutter/local_library_preferences.dart';
import 'package:wenku8_flutter/offline_cache.dart';
import 'package:wenku8_flutter/offline_repository.dart';
import 'package:wenku8_flutter/pages.dart';
import 'support/visual_review.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadReviewFonts);
  test(
    'categories compose with source, offline and merged views without membership changes',
    () async {
      SharedPreferences.setMockInitialValues({});
      final state = LibraryState(await SharedPreferences.getInstance());
      addTearDown(state.dispose);
      final root = await Directory.systemTemp.createTemp('wenku-shelf-groups-');
      addTearDown(() => root.delete(recursive: true));
      final local = LocalBookStore(Directory('${root.path}/books'));
      await local.load();
      addTearDown(local.dispose);
      final imported = await local.import(
        LocalBookInput('本地.txt', Uint8List.fromList(utf8.encode('第一章\n正文'))),
      );
      final cache = OfflineCacheStore(Directory('${root.path}/cache'));
      await cache.load();
      final cached = demoNovels.first.withChapters(const [
        NovelChapter('缓存章节', '', id: 11),
      ]);
      await cache.saveBook(cached, epoch: cache.epochFor(cached.id));
      await cache.saveChapter(
        cached.id,
        11,
        '正文',
        epoch: cache.epochFor(cached.id),
      );
      final repo = OfflineNovelRepository(
        remote: const DemoNovelRepository(),
        cache: cache,
        local: local,
      );
      addTearDown(repo.dispose);
      await state.setShelfMembership(cached.id, true, novel: cached);
      await state.setShelfMembership(
        demoNovels[1].id,
        true,
        novel: demoNovels[1],
      );
      final groups = state.organization;
      final group = await groups.addGroup('冒险');
      for (final id in [cached.id, imported.id]) {
        await groups.assign(id, group);
      }
      await groups.select(group, shelf: true);
      expect(groups.selected, LocalLibraryPreferences.all);
      expect(bookshelfIds(state, repo), {cached.id});
      await state.setNavigationMode(combinedShelf: true);
      expect(bookshelfIds(state, repo), {cached.id, imported.id});
      expect(bookshelfIds(state, repo, readableOnly: true), {
        cached.id,
        imported.id,
      });
      await state.setShelfView(source: 'local');
      expect(bookshelfIds(state, repo), {imported.id});
      final search = LibrarySearchRepository(
        source: repo,
        state: state,
        local: local,
      );
      expect((await search.search('冒险')).single.id, imported.id);
      await state.setShelfView(source: 'cached');
      expect(bookshelfIds(state, repo), {cached.id});
      await state.setNavigationMode(combinedShelf: false);
      expect(bookshelfIds(state, repo), {cached.id});
      expect(state.shelf, {cached.id, demoNovels[1].id});
      final restarted = LocalLibraryPreferences(
        await SharedPreferences.getInstance(),
      )..load();
      addTearDown(restarted.dispose);
      expect(restarted.shelfSelected, group);
      expect(restarted.groupOf(imported.id), group);
      final exported = groups.exportOrganization();
      expect(
        LocalLibraryPreferences.validateOrganization(exported),
        isNotEmpty,
      );
      await groups.removeGroup(group);
      expect(groups.shelfSelected, LocalLibraryPreferences.all);
      expect(groups.groupOf(cached.id), LocalLibraryPreferences.unfiled);
    },
  );
  testWidgets(
    'unmerged shelf shares category management and assignment sheet',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({
        'reduceMotion': true,
        'shelfLayout': 'list',
      });
      final state = LibraryState(await SharedPreferences.getInstance());
      addTearDown(state.dispose);
      final book = demoNovels.first;
      await state.setShelfMembership(book.id, true, novel: book);
      final group = await state.organization.addGroup('正在追更');
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: novelTheme(Brightness.light),
          home: RepaintBoundary(
            key: key,
            child: Scaffold(
              body: ShelfPage(
                books: [book],
                state: state,
                repository: const DemoNovelRepository(),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('shelf-category')));
      await tester.pumpAndSettle();
      expect(find.text('书籍分类'), findsOneWidget);
      expect(find.text('新建分类'), findsOneWidget);
      await tester.tap(find.text('正在追更'));
      await tester.pumpAndSettle();
      expect(state.organization.shelfSelected, group);
      expect(find.text('没有符合条件的书'), findsOneWidget);
      await state.organization.assign(book.id, group);
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('shelf-book-${book.id}')), findsOneWidget);
      await captureReview(tester, key, 'shelf-shared-category');
      expect(tester.takeException(), isNull);
    },
  );
}
