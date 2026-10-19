import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/reader_panels.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/listening/controller.dart';
import 'package:wenku8_flutter/listening/models.dart';
import 'package:wenku8_flutter/listening/store.dart';
import 'package:wenku8_flutter/listening/widgets.dart';
import 'package:wenku8_flutter/pages.dart';
import 'package:wenku8_flutter/reader_content.dart';
import 'package:wenku8_flutter/reader_paged_view.dart';
import 'package:wenku8_flutter/reader_pagination.dart';
import 'package:wenku8_flutter/reader_preferences.dart';
import 'package:wenku8_flutter/reader_selection.dart';
import 'package:wenku8_flutter/reader_vertical_text.dart';
import 'support/listening_fixture.dart';

const paragraph =
    '春天的风穿过窗边，书页轻轻翻动。「回到这里吧！」她说。OPPO 2026，👨‍👩‍👧‍👦与𠮷野、e\u0301都不能被拆开。';
final paragraphs = [
  for (var i = 0; i < 12; i++) '第${i + 1}段。${List.filled(6, paragraph).join()}',
];
final book = Novel(
  id: 10345,
  title: '阅读模式',
  author: '',
  genre: '',
  summary: '',
  colors: const [Colors.black, Colors.grey],
  chapters: [
    NovelChapter('第一章 春风', paragraphs.join('\n\n'), id: 1001),
    NovelChapter('第二章 夏夜', paragraphs.reversed.join('\n\n'), id: 1002),
  ],
);

Future<ReaderPagination> layout(
  ReaderMode mode, {
  Size size = const Size(310, 480),
  double scale = 1,
  bool indent = true,
}) async => (await paginateReader(
  content: ReaderContent(paragraphs),
  size: size,
  style: const TextStyle(fontSize: 19, height: 1.72),
  preferences: ReaderPreferences(mode: mode, indent: indent),
  scaler: TextScaler.linear(scale),
  current: () => true,
))!;

Future<LibraryState> library(ReaderMode mode) async {
  SharedPreferences.setMockInitialValues({
    'readerChromeVisible': true,
    'readerChromeHintSeen': true,
    'reduceMotion': true,
  });
  final state = await LibraryState.load();
  await state.setReaderPreferences(ReaderPreferences(mode: mode));
  return state;
}

Widget app(LibraryState state) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: novelTheme(Brightness.light),
  home: ReaderPage(
    novel: book,
    state: state,
    repository: const DemoNovelRepository(),
    initialChapter: 0,
  ),
);
Finder content() => find.byKey(const ValueKey('reader-content-tap'));

Future<void> settleReader(WidgetTester tester) async {
  await tester.pumpAndSettle(const Duration(milliseconds: 16));
  for (var i = 0; i < 100; i++) {
    if (find.byType(ReaderPagedView).evaluate().isEmpty) break;
    await tester.pump(const Duration(milliseconds: 16));
    final paged = find.byType(ReaderPagedView);
    if (paged.evaluate().isNotEmpty &&
        tester.widget<ReaderPagedView>(paged).controller.ready) {
      break;
    }
  }
  await tester.pumpAndSettle(const Duration(milliseconds: 16));
}

