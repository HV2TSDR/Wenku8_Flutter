import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/archive_carousel.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/pages.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('shelf view choice survives a backup roundtrip', () async {
    SharedPreferences.setMockInitialValues({});
    final state = await LibraryState.load();
    addTearDown(state.dispose);
    await state.setShelfView(layout: 'list');
    final backup = await state.createBackup();
    await state.setShelfView(layout: 'shelf');
    await state.restoreBackup(backup, importPreferences: true);
    expect(state.shelfLayout, 'list');
  });
  testWidgets(
    'shelf preview shows up to 10 books and retains the full management list',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({'reduceMotion': true});
      final state = await LibraryState.load();
      addTearDown(state.dispose);
      final books = [
        for (var i = 1; i <= 12; i++)
          Novel(
            id: 9000 + i,
            title: '书架作品 $i',
            author: '作者',
            genre: '',
            summary: '',
            colors: const [Colors.grey, Colors.black],
            chapters: const [],
          ),
      ];
      for (final book in books) {
        await state.setShelfMembership(book.id, true, novel: book);
      }
      await tester.pumpWidget(
        MaterialApp(
          theme: novelTheme(Brightness.light),
          home: Scaffold(
            body: ShelfPage(
              books: books,
              state: state,
              repository: const DemoNovelRepository(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ArchiveFileCarousel>(find.byType(ArchiveFileCarousel))
            .books
            .length,
        10,
      );
      expect(find.text('全部书籍'), findsNWidgets(2));
      final view = find.byKey(const ValueKey('shelf-view'));
      await tester.tap(view);
      await tester.pumpAndSettle();
      await tester.tap(find.text('仅列表'));
      await tester.pumpAndSettle();
      expect(find.byType(ArchiveFileCarousel), findsNothing);
      expect(state.shelfLayout, 'list');
      final restored = await LibraryState.load();
      expect(restored.shelfLayout, 'list');
      restored.dispose();
      await state.setShelfView(layout: 'shelf');
      for (final book in books.take(3)) {
        await state.setShelfMembership(book.id, false);
      }
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ArchiveFileCarousel>(find.byType(ArchiveFileCarousel))
            .books
            .length,
        9,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
