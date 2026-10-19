import 'dart:async';

import 'package:flutter/material.dart';
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
import 'package:wenku8_flutter/reader_chrome.dart';
import 'package:wenku8_flutter/reader_paged_view.dart';
import 'package:wenku8_flutter/reader_preferences.dart';

import 'support/listening_fixture.dart';
import 'support/visual_review.dart';

Finder control(String key) => find
    .descendant(of: find.byKey(ValueKey(key)), matching: find.byType(InkWell))
    .first;

class _NoOfflineSpeechAudio extends FakeSpeechAudio {
  @override
  Future<List<SpeechVoice>> offlineVoices() async => const [];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadReviewFonts);
  late ListeningController controller;
  late LibraryState library;
  late FakeListeningOutput output;
  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'readerChromeVisible': true,
      'readerChromeHintSeen': true,
      'reduceMotion': true,
    });
    library = await LibraryState.load();
    output = FakeListeningOutput();
    controller = ListeningController(
      repository: const DemoNovelRepository(),
      audio: FakeSpeechAudio(),
      store: ListeningStore(await SharedPreferences.getInstance()),
      outputFactory: (_) async => output,
    );
  });
  tearDown(() {
    library.dispose();
  });
  Future<void> disposeFixture(WidgetTester tester) async {
    final closing = controller.dispose();
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
    await closing;
  }

  Future<void> io(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pumpAndSettle();
  }

  Future<void> flushIo(WidgetTester tester) async {
    // Drain storage/commands without advancing the animation clock or settling
    // the follow motion that the test needs to inspect between actual frames.
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump();
    }
  }

  testWidgets(
    'clip handoffs retain preference controls and unaffected paragraph planes',
    (tester) async {
      final book = demoNovels.first;
      const segments = [
        SpeechSegment(0, 0, 4, '第一句。'),
        SpeechSegment(0, 4, 8, '第二句。'),
        SpeechSegment(1, 0, 4, '下一段。'),
      ];
      void state(int segment, ListeningPhase phase) {
        controller.snapshot.value = ListeningSnapshot(
          novel: book,
          chapter: 0,
          segments: segments,
          segment: segment,
          phase: phase,
          playRequested: phase != ListeningPhase.paused,
        );
      }

      state(0, ListeningPhase.playing);
      await tester.pumpWidget(
        MaterialApp(
          theme: novelTheme(Brightness.light),
          home: Scaffold(
            body: Column(
              children: [
                for (var paragraph = 0; paragraph < 2; paragraph++)
                  ListeningParagraphHighlight(
                    controller: controller,
                    novelId: book.id,
                    chapter: 0,
                    paragraph: paragraph,
                    child: Text('段落 $paragraph'),
                  ),
                Expanded(
                  child: ListeningPanel(
                    controller: controller,
                    novel: book,
                    chapter: 0,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      CustomPainter? plane(int paragraph) => tester
          .widget<CustomPaint>(
            find.byKey(ValueKey('listening-highlight-$paragraph')),
          )
          .painter;
      final current = plane(0), other = plane(1);
      final slider = tester.widget<AppGlassSlider>(
        find.byKey(const ValueKey('listening-speed')),
      );
      expect(slider.min, .5);
      expect(slider.max, 3);
      expect(slider.divisions, 50);
      state(1, ListeningPhase.preparing);
      await tester.pump();
      state(1, ListeningPhase.playing);
      await tester.pump();
      expect(identical(plane(0), current), true);
      expect(identical(plane(1), other), true);
      expect(
        identical(
          tester.widget<AppGlassSlider>(
            find.byKey(const ValueKey('listening-speed')),
          ),
          slider,
        ),
        true,
      );
      state(1, ListeningPhase.paused);
      await tester.pump();
      expect(identical(plane(1), other), true);
      expect(
        find.byWidgetPredicate(
          (widget) => widget is Semantics && widget.properties.hint == '双击继续朗读',
        ),
        findsOneWidget,
      );
      state(2, ListeningPhase.playing);
      await tester.pump();
      expect(identical(plane(0), current), false);
      expect(identical(plane(1), other), false);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await disposeFixture(tester);
    },
  );

  testWidgets(
    'chapter progress does not reset or move the panel at a clip boundary',
    (tester) async {
      tester.view.physicalSize = const Size(412, 915);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final book = demoNovels.first.withChapters([
        const NovelChapter(
          '连续听书',
          '轻柔的光穿过书页。\n\n很短。\n\n这一段文字稍长一些，也应保持相同的控件位置。',
        ),
      ]);
      await tester.runAsync(() => controller.start(book, chapter: 0));
      final boundary = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: novelTheme(Brightness.light),
          home: RepaintBoundary(
            key: boundary,
            child: Scaffold(
              body: SafeArea(
                child: ListeningPanel(
                  controller: controller,
                  novel: book,
                  chapter: 0,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final slider = find.byKey(const ValueKey('listening-position'));
      await tester.ensureVisible(slider);
      output.positionEvents.add(const Duration(seconds: 30));
      await tester.pumpAndSettle();
      final value = tester.widget<AppGlassSlider>(slider).value;
      final y = tester.getCenter(slider).dy;
      await captureReview(tester, boundary, 'listening-chapter-progress');
      output.complete();
      await io(tester);
      expect(
        tester.widget<AppGlassSlider>(slider).value,
        closeTo(value, .00001),
      );
      expect(tester.getCenter(slider).dy, closeTo(y, .5));
      expect(find.text('本段进度'), findsNothing);
      expect(find.text('本章进度'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await disposeFixture(tester);
    },
  );

  ScrollPosition articlePosition(WidgetTester tester) => tester
      .state<ScrollableState>(
        find
            .descendant(
              of: find.byKey(const ValueKey('reader-scroll')),
              matching: find.byType(Scrollable),
            )
            .first,
      )
      .position;
  Future<Novel> followReader(
    WidgetTester tester, {
    bool follow = true,
    bool longParagraph = false,
    GlobalKey? captureKey,
  }) async {
    await tester.runAsync(() => library.setReduceMotion(false));
    final book = demoNovels.first.withChapters([
      NovelChapter(
        '平滑跟读',
        longParagraph
            ? '温柔的光沿着书页缓缓移动，读到下一句时继续向前。' * 150
            : List.generate(
                70,
                (i) => '第 $i 段。${'清晨的光沿着书架缓缓流动。' * 8}',
              ).join('\n\n'),
      ),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        theme: novelTheme(Brightness.light),
        builder: (context, child) =>
            ListeningScope(controller: controller, child: child!),
        home: RepaintBoundary(
          key: captureKey,
          child: ReaderPage(
            novel: book,
            state: library,
            repository: const DemoNovelRepository(),
            initialChapter: 0,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final setting = controller.setFollow(follow);
    await flushIo(tester);
    await setting;
    return book;
  }

  Future<void> doubleTap(WidgetTester tester, Finder paragraph) async {
    await tester.tap(paragraph);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tap(paragraph);
    await io(tester);
  }

  Future<Novel> reader(WidgetTester tester) async {
    final book = demoNovels.first.withChapters(const [
      NovelChapter('手势章节', '第一段可以朗读。\n\n第二段也可以朗读。\n\n第三段继续朗读。'),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        theme: novelTheme(Brightness.light),
        builder: (context, child) =>
            ListeningScope(controller: controller, child: child!),
        home: ReaderPage(
          novel: book,
          state: library,
          repository: const DemoNovelRepository(),
          initialChapter: 0,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final setting = controller.setFollow(false);
    await io(tester);
    await setting;
    return book;
  }

  double chrome(WidgetTester tester) => tester
      .widget<ReaderChromeLayer>(
        find.byKey(const ValueKey('reader-chrome-header'), skipOffstage: false),
      )
      .animation
      .value;

  testWidgets(
    'real reader follows the next paragraph with visible intermediate motion, not a jump',
    (tester) async {
      final book = await followReader(tester);
      final starting = controller.start(book, chapter: 0, paragraph: 8);
      await flushIo(tester);
      await starting;
      await tester.pumpAndSettle();
      final before = articlePosition(tester).pixels;
      output.complete();
      await flushIo(tester);
      expect(controller.snapshot.value.current!.paragraph, 9);
      expect(articlePosition(tester).pixels, closeTo(before, 1));
      await tester.pump(const Duration(milliseconds: 120));
      final intermediate = articlePosition(tester).pixels;
      expect(intermediate, greaterThan(before));
      await tester.pumpAndSettle();
      expect(articlePosition(tester).pixels, greaterThan(intermediate));
      // Progress remains isolated: it neither restarts the landing nor rebuilds
      // the original reader Text object after the paragraph is settled.
      final text = tester.widget(find.byKey(const ValueKey('paragraph-9')));
      final settled = articlePosition(tester).pixels;
      for (var i = 1; i <= 20; i++) {
        output.positionEvents.add(Duration(milliseconds: i * 250));
      }
      await tester.pump(const Duration(seconds: 1));
      expect(articlePosition(tester).pixels, settled);
      expect(
        tester.widget(find.byKey(const ValueKey('paragraph-9'))),
        same(text),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await disposeFixture(tester);
    },
  );
  testWidgets(
    'real reader follows a new spoken fragment inside the same long paragraph',
    (tester) async {
      final book = await followReader(tester, longParagraph: true);
      final starting = controller.start(book, chapter: 0);
      await flushIo(tester);
      await starting;
      await tester.pumpAndSettle();
      final before = articlePosition(tester).pixels;
      output.complete();
      await flushIo(tester);
      expect(controller.snapshot.value.current!.paragraph, 0);
      expect(controller.snapshot.value.current!.start, greaterThan(0));
      await tester.pump(const Duration(milliseconds: 120));
      final intermediate = articlePosition(tester).pixels;
      expect(intermediate, greaterThan(before));
      await tester.pumpAndSettle();
      expect(articlePosition(tester).pixels, greaterThan(intermediate));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await disposeFixture(tester);
    },
  );
  testWidgets(
    'an explicit paragraph double tap soft-lands once without enabling disabled follow',
    (tester) async {
      final book = await followReader(tester, follow: false);
      final starting = controller.start(book, chapter: 0);
      await flushIo(tester);
      await starting;
      final position = articlePosition(tester);
      position.jumpTo(1000);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('paragraph-8')));
      await tester.pumpAndSettle();
      final before = position.pixels;
      await tester.tap(find.byKey(const ValueKey('paragraph-8')));
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tap(find.byKey(const ValueKey('paragraph-8')));
      await flushIo(tester);
      expect(controller.snapshot.value.current!.paragraph, 8);
      expect(controller.snapshot.value.follow, false);
      expect(position.pixels, closeTo(before, 1));
      await tester.pump(const Duration(milliseconds: 120));
      final intermediate = position.pixels;
      expect((intermediate - before).abs(), greaterThan(0));
      await tester.pumpAndSettle();
      expect((position.pixels - intermediate).abs(), greaterThan(0));
      final after = position.pixels;
      output.complete();
      await flushIo(tester);
      await tester.pump(const Duration(seconds: 1));
      expect(controller.snapshot.value.follow, false);
      expect(position.pixels, after);
      await tester.pumpWidget(const SizedBox.shrink());
      await disposeFixture(tester);
    },
  );
  testWidgets(
    'manual dragging interrupts follow immediately and later audio does not pull it back',
    (tester) async {
      final book = await followReader(tester);
      final starting = controller.start(book, chapter: 0);
      await flushIo(tester);
      await starting;
      await tester.pumpAndSettle();
      final jumping = controller.paragraphDoubleTap(
        novelId: 1,
        chapter: 0,
        paragraph: 12,
      );
      await flushIo(tester);
      await jumping;
      await tester.pump(const Duration(milliseconds: 120));
      final before = articlePosition(tester).pixels;
      await tester.fling(
        find.byKey(const ValueKey('reader-scroll')),
        const Offset(0, -240),
        1000,
      );
      await flushIo(tester);
      expect(controller.snapshot.value.follow, false);
      await tester.pump(const Duration(milliseconds: 100));
      expect(articlePosition(tester).pixels, greaterThan(before));
      await tester.pumpAndSettle();
      final manual = articlePosition(tester).pixels;
      output.complete();
      await flushIo(tester);
      await tester.pump(const Duration(seconds: 1));
      expect(articlePosition(tester).pixels, manual);
      expect(find.byType(ReaderEdgeBlur), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await disposeFixture(tester);
    },
  );
  testWidgets(
    'floating follow action lands smoothly, survives hidden chrome and never restarts audio',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final capture = GlobalKey();
      final book = await followReader(
        tester,
        follow: false,
        captureKey: capture,
      );
      final starting = controller.start(book, chapter: 0, paragraph: 12);
      await flushIo(tester);
      await starting;
      await tester.pumpAndSettle();
      final button = find.byKey(const ValueKey('reader-enable-follow'));
      expect(button, findsOneWidget);
      final mainDock = tester.getRect(
        find.byKey(const ValueKey('reader-liquid-dock')),
      );
      expect(tester.getRect(button).bottom, lessThan(mainDock.top));
      await captureReview(tester, capture, 'reader-follow-visible-chrome');
      final plays = output.plays;
      final before = articlePosition(tester).pixels;
      await tester.tap(control('reader-enable-follow'));
      await flushIo(tester);
      expect(controller.snapshot.value.follow, true);
      await tester.pump(const Duration(milliseconds: 120));
      final middle = articlePosition(tester).pixels;
      expect(middle, greaterThan(before));
      await tester.pumpAndSettle();
      expect(articlePosition(tester).pixels, greaterThan(middle));
      expect(button, findsNothing);
      expect(output.plays, plays);

      await tester.drag(
        find.byKey(const ValueKey('reader-scroll')),
        const Offset(0, -180),
      );
      await flushIo(tester);
      await tester.pumpAndSettle();
      expect(controller.snapshot.value.follow, false);
      expect(button, findsOneWidget);
      await tester.tapAt(const Offset(195, 230));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(chrome(tester), 0);
      expect(button, findsOneWidget);
      expect(tester.getRect(button).bottom, greaterThan(mainDock.bottom));
      await captureReview(tester, capture, 'reader-follow-hidden-chrome');
      await controller.stop();
      await tester.pumpAndSettle();
      expect(button, findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await disposeFixture(tester);
    },
  );
  for (final mode in [ReaderMode.paged, ReaderMode.vertical]) {
    testWidgets(
      'floating follow returns to the spoken fragment in ${mode.name}',
      (tester) async {
        await tester.runAsync(
          () => library.setReaderPreferences(ReaderPreferences(mode: mode)),
        );
        final book = await followReader(tester, follow: false);
        final starting = controller.start(book, chapter: 0, paragraph: 12);
        await flushIo(tester);
        await starting;
        await tester.pumpAndSettle();
        final pages = tester
            .widget<ReaderPagedView>(find.byType(ReaderPagedView))
            .controller;
        expect(pages.ready, true);
        expect(pages.page, 0);
        await tester.tap(control('reader-enable-follow'));
        await flushIo(tester);
        await tester.pumpAndSettle();
        expect(controller.snapshot.value.follow, true);
        expect(pages.page, greaterThan(0));
        expect(
          pages.debugLeaf!.fragments.any(
            (fragment) => fragment.paragraph == 12 && fragment.start == 0,
          ),
          true,
        );
        expect(
          find.byKey(const ValueKey('reader-enable-follow')),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await disposeFixture(tester);
      },
    );
  }
  testWidgets(
    'backgrounding stops follow; returning starts a fresh smooth landing',
    (tester) async {
      addTearDown(
        () => tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        ),
      );
      final book = await followReader(tester);
      final starting = controller.start(book, chapter: 0, paragraph: 15);
      await flushIo(tester);
      await starting;
      await tester.pump(const Duration(milliseconds: 120));
      final pausedAt = articlePosition(tester).pixels;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump(const Duration(seconds: 1));
      expect(articlePosition(tester).pixels, closeTo(pausedAt, 1));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(articlePosition(tester).pixels, closeTo(pausedAt, 1));
      await tester.pump();
      // Prime the Ticker started by that post-frame callback before advancing
      // fake time; its first tick establishes its animation timestamp.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      expect(articlePosition(tester).pixels, greaterThan(pausedAt));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await disposeFixture(tester);
    },
  );

  testWidgets(
    'real reader double taps pause, resume and jump without toggling chrome',
    (tester) async {
      final book = await reader(tester);
      expect(
        find.byKey(const ValueKey('listening-paragraph-gesture-0')),
        findsNothing,
      );
      final starting = controller.start(book, chapter: 0);
      await io(tester);
      await starting;
      final seeking = controller.seek(const Duration(seconds: 7));
      await io(tester);
      await seeking;
      final before = chrome(tester), loads = output.loaded.length;
      await doubleTap(tester, find.byKey(const ValueKey('paragraph-0')));
      expect(controller.snapshot.value.phase, ListeningPhase.paused);
      expect(chrome(tester), before);
      await doubleTap(tester, find.byKey(const ValueKey('paragraph-0')));
      expect(controller.snapshot.value.phase, ListeningPhase.playing);
      expect(controller.progress.value.position.inSeconds, 7);
      expect(output.loaded.length, loads);
      expect(chrome(tester), before);
      await doubleTap(tester, find.byKey(const ValueKey('paragraph-2')));
      expect(controller.snapshot.value.current!.paragraph, 2);
      expect(output.initialPosition, Duration.zero);
      expect(controller.snapshot.value.phase, ListeningPhase.playing);
      expect(chrome(tester), before);
      // A single tap still hides controls. Double tap remains available in focus
      // mode; the hidden controls and scroll-edge blur have no active paint.
      await tester.tap(find.byKey(const ValueKey('paragraph-2')));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(chrome(tester), 0);
      await doubleTap(tester, find.byKey(const ValueKey('paragraph-2')));
      expect(controller.snapshot.value.phase, ListeningPhase.paused);
      expect(chrome(tester), 0);
      expect(find.byType(ReaderEdgeBlur), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await disposeFixture(tester);
    },
  );
  testWidgets('double tap can pause pending synthesis without late autoplay', (
    tester,
  ) async {
    final book = await reader(tester);
    final audio = controller.audio as FakeSpeechAudio, gate = Completer<void>();
    audio.gateFor = (segment) => segment.paragraph == 0 ? gate : null;
    final starting = controller.start(book, chapter: 0);
    await io(tester);
    expect(controller.snapshot.value.phase, ListeningPhase.preparing);
    await doubleTap(tester, find.byKey(const ValueKey('paragraph-0')));
    expect(controller.snapshot.value.phase, ListeningPhase.paused);
    gate.complete();
    await io(tester);
    await starting;
    expect(controller.snapshot.value.phase, ListeningPhase.paused);
    expect(output.plays, 0);
    await doubleTap(tester, find.byKey(const ValueKey('paragraph-1')));
    expect(controller.snapshot.value.current!.paragraph, 1);
    expect(output.playing, true);
    await tester.pumpWidget(const SizedBox.shrink());
    await disposeFixture(tester);
  });
  testWidgets(
    'reader failures are visible even when the listening panel is closed',
    (tester) async {
      final book = await reader(tester);
      (controller.audio as FakeSpeechAudio).fail = true;
      final starting = controller.start(book, chapter: 0);
      await io(tester);
      await starting;
      expect(controller.snapshot.value.phase, ListeningPhase.failed);
      expect(find.text('测试音源连接失败'), findsOneWidget);
      expect(find.byType(ListeningPanel), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await disposeFixture(tester);
    },
  );
  testWidgets(
    'the panel can skip a stalled phrase without waiting for synthesis',
    (tester) async {
      final audio = controller.audio as FakeSpeechAudio,
          gate = Completer<void>();
      audio.gateFor = (segment) => segment.paragraph == 0 ? gate : null;
      await tester.pumpWidget(
        MaterialApp(
          theme: novelTheme(Brightness.light),
          home: Scaffold(
            body: ListeningPanel(
              controller: controller,
              novel: demoNovels.first,
              chapter: 0,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final starting = controller.start(demoNovels.first, chapter: 0);
      await io(tester);
      await tester.tap(control('listening-skip-segment'));
      await io(tester);
      await starting;
      expect(controller.snapshot.value.current!.paragraph, 1);
      expect(controller.snapshot.value.phase, ListeningPhase.playing);
      gate.complete();
      await io(tester);
      expect(output.loaded.length, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await disposeFixture(tester);
    },
  );

  testWidgets(
    'reader opens unified listening panel; audio continues when sheet closes',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: novelTheme(Brightness.light),
          builder: (context, child) =>
              ListeningScope(controller: controller, child: child!),
          home: ReaderPage(
            novel: demoNovels.first,
            state: library,
            repository: const DemoNovelRepository(),
            initialChapter: 0,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await openReaderPanel(tester, tab: '听书');
      expect(find.text('听书'), findsOneWidget);
      await tester.tap(control('listening-play-pause'));
      await tester.pumpAndSettle();
      for (var i = 0; i < 8; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.pumpAndSettle();
      expect(controller.snapshot.value.phase, ListeningPhase.playing);
      final close = find.byWidgetPredicate(
        (widget) => widget is GlassIconButton && widget.label == '关闭阅读设置',
      );
      await tester.tap(
        find.descendant(of: close, matching: find.byType(InkWell)).first,
      );
      await tester.pumpAndSettle();
      expect(output.playing, true);
      expect(find.byType(ListeningParagraphHighlight), findsWidgets);
      expect(tester.takeException(), null);
      await tester.pumpWidget(const SizedBox.shrink());
      await disposeFixture(tester);
    },
  );
  testWidgets('small landscape and large text panel scrolls without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(640, 360);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: novelTheme(Brightness.dark),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2.2)),
          child: child!,
        ),
        home: Scaffold(
          body: SizedBox(
            height: 280,
            child: ListeningPanel(
              controller: controller,
              novel: demoNovels.first,
              chapter: 0,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), null);
    expect(
      find.byKey(const ValueKey('listening-panel-scroll')),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await disposeFixture(tester);
  });
  testWidgets('offline source is explicitly pending development and disabled', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: novelTheme(Brightness.light),
        home: Scaffold(
          body: ListeningPanel(
            controller: controller,
            novel: demoNovels.first,
            chapter: 0,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('系统离线 · 待开发'));
    await tester.tap(find.text('系统离线 · 待开发'));
    await tester.pumpAndSettle();
    expect(find.text('System 离线中文'), findsNothing);
    expect(find.text('系统语音设置'), findsNothing);
    expect(controller.snapshot.value.voice.source, ListeningSource.edge);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.takeException(), null);
    await tester.pumpWidget(const SizedBox.shrink());
    await disposeFixture(tester);
  });
  testWidgets(
    'tapping pending offline source does not switch or autoplay; online remains usable',
    (tester) async {
      final store = controller.store;
      await disposeFixture(tester);
      final audio = _NoOfflineSpeechAudio();
      controller = ListeningController(
        repository: const DemoNovelRepository(),
        audio: audio,
        store: store,
        outputFactory: (_) async => output,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: novelTheme(Brightness.light),
          home: Scaffold(
            body: ListeningPanel(
              controller: controller,
              novel: demoNovels.first,
              chapter: 0,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('系统离线 · 待开发'));
      await tester.tap(find.text('系统离线 · 待开发'));
      await tester.pumpAndSettle();
      expect(controller.snapshot.value.voice.source, ListeningSource.edge);
      expect(audio.prepared, isEmpty);
      expect(output.plays, 0);
      final starting = controller.start(demoNovels.first, chapter: 0);
      for (var i = 0; i < 8; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 16));
      }
      await starting;
      await tester.pumpAndSettle();
      expect(output.playing, true);
      await tester.ensureVisible(
        find.byKey(const ValueKey('listening-play-pause')),
      );
      await tester.tap(control('listening-play-pause'));
      await tester.pumpAndSettle();
      expect(output.playing, false);
      await tester.pumpWidget(const SizedBox.shrink());
      await disposeFixture(tester);
    },
  );
}