Future<void> listeningIo(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 16));
  }
  await settleReader(tester);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final mode in [ReaderMode.paged, ReaderMode.vertical]) {
    test(
      '$mode viewport reflow inserts an exact page break without losing text',
      () async {
        final before = await layout(mode);
        for (final anchor in [
          const ReaderTextAnchor(1, 0),
          before.pages[2].anchor,
        ]) {
          for (final height in [360.0, 620.0]) {
            final after = (await paginateReader(
              content: ReaderContent(paragraphs),
              size: Size(310, height),
              style: const TextStyle(fontSize: 19, height: 1.72),
              preferences: ReaderPreferences(mode: mode, indent: true),
              scaler: TextScaler.noScaling,
              current: () => true,
              pageBreak: anchor,
            ))!;
            final first = after.pages[after.pageFor(anchor)].anchor;
            expect(
              (first.paragraph, first.offset),
              (anchor.paragraph, anchor.offset),
            );
            for (var p = 0; p < paragraphs.length; p++) {
              final fragments = after.pages
                  .expand((page) => page.fragments)
                  .where((f) => f.paragraph == p)
                  .toList();
              expect(fragments.map((f) => f.text).join(), paragraphs[p]);
              for (var i = 1; i < fragments.length; i++) {
                expect(fragments[i].start, fragments[i - 1].end);
              }
            }
          }
        }
      },
    );
    test(
      '$mode pagination covers original UTF-16 text without gaps or overlaps',
      () async {
        final pages = await layout(mode);
        expect(pages.pages.length, greaterThan(2));
        for (var p = 0; p < paragraphs.length; p++) {
          final fragments = pages.pages
              .expand((page) => page.fragments)
              .where((f) => f.paragraph == p)
              .toList();
          expect(fragments.map((f) => f.text).join(), paragraphs[p]);
          expect(fragments.first.start, 0);
          expect(fragments.last.end, paragraphs[p].length);
          for (var i = 1; i < fragments.length; i++) {
            expect(fragments[i].start, fragments[i - 1].end);
          }
        }
        for (final page in pages.pages) {
          for (final f in page.fragments) {
            expect(f.rect.left, greaterThanOrEqualTo(-.1));
            expect(f.rect.top, greaterThanOrEqualTo(0));
            expect(f.rect.right, lessThanOrEqualTo(pages.size.width + .1));
            expect(f.rect.bottom, lessThanOrEqualTo(pages.size.height + .1));
          }
        }
      },
    );
    test(
      '$mode pagination reflows at large type and resolves text anchors',
      () async {
        final small = await layout(mode, size: const Size(245, 400));
        final large = await layout(
          mode,
          size: const Size(245, 400),
          scale: 1.8,
        );
        expect(large.pages.length, greaterThan(small.pages.length));
        final anchor = small.pages[2].anchor;
        final page = large.pages[large.pageFor(anchor)];
        expect(
          page.fragments.any(
            (f) =>
                f.paragraph == anchor.paragraph &&
                f.start <= anchor.offset &&
                anchor.offset < f.end,
          ),
          isTrue,
        );
      },
    );
  }
  test(
    'vertical glyphs preserve complete graphemes and advance right-to-left',
    () async {
      final pages = await layout(ReaderMode.vertical);
      final glyphs = pages.pages.expand((page) => page.glyphs).toList();
      expect(glyphs.where((g) => g.text == '👨‍👩‍👧‍👦'), isNotEmpty);
      expect(glyphs.where((g) => g.text == '𠮷'), isNotEmpty);
      expect(glyphs.where((g) => g.text == 'e\u0301'), isNotEmpty);
      final first = pages.pages.first;
      expect(
        first.glyphs.first.rect.center.dx,
        greaterThan(first.glyphs.last.rect.center.dx),
      );
      for (final g in glyphs) {
        expect(g.sourceEnd - g.sourceStart, g.text.length);
      }
    },
  );
  test('cancelled layout cannot publish a partial chapter', () async {
    expect(
      await paginateReader(
        content: ReaderContent(paragraphs),
        size: const Size(300, 500),
        style: const TextStyle(fontSize: 19),
        preferences: const ReaderPreferences(mode: ReaderMode.paged),
        scaler: TextScaler.noScaling,
        current: () => false,
      ),
      isNull,
    );
  });
  test(
    'new modes and text anchors round trip through backup; old scroll layout keys remain stable',
    () async {
      final state = await library(ReaderMode.vertical);
      addTearDown(state.dispose);
      await state.savePosition(
        novel: book,
        chapter: 0,
        offset: .4,
        maximum: 1,
        width: 390,
        paragraphIndex: 3,
        textOffset: 127,
        paragraphFraction: .25,
      );
      final backup = await state.createBackup();
      final next = await library(ReaderMode.scroll);
      addTearDown(next.dispose);
      await next.restoreBackup(backup, importPreferences: true);
      expect(next.readerPreferences.mode, ReaderMode.vertical);
      expect(next.positionFor(book.id)!.textOffset, 127);
      expect(
        const ReaderPreferences(margin: 30).layoutKey,
        '30.0:12.0:false:false',
      );
      expect(ReaderPreferences.fromJson({}).mode, ReaderMode.scroll);
    },
  );
  for (final mode in ReaderMode.values) {
    testWidgets('$mode reader loads and keeps native selection available', (
      tester,
    ) async {
      final state = await library(mode);
      addTearDown(state.dispose);
      await tester.pumpWidget(app(state));
      await settleReader(tester);
      expect(find.byType(ReaderSelection), findsOneWidget);
      expect(tester.takeException(), isNull);
      if (mode.paginated) {
        expect(find.byType(PageView), findsOneWidget);
        expect(find.byKey(const ValueKey('reader-page-count')), findsOneWidget);
        final pager = tester
            .widget<ReaderPagedView>(find.byType(ReaderPagedView))
            .controller;
        expect(pager.ready, isTrue);
        expect(pager.pageCount, greaterThan(1));
        pager.pageBy(1);
        await settleReader(tester);
        expect(pager.page, pager.pagesPerSpread);
      } else {
        expect(find.byKey(const ValueKey('reader-scroll')), findsOneWidget);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await settleReader(tester);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets(
    'switching scroll, horizontal, vertical and typography retains the text anchor',
    (tester) async {
      final state = await library(ReaderMode.paged);
      addTearDown(state.dispose);
      await tester.pumpWidget(app(state));
      await settleReader(tester);
      ReaderPagedController controller() => tester
          .widget<ReaderPagedView>(find.byType(ReaderPagedView))
          .controller;
      controller().pageBy(1);
      await settleReader(tester);
      final before = controller().anchor!;
      await state.setReaderPreferences(
        state.readerPreferences.copyWith(mode: ReaderMode.vertical),
      );
      await settleReader(tester);
      final vertical = controller();
      expect(vertical.ready, isTrue);
      expect(vertical.anchor!.paragraph, lessThanOrEqualTo(before.paragraph));
      await state.setTypography(fontSize: 25);
      await settleReader(tester);
      expect(tester.takeException(), isNull);
      await state.setReaderPreferences(
        state.readerPreferences.copyWith(mode: ReaderMode.scroll),
      );
      await settleReader(tester);
      expect(find.byType(PageView), findsNothing);
      expect(find.byKey(const ValueKey('reader-scroll')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'vertical selection copies the complete emoji grapheme using the glass toolbar',
    (tester) async {
      final state = await library(ReaderMode.vertical);
      addTearDown(state.dispose);
      await tester.pumpWidget(app(state));
      await settleReader(tester);
      final render = tester.renderObject<RenderReaderVerticalText>(
        find.byType(ReaderVerticalText).first,
      );
      final page = tester
          .widget<ReaderVerticalText>(find.byType(ReaderVerticalText).first)
          .page;
      final glyph = page.glyphs.firstWhere((g) => g.text == '👨‍👩‍👧‍👦');
      final position = render.localToGlobal(glyph.rect.center);
      await tester.longPressAt(position);
      await settleReader(tester);
      expect(
        render.getSelectedContent()?.plainText,
        contains('OPPO 2026，👨‍👩‍👧‍👦'),
      );
      // Initial long press now selects the sentence. The normal handle-event
      // path still permits an exact grapheme without splitting its ZWJ family.
      final handles = find.byWidgetPredicate(
        (w) =>
            w is RawGestureDetector &&
            w.gestures.containsKey(PanGestureRecognizer),
      );
      expect(handles, findsNWidgets(2));
      Future<void> dragHandle(Finder handle, Offset delta) async {
        final factory =
            tester
                    .widget<RawGestureDetector>(handle)
                    .gestures[PanGestureRecognizer]!
                as GestureRecognizerFactoryWithHandlers<PanGestureRecognizer>;
        final drag = factory.constructor();
        factory.initializer(drag);
        // Exercise the SDK handle's accepted-pan callbacks without adding
        // pointer slop to the exact grapheme boundary under test.
        final at = tester.getCenter(handle);
        drag.onStart!(DragStartDetails(globalPosition: at));
        drag.onUpdate!(
          DragUpdateDetails(globalPosition: at + delta, delta: delta),
        );
        drag.onEnd!(DragEndDetails());
        drag.dispose();
      }

      await dragHandle(
        handles.first,
        glyph.rect.center - render.value.startSelectionPoint!.localPosition,
      );
      await settleReader(tester);
      await dragHandle(
        handles.last,
        glyph.rect.center - render.value.endSelectionPoint!.localPosition,
      );
      await settleReader(tester);
      expect(render.getSelectedContent()?.plainText, '👨‍👩‍👧‍👦');
      expect(
        find.byKey(const ValueKey('reader-selection-copy')),
        findsOneWidget,
      );
      final toolbar = tester.getRect(
        find.byKey(const ValueKey('reader-selection-toolbar')),
      );
      final screenWidth =
          tester.view.physicalSize.width / tester.view.devicePixelRatio;
      expect(toolbar.left, greaterThanOrEqualTo(0));
      expect(toolbar.right, lessThanOrEqualTo(screenWidth));
      expect(
        toolbar.center.dx,
        closeTo(
          position.dx.clamp(
            toolbar.width / 2 + 8,
            screenWidth - toolbar.width / 2 - 8,
          ),
          8,
        ),
      );
      final clipboard = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard.add((call.arguments as Map)['text'] as String);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.tap(find.byKey(const ValueKey('reader-selection-copy')));
      await settleReader(tester);
      expect(clipboard, contains('👨‍👩‍👧‍👦'));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'chapter progress moves to start or end without a return-position control',
    (tester) async {
      final state = await library(ReaderMode.paged);
      addTearDown(state.dispose);
      await tester.pumpWidget(app(state));
      await settleReader(tester);
      ReaderPagedController controller() => tester
          .widget<ReaderPagedView>(find.byType(ReaderPagedView))
          .controller;
      controller().pageBy(1);
      await settleReader(tester);
      await openReaderChapterProgress(tester);
      await tester.tap(find.text('跳至章末'));
      await settleReader(tester);
      expect(controller().page, controller().pageCount - 1);
      expect(
        find.byKey(const ValueKey('reader-return-position')),
        findsNothing,
      );
      await openReaderChapterProgress(tester);
      await tester.tap(find.text('回到章首'));
      await settleReader(tester);
      expect(controller().page, 0);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'reading mode controls select real pagination and vertical columns without enabling notes',
    (tester) async {
      final state = await library(ReaderMode.scroll);
      addTearDown(state.dispose);
      await tester.pumpWidget(app(state));
      await settleReader(tester);
      await tester.tap(
        find.byWidgetPredicate(
          (w) => w is GlassIconButton && w.label == '阅读设置',
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('reader-mode-vertical')));
      await settleReader(tester);
      await tester.binding.handlePopRoute();
      await settleReader(tester);
      expect(state.readerPreferences.mode, ReaderMode.vertical);
      expect(find.byType(ReaderVerticalText), findsWidgets);
      expect(find.text('笔记'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  for (final mode in [ReaderMode.paged, ReaderMode.vertical]) {
    testWidgets(
      '$mode listening follows the spoken page and double tap pauses it',
      (tester) async {
        final state = await library(mode);
        final output = FakeListeningOutput();
        final listening = ListeningController(
          repository: const DemoNovelRepository(),
          audio: FakeSpeechAudio(),
          store: ListeningStore(await SharedPreferences.getInstance()),
          outputFactory: (_) async => output,
        );
        await tester.pumpWidget(
          ListeningScope(controller: listening, child: app(state)),
        );
        await settleReader(tester);
        final starting = listening.start(book, chapter: 0, paragraph: 8);
        await listeningIo(tester);
        await starting;
        final pager = tester
            .widget<ReaderPagedView>(find.byType(ReaderPagedView))
            .controller;
        expect(pager.page, greaterThan(0));
        late Offset point;
        if (mode == ReaderMode.vertical) {
          final node = find.byType(ReaderVerticalText).hitTestable().first;
          final render = tester.renderObject<RenderReaderVerticalText>(node);
          final page = tester.widget<ReaderVerticalText>(node).page;
          final glyph = page.glyphs.firstWhere((g) => g.paragraph == 8);
          point = render.localToGlobal(glyph.rect.center);
        } else {
          point = tester.getCenter(
            find.byKey(const ValueKey('paragraph-8')).hitTestable().first,
          );
        }
        await tester.tapAt(point);
        await tester.pump(const Duration(milliseconds: 60));
        await tester.tapAt(point);
        await listeningIo(tester);
        expect(listening.snapshot.value.phase, ListeningPhase.paused);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        final closing = listening.dispose();
        await listeningIo(tester);
        await closing;
        state.dispose();
        expect(tester.takeException(), isNull);
      },
    );
    testWidgets(
      '$mode respects the tap-paging switch instead of forcing touch zones on',
      (tester) async {
        final state = await library(mode);
        addTearDown(state.dispose);
        await tester.pumpWidget(app(state));
        await settleReader(tester);
        ReaderPagedController controller() => tester
            .widget<ReaderPagedView>(find.byType(ReaderPagedView))
            .controller;
        final size = tester.getSize(content());
        final point =
            tester.getTopLeft(content()) +
            Offset(
              size.width * (mode == ReaderMode.vertical ? .18 : .82),
              size.height * .5,
            );
        await tester.tapAt(point);
        await settleReader(tester);
        expect(controller().page, 0);
        await state.setReaderPreferences(
          state.readerPreferences.copyWith(tapPaging: true),
        );
        await settleReader(tester);
        await tester.tapAt(point);
        await settleReader(tester);
        expect(controller().page, controller().pagesPerSpread);
        expect(tester.takeException(), isNull);
      },
    );
    testWidgets(
      '$mode remains usable in compact landscape with large system text',
      (tester) async {
        tester.view.physicalSize = const Size(800, 360);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final state = await library(mode);
        addTearDown(state.dispose);
        await tester.pumpWidget(
          MaterialApp(
            theme: novelTheme(Brightness.light),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(2)),
              child: child!,
            ),
            home: ReaderPage(
              novel: book,
              state: state,
              repository: const DemoNovelRepository(),
              initialChapter: 0,
            ),
          ),
        );
        await settleReader(tester);
        final pager = tester
            .widget<ReaderPagedView>(find.byType(ReaderPagedView))
            .controller;
        expect(pager.ready, isTrue);
        expect(pager.pageBy(1), isTrue);
        await settleReader(tester);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
