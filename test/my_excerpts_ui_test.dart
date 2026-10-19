import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/bookmark_library_page.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/local_platform.dart';
import 'package:wenku8_flutter/main.dart';
import 'package:wenku8_flutter/my_page.dart';
import 'package:wenku8_flutter/illustration_placement.dart';
import 'package:wenku8_flutter/reader_illustrations.dart';
import 'package:wenku8_flutter/legacy_transport.dart';
import 'package:wenku8_flutter/pages.dart';
import 'package:wenku8_flutter/quote_card.dart';
import 'package:wenku8_flutter/reader_paged_view.dart';
import 'package:wenku8_flutter/reader_preferences.dart';
import 'package:wenku8_flutter/reader_selection.dart';
import 'package:wenku8_flutter/reader_vertical_text.dart';
import 'reader_modes_test.dart' show settleReader;
import 'support/visual_review.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await loadReviewFonts();
    await (FontLoader('SourceHanSerifCN')..addFont(
          rootBundle.load('assets/fonts/SourceHanSerifCN-Regular.otf'),
        ))
        .load();
  });
  const quote = '时间没有停在那个夏天，但我们依然记得窗边的风。';
  final book = Novel(
    id: 71234,
    title: '窗边的风',
    author: '作者',
    genre: '日常',
    summary: '',
    colors: const [Colors.grey, Colors.white],
    chapters: [
      const NovelChapter('第一章 相遇', '''A beautiful morning.

The sunlight shines through the window.

Tomorrow we will meet again.''', id: 7123401),
    ],
  );
  late LibraryState state;
  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'readerChromeVisible': true,
      'readerChromeHintSeen': true,
      'reduceMotion': true,
    });
    state = await LibraryState.load();
  });
  tearDown(() => state.dispose());

  testWidgets(
    'My separates account, excerpts, settings and about; no duplicate account entry in settings',
    (tester) async {
      tester.view.physicalSize = const Size(390, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final boundary = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: NovelApp(
            state: state,
            repository: const DemoNovelRepository(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('dock-tab-3')));
      await tester.pumpAndSettle();
      expect(find.byType(MyPage), findsOneWidget);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)),
      );
      await tester.pumpAndSettle();
      await captureReview(tester, boundary, 'my-page');
      for (final key in [
        'my-account',
        'my-bookmarks',
        'my-settings',
        'my-about',
      ]) {
        expect(find.byKey(ValueKey(key)), findsOneWidget);
      }
      await tester.tap(find.byKey(const ValueKey('my-settings')));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsPage), findsOneWidget);
      expect(find.byKey(const ValueKey('settings-account')), findsNothing);
      expect(find.byKey(const ValueKey('settings-app-update')), findsNothing);
      expect(find.byKey(const ValueKey('settings-data-entry')), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('my-bookmarks')));
      await tester.pumpAndSettle();
      expect(find.byType(BookmarkLibraryPage), findsOneWidget);
      expect(find.textContaining('长按正文'), findsOneWidget);
    },
  );

  testWidgets(
    'saved quote is searchable, shareable and opens its original source anchor',
    (tester) async {
      final mark = (await tester.runAsync(
        () => state.addBookmark(
          novel: book,
          quote: quote,
          position: ReadingPosition(
            chapter: 0,
            chapterId: book.chapters.first.id,
            offset: 0,
            fraction: 0,
            width: 390,
            fontSize: 19,
            updatedAt: 100,
            paragraphIndex: 1,
            textOffset: 4,
          ),
        ),
      ))!;
      final boundary = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: novelTheme(Brightness.light),
            home: BookmarkLibraryPage(
              state: state,
              repository: const DemoNovelRepository(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(quote), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('bookmark-search')),
        '作者',
      );
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('my-bookmark-${mark.id}')), findsOneWidget);
      await captureReview(tester, boundary, 'my-bookmarks');
      await tester.tap(find.byKey(ValueKey('bookmark-share-${mark.id}')));
      await tester.pumpAndSettle();
      expect(find.byType(QuoteCardPage), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('bookmark-read-${mark.id}')));
      await settleReader(tester);
      expect(
        tester.widget<ReaderPage>(find.byType(ReaderPage)).initialBookmark?.id,
        mark.id,
      );
      expect(find.byKey(const ValueKey('paragraph-1')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final mode in ReaderMode.values) {
    testWidgets(
      '$mode selected text saves with its exact paragraph, not the viewport start',
      (tester) async {
        await tester.runAsync(
          () => state.setReaderPreferences(
            ReaderPreferences(mode: mode, indent: false),
          ),
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: novelTheme(Brightness.light),
            home: ReaderPage(
              novel: book,
              state: state,
              repository: const DemoNovelRepository(),
              initialChapter: 0,
            ),
          ),
        );
        await settleReader(tester);
        late Offset at;
        if (mode == ReaderMode.vertical) {
          final render = tester.renderObject<RenderReaderVerticalText>(
            find.byType(ReaderVerticalText),
          );
          final glyph = tester
              .widget<ReaderVerticalText>(find.byType(ReaderVerticalText))
              .page
              .glyphs
              .firstWhere((g) => g.paragraph == 1 && g.sourceStart >= 4);
          at = render.localToGlobal(glyph.rect.center);
        } else {
          final text = find.textContaining('The sunlight', findRichText: true);
          final render = tester.renderObject<RenderParagraph>(text.first);
          final bounds = render
              .getBoxesForSelection(
                const TextSelection(baseOffset: 4, extentOffset: 12),
              )
              .first
              .toRect();
          at = render.localToGlobal(bounds.center);
        }
        await tester.longPressAt(at);
        await settleReader(tester);
        final selected = tester
            .widget<ReaderSelection>(find.byType(ReaderSelection))
            .controller
            .quote;
        expect(selected.text, isNotEmpty);
        expect(selected.text.trim(), 'The sunlight shines through the window.');
        expect(
          find.byKey(const ValueKey('reader-selection-copy')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('reader-selection-share')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('reader-selection-illustrations')),
          findsOneWidget,
        );
        expect(selected.anchor?.paragraph, 1);
        expect(selected.anchor!.offset, greaterThanOrEqualTo(0));
        await tester.tap(
          find.byKey(const ValueKey('reader-selection-bookmark')),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 60)),
        );
        await settleReader(tester);
        final mark = state.bookmarksFor(book.id).single;
        expect(mark.quote, selected.text.trim());
        expect(mark.position.paragraphIndex, 1);
        expect(mark.position.textOffset, selected.anchor!.offset);
        if (mode.paginated) {
          expect(find.byType(ReaderPagedView), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'legacy illustration anchors remain readable without exposing manual placement controls',
    (tester) async {
      final original = book.chapters.first;
      const url = 'https://pic.wenku8.cn/pictures/1/placement-ui.jpg';
      final novel = book.withChapters([
        NovelChapter(
          original.title,
          original.content,
          id: original.id,
          volumeId: 1,
          volumeTitle: '第一卷',
        ),
        const NovelChapter(
          '插图',
          '<!--image-->$url<!--image-->',
          id: 7123402,
          volumeId: 1,
          volumeTitle: '第一卷',
        ),
      ]);
      final png = (await tester.runAsync(
        () => rootBundle.load('assets/branding/app-icon.png'),
      ))!.buffer.asUint8List();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        LegacyTransport.channel,
        (call) async => call.method == 'illustration' ? png : null,
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          LegacyTransport.channel,
          null,
        );
        ReaderIllustrationCache.shared.clearMemory();
      });
      await tester.runAsync(
        () => state.putIllustration(
          novel.id,
          IllustrationPlacement.at(
            chapterId: original.id,
            chapterTitle: original.title,
            url: url,
            paragraphs: original.content.split('\n\n'),
            paragraph: 1,
          ),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: novelTheme(Brightness.light),
          home: ReaderPage(
            novel: novel,
            state: state,
            repository: const DemoNovelRepository(),
            initialChapter: 0,
          ),
        ),
      );
      await settleReader(tester);
      await tester.tap(
        find
            .descendant(
              of: find.byWidgetPredicate(
                (w) => w is GlassIconButton && w.label == '阅读设置',
              ),
              matching: find.byType(InkWell),
            )
            .first,
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('reader-illustration-layout')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('reader-selection-illustration')),
        findsNothing,
      );
      await tester.binding.handlePopRoute();
      await settleReader(tester);
      expect(state.illustrationsFor(novel.id).single.chapterId, original.id);
      expect(
        state
            .illustrationsFor(novel.id)
            .single
            .resolve(original.content.split('\n\n')),
        1,
      );
      expect(
        find.byWidgetPredicate((w) => w is ReaderIllustration && w.url == url),
        findsOneWidget,
      );
      final following = find.textContaining(
        'Tomorrow we will meet',
        findRichText: true,
      );
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('paragraph-2')),
        350,
        scrollable: find
            .descendant(
              of: find.byKey(const ValueKey('reader-scroll')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(following, findsWidgets);
      expect(find.byKey(const ValueKey('paragraph-2')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test(
    'PNG cards keep full long excerpts, correct pixel sizes and the existing icon-only watermark',
    () async {
      final bytes = await rootBundle.load('assets/branding/app-icon.png');
      final codec = await ui.instantiateImageCodec(
        bytes.buffer.asUint8List(),
        targetWidth: 96,
      );
      final icon = (await codec.getNextFrame()).image;
      codec.dispose();
      addTearDown(icon.dispose);
      for (final style in QuoteCardStyle.values) {
        final data = QuoteCardData(
          text: List.filled(25, quote).join('\n'),
          book: book.title,
          author: book.author,
          chapter: book.chapters.first.title,
        );
        final cards = QuoteCardLayout.prepare(data, style);
        expect(cards.length, greaterThan(1));
        expect(
          cards
              .map((card) => card.body.text!.toPlainText())
              .join()
              .replaceAll(RegExp(r'\s+'), ''),
          data.text.replaceAll(RegExp(r'\s+'), ''),
        );
        final png = await cards.first.png(
          icon: icon,
          page: 0,
          pages: cards.length,
        );
        final header = ByteData.sublistView(png);
        expect(header.getUint32(16), 1080);
        expect(
          header.getUint32(20),
          (cards.first.height * 1080 / QuoteCardLayout.width).ceil(),
        );
        const output = String.fromEnvironment('REVIEW_ARTIFACTS');
        if (output.isNotEmpty) {
          await Directory(output).create(recursive: true);
          await File('$output/quote-card-${style.name}.png').writeAsBytes(png);
        }
        for (final card in cards) {
          card.dispose();
        }
      }
    },
  );

  testWidgets(
    'quote preview exports PNG via the explicit native save/share actions',
    (tester) async {
      final calls = <String>[];
      Completer<void>? exported;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        LocalPlatform.channel,
        (call) async {
          calls.add(call.method);
          expect((call.arguments as Map)['bytes'], isA<Uint8List>());
          exported?.complete();
          return call.method == 'exportImage' ? true : null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          LocalPlatform.channel,
          null,
        ),
      );
      final boundary = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: novelTheme(Brightness.light),
            home: QuoteCardPage(
              data: QuoteCardData(
                text: quote,
                book: book.title,
                author: book.author,
                chapter: '第一章 相遇',
              ),
            ),
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 80)),
      );
      await tester.pumpAndSettle();
      await captureReview(tester, boundary, 'quote-share-preview');
      for (final key in ['quote-save-image', 'quote-share-image']) {
        final button = tester.widget<GlassTextButton>(
          find.byKey(ValueKey(key)),
        );
        await tester.runAsync(() async {
          exported = Completer<void>();
          button.onPressed!();
          await exported!.future;
        });
        await tester.pumpAndSettle();
      }
      expect(calls, ['exportImage', 'shareImage']);
      expect(tester.takeException(), isNull);
    },
  );
}
