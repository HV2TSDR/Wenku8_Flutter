import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/bookshelf_scope.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/local_books.dart';
import 'package:wenku8_flutter/local_book_removal.dart';
import 'package:wenku8_flutter/local_series_actions.dart';
import 'package:wenku8_flutter/bookmark_library_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late LocalBookStore books;
  late LibraryState library;
  setUp(() async {
    SharedPreferences.setMockInitialValues({'reduceMotion': true});
    root = await Directory.systemTemp.createTemp('local-removal-test-');
    books = LocalBookStore(Directory('${root.path}/app-library'));
    await books.load();
    library = await LibraryState.load();
  });
  tearDown(() async {
    books.dispose();
    library.dispose();
    await root.delete(recursive: true);
  });
  const text = '第一章\n风穿过窗边。';
  LocalBookInput input() => LocalBookInput(
    '原书.txt',
    Uint8List.fromList(utf8.encode(text)),
    text: text,
  );

  test(
    'shelf-only removal persists independently of the original, resume and excerpt; deletion frees app-owned files only',
    () async {
      final downloads = File('${root.path}/original-user-download.txt');
      await downloads.writeAsString(text);
      final book = await books.import(input());
      final mark = await library.addBookmark(
        novel: book,
        quote: '风穿过窗边。',
        position: ReadingPosition(
          chapter: 0,
          chapterId: book.chapters.first.id,
          offset: 0,
          fraction: 0,
          fontSize: 19,
          width: 390,
          updatedAt: 1,
        ),
      );
      await library.savePosition(
        novel: book,
        chapter: 0,
        offset: 40,
        maximum: 200,
        width: 390,
      );
      await library.setLocalBookHidden(book.id, true);
      expect(library.localBookVisible(book.id), false);
      expect((await books.original(book.id)).bytes, input().bytes);
      expect(
        await books.chapterContent(book.id, book.chapters.first),
        contains('风穿过窗边'),
      );
      final reloaded = await LibraryState.load();
      addTearDown(reloaded.dispose);
      expect(reloaded.localBookVisible(book.id), false);
      final backup = await library.createBackup();
      expect(backup.records['local_shelf_hidden'], ['${book.id}']);
      await library.setLocalBookHidden(book.id, false);
      expect(library.localBookVisible(book.id), true);
      await removeLocalBook(books: books, library: library, id: book.id);
      expect(books.contains(book.id), false);
      expect(
        await Directory('${books.directory.path}/${book.id}').exists(),
        false,
      );
      expect(await downloads.readAsString(), text);
      expect(library.positionFor(book.id)?.offset, 40);
      expect(library.bookmarksFor(book.id).single.id, mark!.id);
      expect(library.bookmarksFor(book.id).single.quote, '风穿过窗边。');
      expect(library.hiddenLocalBooks, isEmpty);
      expect(bookshelfIds(library, null), isEmpty);
    },
  );

  test(
    'series merge keeps excerpt recovery copies but displays one canonical bookmark',
    () async {
      final first = await books.import(input());
      const other = '第一章\n另一个故事开始了。';
      final second = await books.import(
        LocalBookInput(
          '原书第二卷.txt',
          Uint8List.fromList(utf8.encode(other)),
          text: other,
        ),
      );
      await library.addBookmark(
        novel: first,
        quote: '风穿过窗边。',
        position: ReadingPosition(
          chapter: 0,
          chapterId: first.chapters.first.id,
          offset: 0,
          fraction: 0,
          fontSize: 19,
          width: 390,
          updatedAt: 1,
          paragraphIndex: 0,
          textOffset: 3,
        ),
      );
      final combined = await saveLocalSeries(
        books: books,
        library: library,
        title: '完整故事',
        volumes: [
          (bookId: first.id, title: '第一卷'),
          (bookId: second.id, title: '第二卷'),
        ],
      );
      expect(library.bookmarksFor(first.id).single.quote, '风穿过窗边。');
      expect(library.bookmarksFor(combined.id).single.quote, '风穿过窗边。');
      expect(libraryBookmarks(library, books: books), hasLength(1));
      expect(
        libraryBookmarks(library, books: books).single.novelId,
        combined.id,
      );
    },
  );

  testWidgets(
    'removal presents separate choices, leaves files intact on shelf-only and supports restoration',
    (tester) async {
      late dynamic book;
      await tester.runAsync(() async {
        book = await books.import(input());
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: novelTheme(Brightness.light),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => chooseLocalBookRemoval(
                  context,
                  book: book,
                  books: books,
                  library: library,
                ),
                child: const Text('移除书籍'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('移除书籍'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('local-remove-shelf-only')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('local-remove-files')), findsOneWidget);
      await tester.tap(find.text('仅移出书架'));
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pumpAndSettle();
      expect(library.localBookVisible(book.id), false);
      expect(books.contains(book.id), true);
      await tester.pumpWidget(
        MaterialApp(
          theme: novelTheme(Brightness.light),
          home: RemovedLocalBooksPage(books: books, library: library),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('local-restore-${book.id}')));
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pumpAndSettle();
      expect(library.localBookVisible(book.id), true);
      expect(find.text('没有已移出的本地书。'), findsOneWidget);
      expect(books.contains(book.id), true);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
