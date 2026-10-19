import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/listening/models.dart';
import 'package:wenku8_flutter/local_book_media.dart';
import 'package:wenku8_flutter/local_books.dart';
import 'package:wenku8_flutter/local_image_layout.dart';
import 'package:wenku8_flutter/pages.dart';
import 'package:wenku8_flutter/reader_content.dart';
import 'package:wenku8_flutter/reader_illustrations.dart';
import 'package:wenku8_flutter/reader_pagination.dart';
import 'package:wenku8_flutter/reader_preferences.dart';
import 'package:wenku8_flutter/reader_paged_view.dart';

import 'local_books_test.dart' show epubFixture;
import 'reader_modes_test.dart' show settleReader;
import 'support/visual_review.dart';

const _id = 0x60000071;
const _url = 'wenku-local://$_id/img-0.png';
const _marker = '<!--image-->$_url<!--image-->';

Future<Uint8List> _png(int width, int height) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = const Color(0xff657b94),
  );
  canvas.drawCircle(
    Offset(width / 2, height / 2),
    width / 5,
    Paint()..color = const Color(0xfff4f2eb),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return data!.buffer.asUint8List();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadReviewFonts);
  late Directory root;
  Directory? previousRoot;
  setUp(() async {
    SharedPreferences.setMockInitialValues({'reduceMotion': true});
    root = await Directory.systemTemp.createTemp('wenku-image-size-');
    previousRoot = LocalBookMedia.root;
    LocalBookMedia.root = root;
    await Directory('${root.path}/$_id').create();
    ReaderIllustrationCache.shared.clearMemory();
  });
  tearDown(() async {
    LocalBookMedia.root = previousRoot;
    ReaderIllustrationCache.shared.clearMemory();
    await root.delete(recursive: true);
  });

  test(
    'import retains CSS, inline and attribute dimensions without changing asset URLs or text order',
    () {
      final book = parseLocalBook(
        LocalBookInput(
          'notes.epub',
          epubFixture(
            overrides: {
              'OPS/a.xhtml':
                  '<html><head><link rel="stylesheet" href="style.css"/><style>#small {width:20px} img.note {height:1em !important}</style></head><body><p>前面的正文。</p><img id="small" class="note" src="images/cover.png" width="500" style="width:18px; height:60px"/><p>后面的正文。</p></body></html>',
              'OPS/style.css':
                  'img {max-width:100%} .note {width:1em; height:1em}',
            },
          ),
        ),
      );
      final paragraphs = book.bodies.first.split('\n\n');
      expect(paragraphs.length, 3);
      expect(paragraphs.first, '前面的正文。');
      expect(paragraphs.last, '后面的正文。');
      final marker = paragraphs[1],
          layout = LocalImageLayout.fromParagraph(marker);
      expect(layout.width, '18px');
      expect(layout.height, '1em');
      expect(layout.maxWidth, '100%');
      final url = readerIllustrationUrl(marker)!;
      expect(LocalBookMedia.valid(Uri.parse(url)), isTrue);
      expect(url, isNot(contains('epub-image')));
      expect(speechSegments(paragraphs).map((s) => s.paragraph).toList(), [
        0,
        2,
      ]);
      expect(
        readerIllustrationUrl('$_marker<!--epub-image:w=javascript:bad-->'),
        isNull,
      );
      expect(
        readerIllustrationUrl(
          '<!--image-->https://img.wenku8.com/a.jpg<!--image--><!--epub-image:w=1em-->',
        ),
        isNull,
      );
    },
  );

  test('natural sizing only scales down, and em follows reader typography', () {
    const layout = LocalImageLayout();
    expect(
      layout.resolve(
        natural: const Size(16, 20),
        available: const Size(340, 700),
      ),
      const Size(16, 20),
    );
    expect(
      layout.resolve(
        natural: const Size(1200, 1800),
        available: const Size(300, 500),
      ),
      const Size(300, 450),
    );
    final note = LocalImageLayout.fromProperties({
      'width': '1em',
      'height': '1em',
    });
    expect(
      note.resolve(
        natural: const Size(64, 64),
        available: const Size(340, 700),
        fontSize: 24,
      ),
      const Size(24, 24),
    );
    expect(LocalImageLayout.parseSuffix(note.suffix)!.width, '1em');
  });

  test(
    'small local icons share a leaf with text in horizontal and vertical modes; remote art stays full-page',
    () async {
      for (final mode in [ReaderMode.paged, ReaderMode.vertical]) {
        final result = (await paginateReader(
          content: const ReaderContent(['注释前的正文。', _marker, '注释后的正文。']),
          size: const Size(340, 700),
          style: const TextStyle(fontSize: 19, height: 1.7),
          preferences: ReaderPreferences(mode: mode),
          scaler: TextScaler.noScaling,
          current: () => true,
          localImageSizes: {_url: const Size(16, 16)},
        ))!;
        expect(result.pages.length, 1, reason: mode.name);
        final fragments = result.pages.single.fragments;
        final image = fragments.singleWhere((f) => f.image);
        expect(image.rect.size, const Size(16, 16));
        for (final other in fragments.where((f) => !f.image)) {
          expect(image.rect.overlaps(other.rect), isFalse);
        }
        final remote = (await paginateReader(
          content: const ReaderContent([
            '正文',
            '<!--image-->https://img.wenku8.com/image/a.jpg<!--image-->',
            '正文',
          ]),
          size: const Size(340, 700),
          style: const TextStyle(fontSize: 19),
          preferences: ReaderPreferences(mode: mode),
          scaler: TextScaler.noScaling,
          current: () => true,
        ))!;
        expect(remote.pages.length, 3);
        expect(
          remote.pages[1].fragments.single.rect.size,
          const Size(340, 700),
        );
      }
    },
  );

  test(
    'old imports recover sizing from the saved EPUB without changing text, user metadata or chapter IDs',
    () async {
      final store = LocalBookStore(root);
      addTearDown(store.dispose);
      final bytes = epubFixture(
        overrides: {
          'OPS/a.xhtml':
              '<html><head><style>.note{width:1em;height:1em}</style></head><body><p>前文。</p><img class="note" src="images/cover.png"/><p>后文。</p></body></html>',
        },
      );
      final book = await store.import(LocalBookInput('notes.epub', bytes));
      await store.updateMetadata(
        book.id,
        title: '保留自定书名',
        author: '自定作者',
        summary: '自定简介',
      );
      final recordFile = File('${root.path}/${book.id}/book.json');
      final record =
          jsonDecode(await recordFile.readAsString()) as Map<String, dynamic>;
      (record['source'] as Map).remove('imageSizing');
      await recordFile.writeAsString(jsonEncode(record));
      final chapterFile = File('${root.path}/${book.id}/c1.txt');
      final legacy = (await chapterFile.readAsString()).replaceAll(
        RegExp(r'<!--epub-image:[^<>]*-->'),
        '',
      );
      await chapterFile.writeAsString(legacy);
      final reopened = LocalBookStore(root);
      addTearDown(reopened.dispose);
      await reopened.load();
      final upgraded = await reopened.chapterContent(
        book.id,
        reopened.book(book.id)!.chapters.first,
      );
      expect(
        LocalImageLayout.fromParagraph(upgraded.split('\n\n')[1]).width,
        '1em',
      );
      expect(
        upgraded.replaceAll(RegExp(r'<!--epub-image:[^<>]*-->'), ''),
        legacy,
      );
      expect(reopened.book(book.id)!.title, '保留自定书名');
      expect(reopened.book(book.id)!.author, '自定作者');
      final updated = jsonDecode(await recordFile.readAsString()) as Map;
      expect(updated['chapters'], record['chapters']);
      expect(updated['source']['imageSizing'], 1);
      expect(
        await File('${root.path}/${book.id}/original').readAsBytes(),
        bytes,
      );
    },
  );

  test(
    'a sizing upgrade never replaces prose that differs from the saved original',
    () async {
      final store = LocalBookStore(root);
      addTearDown(store.dispose);
      final book = await store.import(
        LocalBookInput('notes.epub', epubFixture()),
      );
      final recordFile = File('${root.path}/${book.id}/book.json');
      final record =
          jsonDecode(await recordFile.readAsString()) as Map<String, dynamic>;
      (record['source'] as Map).remove('imageSizing');
      await recordFile.writeAsString(jsonEncode(record));
      final chapterFile = File('${root.path}/${book.id}/c1.txt');
      final changed = '${await chapterFile.readAsString()}\n\n额外保留的本地段落。';
      await chapterFile.writeAsString(changed);
      final reopened = LocalBookStore(root);
      addTearDown(reopened.dispose);
      await reopened.load();
      expect(
        await reopened.chapterContent(
          book.id,
          reopened.book(book.id)!.chapters.first,
        ),
        changed,
      );
      expect(await chapterFile.readAsString(), changed);
    },
  );

  testWidgets(
    'a pre-sized image frame does not apply percentage dimensions twice',
    (tester) async {
      await tester.runAsync(() async {
        await File(
          '${root.path}/$_id/img-0.png',
        ).writeAsBytes(await _png(16, 16));
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 100,
              height: 100,
              child: ReaderIllustration(
                url: _url,
                sizedFrame: true,
                localLayout: const LocalImageLayout(width: '50%'),
              ),
            ),
          ),
        ),
      );
      final image = find.byType(Image);
      for (var i = 0; i < 80 && image.evaluate().isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(tester.getSize(image), const Size(100, 100));
      expect((tester.widget<Image>(image).image as ResizeImage).width, 16);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'an unreadable 16px image has a compact retry without overlapping controls',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 16,
              height: 16,
              child: ReaderIllustration(url: _url),
            ),
          ),
        ),
      );
      final retry = find.bySemanticsLabel('图片加载失败，点按重试');
      for (var i = 0; i < 80 && retry.evaluate().isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(retry, findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final mode in ReaderMode.values) {
    testWidgets(
      '${mode.name} reader keeps a 16px local note image small and keeps surrounding text',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.runAsync(() async {
          await File(
            '${root.path}/$_id/img-0.png',
          ).writeAsBytes(await _png(16, 16));
        });
        final state = await LibraryState.load();
        addTearDown(state.dispose);
        await state.setReaderPreferences(ReaderPreferences(mode: mode));
        final key = GlobalKey();
        const book = Novel(
          id: 0x60000071,
          title: '书页中的注释',
          author: '本地作者',
          genre: '本地导入',
          summary: '',
          colors: [Colors.grey, Colors.black],
          chapters: [
            NovelChapter(
              '第一章',
              '注释前面的正文，保持原来的阅读顺序。\n\n$_marker\n\n注释后面的正文，小图标不应该撑满整页。',
            ),
          ],
        );
        await tester.pumpWidget(
          RepaintBoundary(
            key: key,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: novelTheme(Brightness.light),
              home: ReaderPage(
                novel: book,
                initialChapter: 0,
                state: state,
                repository: const DemoNovelRepository(),
              ),
            ),
          ),
        );
        await settleReader(tester);
        final note = find.byWidgetPredicate(
          (w) => w is ReaderIllustration && w.url == _url,
        );
        for (var i = 0; i < 80 && note.evaluate().isEmpty; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 5)),
          );
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(note, findsOneWidget);
        final image = find.descendant(of: note, matching: find.byType(Image));
        for (var i = 0; i < 40 && image.evaluate().isEmpty; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 5)),
          );
          await tester.pump(const Duration(milliseconds: 20));
        }
        await tester.pumpAndSettle();
        expect(image, findsOneWidget);
        final decoded = find.descendant(
          of: note,
          matching: find.byWidgetPredicate(
            (w) => w is RawImage && w.image != null,
          ),
        );
        for (var i = 0; i < 80 && decoded.evaluate().isEmpty; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 5)),
          );
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(decoded, findsOneWidget);
        await tester.pumpAndSettle();
        expect(tester.getSize(image), const Size(16, 16));
        expect((tester.widget<Image>(image).image as ResizeImage).width, 16);
        if (mode != ReaderMode.scroll) {
          final view = find.byType(ReaderPagedView);
          expect(view, findsOneWidget);
          expect(tester.widget<ReaderPagedView>(view).controller.pageCount, 1);
        }
        expect(tester.takeException(), isNull);
        await captureReview(tester, key, 'epub-note-${mode.name}');
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
