import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/library_backup.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/local_books.dart';
import 'package:wenku8_flutter/local_book_media.dart';
import 'package:wenku8_flutter/local_book_series.dart';
import 'package:wenku8_flutter/local_series_actions.dart';
import 'support/local_series_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  Future<LocalBookStore> store() async {
    final dir = await Directory.systemTemp.createTemp('local-series-');
    addTearDown(() => dir.delete(recursive: true));
    final books = LocalBookStore(dir);
    addTearDown(books.dispose);
    await books.load();
    return books;
  }

  Future<List<Novel>> volumes(LocalBookStore books, int count) async => [
    for (var n = 1; n <= count; n++)
      await books.import(LocalBookInput('星海图书馆.$n.epub', seriesEpubFixture(n))),
  ];
  List<({int bookId, String title})> draft(List<Novel> books) => [
    for (final (i, book) in books.indexed)
      (bookId: book.id, title: '第 ${i + 1} 卷'),
  ];

  test(
    'volume inference recognizes Chinese, full-width and numeric suffixes without fuzzy merging',
    () {
      for (final title in [
        '星海图书馆 第一卷',
        '星海图书馆.01.epub',
        '星海图书馆 １',
        '星海图书馆 Vol. 1',
        '星海图书馆（01）',
      ]) {
        final hint = inferLocalSeries(title)!;
        expect(hint.key, '星海图书馆');
        expect(hint.number, 1);
      }
      expect(inferLocalSeries('星海图书馆 第十二卷')!.number, 12);
      expect(inferLocalSeries('86'), isNull);
      expect(inferLocalSeries('1984'), isNull);
      expect(inferLocalSeries('星海图书馆'), isNull);
    },
  );

  test(
    'four originals become one durable series with grouped volumes and unchanged inline illustrations',
    () async {
      final books = await store();
      final originals = await volumes(books, 4);
      expect(
        books.books.length,
        4,
        reason: 'recognition alone must not merge books',
      );
      expect(books.relatedVolumes(originals.last.id).length, 3);
      final differentAuthor = await books.import(
        LocalBookInput('other.epub', seriesEpubFixture(5, author: '另一作者')),
      );
      expect(
        books.relatedVolumes(originals.last.id).map((b) => b.id),
        isNot(contains(differentAuthor.id)),
      );
      final combined = await books.saveSeries(
        title: '星海图书馆',
        volumes: draft(originals),
      );
      expect(books.books.map((b) => b.id), [differentAuthor.id, combined.id]);
      expect(books.originals.length, 5);
      expect(NovelVolume.of(combined.chapters).map((v) => v.title), [
        '第 1 卷',
        '第 2 卷',
        '第 3 卷',
        '第 4 卷',
      ]);
      expect(combined.chapters.map((c) => c.id).toSet().length, 8);
      for (final (n, original) in originals.indexed) {
        for (final (i, chapter) in original.chapters.indexed) {
          expect(
            await books.chapterContent(
              combined.id,
              combined.chapters[n * 2 + i],
            ),
            await books.chapterContent(original.id, chapter),
          );
        }
        expect(
          await File(
            '${books.directory.path}/${original.id}/original',
          ).exists(),
          isTrue,
        );
      }
      final cover = Uri.parse(combined.coverUrl!);
      expect(cover.host, '${combined.id}');
      expect(LocalBookMedia.valid(cover), isTrue);
      expect(
        await File(
          '${books.directory.path}/${cover.host}${cover.path}',
        ).exists(),
        isTrue,
      );
      final again = await books.import(
        LocalBookInput('renamed.epub', seriesEpubFixture(1)),
      );
      expect(again.id, originals.first.id);
      expect(books.seriesFor(again.id)!.id, combined.id);
      final restored = LocalBookStore(books.directory);
      addTearDown(restored.dispose);
      await restored.load();
      expect(
        restored.books.map((b) => b.id).toSet(),
        books.books.map((b) => b.id).toSet(),
      );
      expect(
        restored.book(combined.id)!.chapters.map((c) => c.id),
        combined.chapters.map((c) => c.id),
      );
      expect(
        await restored.chapterContent(combined.id, combined.chapters.last),
        contains('第 4 卷'),
      );
      final edited = await restored.updateMetadata(
        combined.id,
        title: '星海档案',
        author: '新作者',
        summary: '合订本简介',
      );
      expect(edited.author, '新作者');
      await restored.load();
      expect(restored.book(combined.id)!.summary, '合订本简介');
      expect(books.book(originals.first.id)!.title, '星海图书馆 1');
    },
  );

  test(
    'progress and bookmarks retain chapter identity through reorder, append, restart and dissolve',
    () async {
      final books = await store();
      final originals = await volumes(books, 3);
      final state = await LibraryState.load();
      addTearDown(state.dispose);
      for (final original in originals.take(2)) {
        await state.setShelfMembership(original.id, true, novel: original);
        await state.savePosition(
          novel: original,
          chapter: 1,
          offset: 140,
          maximum: 1000,
          width: 390,
          paragraphIndex: 3,
          textOffset: 12,
        );
        await state.addBookmark(
          novel: original,
          position: state.positionFor(original.id)!,
        );
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      var merged = await saveLocalSeries(
        books: books,
        library: state,
        title: '星海图书馆',
        volumes: draft(originals.take(2).toList()),
      );
      final savedChapterId = state.positionFor(merged.id)!.chapterId;
      expect(state.shelf, isEmpty);
      expect(state.chapterForNovel(merged), 3);
      expect(state.positionFor(merged.id)!.textOffset, 12);
      expect(state.bookmarksFor(merged.id).length, 2);
      expect(state.bookmarksFor(originals.first.id).length, 1);
      expect(state.positionFor(originals.first.id)!.paragraphIndex, 3);
      final oldIds = {for (final c in merged.chapters) c.id};
      merged = await saveLocalSeries(
        books: books,
        library: state,
        id: merged.id,
        title: merged.title,
        volumes: [
          (bookId: originals[1].id, title: '第二卷'),
          (bookId: originals[0].id, title: '第一卷'),
          (bookId: originals[2].id, title: '第三卷'),
        ],
      );
      expect(state.positionFor(merged.id)!.chapterId, savedChapterId);
      expect(state.chapterForNovel(merged), 1);
      expect(
        oldIds.difference(merged.chapters.map((c) => c.id).toSet()),
        isEmpty,
      );
      final removed = state.bookmarksFor(merged.id).first;
      await state.removeBookmark(merged.id, removed.id);
      await reconcileLocalSeries(books, state);
      expect(
        state.bookmarksFor(merged.id).length,
        1,
        reason: 'a deleted bookmark must not resurrect on reconciliation',
      );
      final backup = await LibraryBackup.parse(
        await (await state.createBackup()).encode(),
      );
      expect(
        backup.records.keys.any((k) => k.startsWith('book_merge_')),
        isTrue,
      );
      final restarted = LibraryState(await SharedPreferences.getInstance());
      addTearDown(restarted.dispose);
      await reconcileLocalSeries(books, restarted);
      expect(restarted.bookmarksFor(merged.id).length, 1);
      await restarted.savePosition(
        novel: merged,
        chapter: 4,
        offset: 800,
        maximum: 1000,
        width: 390,
        paragraphIndex: 5,
        textOffset: 29,
      );
      await restarted.addBookmark(
        novel: merged,
        position: restarted.positionFor(merged.id)!,
      );
      await dissolveLocalSeries(
        books: books,
        library: restarted,
        series: books.seriesFor(merged.id)!,
      );
      expect(books.books.length, 3);
      expect(books.series, isEmpty);
      expect(restarted.shelf, isEmpty);
      expect(restarted.positionFor(originals[2].id)!.textOffset, 29);
      expect(restarted.chapterForNovel(originals[2]), 0);
      expect(restarted.bookmarksFor(originals[2].id).length, 1);
      expect(
        restarted.bookmarksFor(originals.first.id).length,
        1,
        reason: 'restoring originals does not duplicate copied marks',
      );
      await books.load();
      expect(books.books.length, 3);
    },
  );

  test(
    'invalid or conflicting membership never changes existing books',
    () async {
      final books = await store();
      final originals = await volumes(books, 4);
      final first = await books.saveSeries(
        title: '第一部',
        volumes: draft(originals.take(2).toList()),
      );
      await expectLater(
        books.saveSeries(
          title: '重复',
          volumes: draft([originals[0], originals[2]]),
        ),
        throwsFormatException,
      );
      await expectLater(
        books.saveSeries(title: '', volumes: draft(originals.skip(2).toList())),
        throwsFormatException,
      );
      await expectLater(
        books.saveSeries(
          title: '重复卷',
          volumes: draft([originals[2], originals[2]]),
        ),
        throwsFormatException,
      );
      expect(books.series.single.id, first.id);
      expect(books.originals.length, 4);
      expect(books.books.length, 3);
      await books.remove(first.id);
      expect(
        books.originals.map((b) => b.id).toSet(),
        originals.skip(2).map((b) => b.id).toSet(),
      );
      expect(books.books.length, 2);
    },
  );
  test(
    'deleting a series keeps each volume resumable when re-imported alone',
    () async {
      final books = await store();
      final originals = await volumes(books, 2);
      final library = await LibraryState.load();
      addTearDown(library.dispose);
      final merged = await saveLocalSeries(
        books: books,
        library: library,
        title: '星海图书馆',
        volumes: draft(originals),
      );
      await library.savePosition(
        novel: merged,
        chapter: 3,
        offset: 480,
        maximum: 1000,
        width: 390,
        paragraphIndex: 5,
        textOffset: 26,
      );
      await library.addBookmark(
        novel: merged,
        position: library.positionFor(merged.id)!,
      );
      await removeLocalBook(books: books, library: library, id: merged.id);
      expect(books.books, isEmpty);
      expect(library.shelf, isEmpty);
      final reimported = await books.import(
        LocalBookInput('第二卷.epub', seriesEpubFixture(2)),
      );
      expect(reimported.id, originals[1].id);
      expect(library.positionFor(reimported.id)!.textOffset, 26);
      expect(library.chapterForNovel(reimported), 1);
      expect(library.bookmarksFor(reimported.id).length, 1);
      expect(library.positionFor(merged.id), isNotNull);
    },
  );
}
