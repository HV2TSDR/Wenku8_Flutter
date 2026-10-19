import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/illustration_placement.dart';
import 'package:wenku8_flutter/library_backup.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/reader_content.dart';
import 'package:wenku8_flutter/reader_pagination.dart';
import 'package:wenku8_flutter/reader_preferences.dart';
import 'support/offline_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final book = offlineFixtureBook(71);
  const url = 'https://pic.wenku8.cn/pictures/1/test.jpg';
  final prose = ['第一段：相遇。', '第二段：窗边有微风。', '第三段：继续前行。'];
  IllustrationPlacement placement({int paragraph = 1}) =>
      IllustrationPlacement.at(
        chapterId: book.chapters.first.id,
        chapterTitle: '第一章',
        url: url,
        paragraphs: prose,
        paragraph: paragraph,
      );
  ReadingPosition position({int offset = 2}) => ReadingPosition(
    chapter: 0,
    chapterId: book.chapters.first.id,
    offset: 0,
    fraction: 0,
    fontSize: 19,
    lineHeight: 1.72,
    width: 390,
    updatedAt: 500,
    paragraphIndex: 1,
    textOffset: offset,
  );
  Future<LibraryState> library() async {
    final state = await LibraryState.load();
    addTearDown(state.dispose);
    return state;
  }

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'excerpts keep exact source offsets and survive full backup/restore',
    () async {
      final state = await library();
      final first = await state.addBookmark(
        novel: book,
        position: position(),
        quote: '  窗边有微风。  ',
      );
      final same = await state.addBookmark(
        novel: book,
        position: position(),
        quote: '窗边有微风。',
      );
      final other = await state.addBookmark(
        novel: book,
        position: position(offset: 4),
        quote: '窗边有微风。',
      );
      expect(same!.id, first!.id);
      expect(other!.id, isNot(first.id));
      expect(state.bookmarkEntries, hasLength(2));
      expect(state.readingHistoryIds, isEmpty);
      expect(state.positionFor(book.id), isNull);
      expect(state.cachedNovel(book.id)!.title, book.title);
      final backup = await LibraryBackup.parse(
        await (await state.createBackup()).encode(),
      );
      SharedPreferences.setMockInitialValues({});
      final restored = await library();
      await restored.restoreBackup(backup);
      final reloaded = await library();
      expect(reloaded.bookmarksFor(book.id).map((m) => m.quote), [
        '窗边有微风。',
        '窗边有微风。',
      ]);
      expect(
        reloaded
            .bookmarksFor(book.id)
            .map((m) => m.position.textOffset)
            .toSet(),
        {2, 4},
      );
      expect(reloaded.readingHistoryIds, isEmpty);
      final old = first.toJson()..remove('quote');
      expect(ReaderBookmark.fromJson(old).quote, '');
    },
  );

  test(
    'placement uses context rather than stale indices or image ordinals',
    () {
      final anchor = placement();
      expect(anchor.resolve(['新段落', ...prose]), 2);
      expect(anchor.resolve([prose[0], '第二段：已经改写。', prose[2]]), isNull);
      expect(anchor.resolve([...prose, ...prose]), isNull);
      expect(anchor.resolve(['重复的前文', prose[1], '其他后文', ...prose]), 4);
      expect(
        placement(paragraph: 0).resolve([' 第 一段：相遇。 ', ...prose.skip(1)]),
        0,
      );
      expect(
        () => IllustrationPlacement.fromJson({
          ...anchor.toJson(),
          'url': 'https://example.com/x.png',
        }),
        throwsFormatException,
      );
    },
  );

  test(
    'inline order leaves every original paragraph and selection ID unchanged',
    () {
      final original = ReaderContent(prose);
      final content = placeIllustrations(original, [placement()]);
      expect(original.paragraphs, prose);
      expect(content.paragraphs.take(prose.length), prose);
      expect(content.order, [0, 1, 3, 2]);
      expect(content.inlineOwners, {3: 1});
      expect(content.illustrations, [url]);
      expect(identical(placeIllustrations(original, []), original), true);
      expect(
        placeIllustrations(original, [placement(), placement()]).illustrations,
        [url],
      );
    },
  );

  for (final mode in [ReaderMode.paged, ReaderMode.vertical]) {
    test(
      '$mode interleaves the confirmed image without renumbering prose',
      () async {
        final result = (await paginateReader(
          content: placeIllustrations(ReaderContent(prose), [placement()]),
          size: const Size(330, 600),
          style: const TextStyle(fontSize: 19, height: 1.72),
          preferences: ReaderPreferences(mode: mode),
          scaler: TextScaler.noScaling,
          current: () => true,
        ))!;
        final order = result.pages
            .expand((page) => page.fragments)
            .map((f) => f.paragraph)
            .toList();
        expect(order, [0, 1, 3, 2]);
        expect(
          result
              .pages[result.pageFor(const ReaderTextAnchor(2, 0))]
              .fragments
              .first
              .paragraph,
          2,
        );
      },
    );
  }

  test(
    'placement persistence is narrow, moves by URL and merges newer backup positions',
    () async {
      final state = await library();
      var changes = 0, history = 0;
      state.illustrationChanges.addListener(() => changes++);
      state.historyChanges.addListener(() => history++);
      await state.putIllustration(book.id, placement());
      final backup = await state.createBackup();
      await state.putIllustration(book.id, placement(paragraph: 0));
      await state.restoreBackup(backup);
      expect(state.illustrationsFor(book.id).single.resolve(prose), 0);
      final next = await library();
      expect(next.illustrationsFor(book.id).single.resolve(prose), 0);
      expect(changes, greaterThanOrEqualTo(2));
      expect(
        history,
        1,
        reason: 'Only the explicit backup restore publishes history',
      );
      final id = state.illustrationsFor(book.id).single.id;
      await state.removeIllustration(book.id, id);
      expect((await library()).illustrationsFor(book.id), isEmpty);
    },
  );

  test(
    'one damaged placement is isolated without losing valid records',
    () async {
      SharedPreferences.setMockInitialValues({
        'illustration_layout_71': jsonEncode([
          {'broken': true},
          placement().toJson(),
        ]),
      });
      expect((await library()).illustrationsFor(71), hasLength(1));
    },
  );
}
