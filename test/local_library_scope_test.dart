import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/library_backup.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/library_search_repository.dart';
import 'package:wenku8_flutter/local_books.dart';
import 'package:wenku8_flutter/local_library_page.dart';
import 'package:wenku8_flutter/offline_cache.dart';
import 'package:wenku8_flutter/offline_repository.dart';
import 'package:wenku8_flutter/pages.dart';
import 'cloud_library_ui_test.dart' show ioSettle;

final _local = Novel(
  id: localBookIdStart + 1,
  title: '只在本地的原书',
  author: '本地作者',
  genre: '本地',
  summary: '',
  colors: const [Colors.grey, Colors.black],
  chapters: const [NovelChapter('第一章', '本地原书的正文。', id: 100)],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({'reduceMotion': true}));
  Future<void> saveReading(LibraryState state) async {
    await state.savePosition(
      novel: _local,
      chapter: 0,
      offset: 123,
      maximum: 1000,
      width: 390,
      paragraphIndex: 2,
      textOffset: 11,
    );
    await state.addBookmark(
      novel: _local,
      position: state.positionFor(_local.id)!,
    );
  }

  test(
    'startup moves legacy local memberships out of the shelf, preserving records',
    () async {
      final before = await LibraryState.load();
      await saveReading(before);
      final prefs = await SharedPreferences.getInstance();
      final saved = {
        for (final key in prefs.getKeys())
          if (key != 'shelf') key: prefs.get(key),
      };
      await prefs.setStringList('shelf', [
        '1',
        '${_local.id}',
        '${localBookIdStart + 2}',
      ]);
      before.dispose();
      final migrated = await LibraryState.load();
      addTearDown(migrated.dispose);
      expect(migrated.shelf, {1});
      expect(prefs.getStringList('shelf'), ['1']);
      expect(migrated.positionFor(_local.id)!.textOffset, 11);
      expect(migrated.bookmarksFor(_local.id).length, 1);
      for (final entry in saved.entries) {
        expect(prefs.get(entry.key), entry.value);
      }
      final restarted = await LibraryState.load();
      addTearDown(restarted.dispose);
      expect(restarted.shelf, {1});
      expect(restarted.hasRead(_local.id), true);
    },
  );

  test(
    'all membership entry points exclude locals while keeping online collection usable',
    () async {
      final state = await LibraryState.load();
      addTearDown(state.dispose);
      await state.setShelfMembership(_local.id, true, novel: _local);
      await state.toggleShelf(_local.id, novel: _local);
      await state.addShelfIds([_local.id, 1, 2]);
      expect(state.shelf, {1, 2});
      expect(state.cachedNovel(_local.id)?.title, _local.title);
      await state.toggleShelf(1);
      expect(state.shelf, {2});
      await state.toggleShelf(1, novel: demoNovels.first);
      expect(state.shelf, {1, 2});
      await state.combineBookRecords(
        target: _local,
        sources: {},
        onShelf: true,
      );
      expect(state.shelf, {1, 2});
      final backup = await state.createBackup();
      expect(backup.records['shelf'], ['2', '1']);
    },
  );

  test(
    'legacy backup restores local reading and bookmarks but never local shelf entries',
    () async {
      final source = await LibraryState.load();
      addTearDown(source.dispose);
      await saveReading(source);
      final backup = await LibraryBackup.fromRecords({
        ...(await source.createBackup()).records,
        'shelf': ['1', '${_local.id}'],
      });
      expect(backup.shelfCount, 1);
      SharedPreferences.setMockInitialValues({});
      final target = await LibraryState.load();
      addTearDown(target.dispose);
      await target.restoreBackup(backup);
      expect(target.shelf, {1});
      expect(target.positionFor(_local.id)!.offset, 123);
      expect(target.bookmarksFor(_local.id).length, 1);
      expect(target.cachedNovel(_local.id)!.title, _local.title);
      expect((await target.createBackup()).records['shelf'], ['1']);
    },
  );

  testWidgets(
    'local book remains in local tab/search, not shelf tab/search, also offline',
    (tester) async {
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('separate-library-'),
      ))!;
      addTearDown(() => root.delete(recursive: true));
      final fixture = (await tester.runAsync(() async {
        final books = LocalBookStore(Directory('${root.path}/books'));
        await books.load();
        const text = '第一章\n这是只在本地页面出现的正文。';
        final local = await books.import(
          LocalBookInput(
            '我的本地原书.txt',
            Uint8List.fromList(utf8.encode(text)),
            text: text,
          ),
        );
        final cache = OfflineCacheStore(Directory('${root.path}/cache'));
        await cache.load();
        return (books: books, local: local, cache: cache);
      }))!;
      final books = fixture.books, local = fixture.local, cache = fixture.cache;
      addTearDown(books.dispose);
      addTearDown(cache.dispose);
      final repository = OfflineNovelRepository(
        remote: const DemoNovelRepository(),
        cache: cache,
        local: books,
      );
      addTearDown(repository.dispose);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('shelf', [
        '${demoNovels.first.id}',
        '${local.id}',
      ]);
      final state = await LibraryState.load();
      addTearDown(state.dispose);
      await state.rememberNovel(demoNovels.first);
      await state.setShelfView(layout: 'list');
      final shelf = LibrarySearchRepository(
        source: repository,
        state: state,
        local: books,
      );
      final localSearch = LibrarySearchRepository(
        source: repository,
        state: state,
        local: books,
        localOnly: true,
      );
      expect(await tester.runAsync(() => shelf.search(local.title)), isEmpty);
      expect(
        (await tester.runAsync(
          () => localSearch.search(local.title),
        ))!.single.id,
        local.id,
      );
      final offlineShelf = LibrarySearchRepository(
        source: repository,
        state: state,
        local: books,
        cachedOnly: () => true,
      );
      expect(
        await tester.runAsync(() => offlineShelf.search(local.title)),
        isEmpty,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: novelTheme(Brightness.light),
          home: HomeShell(state: state, repository: repository),
        ),
      );
      await ioSettle(tester);
      await tester.tap(find.byKey(const ValueKey('dock-tab-1')));
      await ioSettle(tester);
      expect(find.text(local.title), findsNothing);
      expect(find.text(demoNovels.first.title), findsWidgets);
      await tester.tap(find.byKey(const ValueKey('dock-tab-2')));
      await ioSettle(tester);
      expect(find.byType(LocalLibraryPage), findsOneWidget);
      expect(find.text(local.title), findsWidgets);
      expect(books.contains(local.id), true);
      expect(
        await tester.runAsync(
          () => books.chapterContent(local.id, local.chapters.first),
        ),
        contains('只在本地页面'),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
