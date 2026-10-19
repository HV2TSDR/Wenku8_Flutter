import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/app_typography.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/font_settings_page.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/library_backup.dart';
import 'package:wenku8_flutter/reader_appearance.dart';
import 'package:wenku8_flutter/reader_preferences.dart';
import 'package:wenku8_flutter/user_fonts.dart';
import 'package:wenku8_flutter/book_documents.dart';
import 'cloud_library_ui_test.dart' show ioSettle;
import 'support/visual_review.dart';

class _FontDocuments extends BookDocuments {
  _FontDocuments(this.path);
  final String path;
  bool released = false;
  @override
  Future<BookDocumentSelection?> pickFont() async =>
      BookDocumentSelection(name: '自己的宋体.otf', path: path);
  @override
  Future<void> releaseBooks(Iterable<BookDocumentSelection> books) async {
    released = true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadReviewFonts);
  test(
    'real OTF imports durably; app and reader fonts remain independent',
    () async {
      SharedPreferences.setMockInitialValues({});
      final root = await Directory.systemTemp.createTemp('wenku-fonts-');
      addTearDown(() => root.delete(recursive: true));
      var loads = 0;
      UserFontStore store() => UserFontStore(
        directory: root,
        loader: (_, _) async {
          loads++;
        },
      );
      final fonts = store();
      final state = LibraryState(
        await SharedPreferences.getInstance(),
        fonts: fonts,
      );
      addTearDown(state.dispose);
      await fonts.load();
      final font = await fonts.importFile(
        '自己的字体.otf',
        File('assets/fonts/SourceHanSerifCN-Regular.otf').absolute.path,
      );
      expect(loads, 1);
      await state.setAppFont(font.id);
      expect(state.readerFontId, font.id);
      await state.setReaderTypeface('system');
      var readerChanges = 0;
      state.readerSettingsChanges.addListener(() => readerChanges++);
      await state.setAppTypeface(AppTypeface.sourceHanSerif);
      expect(state.appFontId, 'sourceHanSerif');
      expect(state.readerFontId, 'system');
      expect(readerChanges, 0);
      await state.setReaderTypeface(font.id);
      expect(state.readerFontFamily, font.family);
      expect(loads, 1);
      final position = ReadingPosition(
        chapter: 0,
        chapterId: 1,
        offset: 0,
        fraction: 0,
        fontSize: 19,
        width: 390,
        updatedAt: 1,
        typeface: font.id,
      );
      final backup = await LibraryBackup.fromRecords({
        'appTypeface': 'sourceHanSerif',
        'appCustomFont': '',
        'readerTypeface': font.id,
        'reading_position_1': jsonEncode(position.toJson()),
      });
      expect(
        ReadingPosition.fromJson(
          jsonDecode(backup.records['reading_position_1'] as String),
        ).typeface,
        font.id,
      );
      final restartedFonts = store();
      await restartedFonts.load();
      final restarted = LibraryState(
        await SharedPreferences.getInstance(),
        fonts: restartedFonts,
      );
      addTearDown(restarted.dispose);
      expect(restarted.readerFontId, font.id);
      expect(restarted.fonts.fonts.single.name, '自己的字体');
      await restarted.removeUserFont(font.id);
      expect(restarted.readerTypeface, followAppFont);
      expect(restarted.readerFontId, 'sourceHanSerif');
      expect(restarted.fonts.fonts, isEmpty);
      expect(
        await File('assets/fonts/SourceHanSerifCN-Regular.otf').exists(),
        true,
      );
    },
  );
  test('corrupt and oversized fonts do not enter the catalogue', () async {
    final root = await Directory.systemTemp.createTemp('wenku-font-errors-');
    addTearDown(() => root.delete(recursive: true));
    final source = File('${root.path}/bad.ttf');
    await source.writeAsString('not a font');
    final fonts = UserFontStore(
      directory: Directory('${root.path}/fonts'),
      loader: (_, _) async {},
    );
    addTearDown(fonts.dispose);
    await expectLater(
      fonts.importFile('bad.ttf', source.path),
      throwsFormatException,
    );
    final handle = await source.open(mode: FileMode.write);
    await handle.truncate(UserFontStore.maxBytes + 1);
    await handle.close();
    await expectLater(
      fonts.importFile('large.ttf', source.path),
      throwsFormatException,
    );
    expect(fonts.fonts, isEmpty);
  });
  test(
    'reader theme uses its own family in light and dark, without changing app theme',
    () {
      final app = novelTheme(Brightness.light, fontFamily: 'AppFace');
      for (final paper in [ReaderPaper.milk, ReaderPaper.night]) {
        final reader = readerTheme(
          app,
          ReaderPreferences(paper: paper),
          fontFamily: 'ReaderFace',
        );
        expect(reader.textTheme.bodyMedium!.fontFamily, 'ReaderFace');
      }
      expect(app.textTheme.bodyMedium!.fontFamily, 'AppFace');
      expect(
        readerTheme(
          app,
          const ReaderPreferences(),
        ).textTheme.bodyMedium!.fontFamily,
        'Roboto',
      );
    },
  );
  testWidgets('font secondary page and selector fit compact large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({'reduceMotion': true});
    final state = LibraryState(await SharedPreferences.getInstance());
    addTearDown(state.dispose);
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        theme: novelTheme(Brightness.dark),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(1.4)),
          child: child!,
        ),
        home: RepaintBoundary(
          key: key,
          child: FontSettingsPage(state: state),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await captureReview(tester, key, 'font-settings-compact-dark');
    await tester.tap(find.text('阅读器字体'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reader-font-sourceHanSerif')));
    await tester.pumpAndSettle();
    expect(state.readerTypeface, 'sourceHanSerif');
    expect(state.appFontId, 'system');
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'font picker imports a real OTF and selects it independently for the reader',
    (tester) async {
      SharedPreferences.setMockInitialValues({'reduceMotion': true});
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('wenku-font-picker-'),
      ))!;
      addTearDown(() => root.delete(recursive: true));
      final fonts = UserFontStore(directory: root);
      final state = LibraryState(
        await SharedPreferences.getInstance(),
        fonts: fonts,
      );
      addTearDown(state.dispose);
      final documents = _FontDocuments(
        File('assets/fonts/SourceHanSerifCN-Regular.otf').absolute.path,
      );
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: novelTheme(Brightness.light),
          home: RepaintBoundary(
            key: key,
            child: FontSettingsPage(state: state, documents: documents),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('import-font')));
      await ioSettle(
        tester,
        until: () => fonts.fonts.isNotEmpty && documents.released,
      );
      final font = fonts.fonts.single;
      await tester.tap(find.text('阅读器字体'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('reader-font-${font.id}')));
      await tester.pumpAndSettle();
      expect(state.readerFontFamily, font.family);
      expect(state.appFontId, 'system');
      expect(await tester.runAsync(() => Directory(root.path).exists()), true);
      expect(tester.takeException(), isNull);
      await captureReview(tester, key, 'font-import-real-face');
      await tester.pumpWidget(const SizedBox());
    },
  );
}
