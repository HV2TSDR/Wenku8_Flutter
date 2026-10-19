import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/library_workspace.dart';
import 'package:wenku8_flutter/library_reflow.dart';
import 'package:wenku8_flutter/novel_feed_controller.dart';
import 'package:wenku8_flutter/pages.dart';
import 'package:wenku8_flutter/ui_notifiers.dart';
import 'package:wenku8_flutter/reader_content.dart';
import 'package:wenku8_flutter/reader_pagination.dart';
import 'package:wenku8_flutter/reader_preferences.dart';
import 'package:wenku8_flutter/reader_turn_motion.dart';
import 'package:wenku8_flutter/reader_vertical_text.dart';
import 'support/visual_review.dart';

class _Work {
  int builds = 0, layouts = 0, paints = 0;
}

class _Probe extends SingleChildRenderObjectWidget {
  const _Probe(this.work, {required super.child});
  final _Work work;
  @override
  RenderObject createRenderObject(BuildContext context) => _ProbeRender(work);
}

class _ProbeRender extends RenderProxyBox {
  _ProbeRender(this.work);
  final _Work work;
  @override
  void performLayout() {
    work.layouts++;
    super.performLayout();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    work.paints++;
    super.paint(context, offset);
  }
}

class _Pending extends DemoNovelRepository {
  final request = Completer<NovelPage>();
  @override
  Future<NovelPage> browse({
    NovelSort sort = NovelSort.lastUpdate,
    int page = 1,
    bool refresh = false,
  }) => request.future;
}

void main({
  bool native = false,
  Future<void> Function(WidgetTester, GlobalKey, String)? capture,
}) {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (!native) setUpAll(loadReviewFonts);
  Future<GlobalKey> mount(
    WidgetTester tester,
    Widget child, {
    double width = 1318,
    GlobalKey? boundary,
  }) async {
    tester.view.physicalSize = Size(width, 824);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
    tester.view.viewPadding = tester.view.padding;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);
    final key = boundary ?? GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: novelTheme(Brightness.light),
          home: child,
        ),
      ),
    );
    await tester.pump();
    return key;
  }

  Future<void> shot(WidgetTester tester, GlobalKey key, String name) async {
    if (capture != null) {
      await capture(tester, key, name);
    } else {
      await captureReview(tester, key, name);
    }
  }

  testWidgets(
    'wide initial skeleton and loading more both match three book columns',
    (tester) async {
      final key = await mount(
        tester,
        const Scaffold(body: LibrarySkeleton(featured: false)),
      );
      var rows = find.byType(BookRowSkeleton);
      expect(rows, findsNWidgets(9));
      expect(tester.getRect(rows.at(0)).top, tester.getRect(rows.at(2)).top);
      expect(tester.getRect(rows.at(2)).right, closeTo(1294, .01));
      await shot(tester, key, 'tablet-three-column-skeleton');
      final repository = _Pending();
      final feed = NovelFeedController(repository);
      addTearDown(feed.dispose);
      unawaited(feed.loadInitial());
      final footer = await mount(
        tester,
        Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: FeedFooter(feed: feed),
          ),
        ),
      );
      rows = find.byType(BookRowSkeleton);
      expect(rows, findsNWidgets(6));
      expect(tester.getRect(rows.at(0)).top, tester.getRect(rows.at(2)).top);
      expect(tester.getRect(rows.at(2)).right, closeTo(1294, .01));
      await shot(tester, footer, 'tablet-three-column-load-more');
      repository.request.complete(
        const NovelPage(items: [], page: 1, totalPages: 1),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'inactive retained pages skip sibling width media and layout work',
    (tester) async {
      final work = _Work();
      double? observed;
      final cachedChild = Builder(
        builder: (context) {
          work.builds++;
          observed = MediaQuery.sizeOf(context).width;
          return _Probe(work, child: const ColoredBox(color: Colors.white));
        },
      );
      Widget frame(double width, bool active) => SizedBox.expand(
        child: Center(
          child: SizedBox(
            width: width,
            height: 700,
            child: MediaQuery(
              data: MediaQueryData(size: Size(width, 700)),
              child: RetainedPane(active: active, child: cachedChild),
            ),
          ),
        ),
      );
      final key = await mount(tester, frame(1200, true));
      final builds = work.builds, layouts = work.layouts;
      await mount(tester, frame(647, false), boundary: key);
      expect(work.builds, builds);
      expect(work.layouts, layouts);
      expect(observed, 1200);
      await mount(tester, frame(647, true), boundary: key);
      expect(work.builds, builds + 1);
      expect(work.layouts, layouts + 1);
      expect(observed, 647);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'workspace transitions retain paint layers without per-frame text layout',
    (tester) async {
      final master = _Work(), detail = _Work();
      late BuildContext browseContext, detailContext;
      final key = await mount(
        tester,
        LibraryWorkspace(
          child: Builder(
            builder: (context) {
              browseContext = context;
              return _Probe(
                master,
                child: const ColoredBox(color: Color(0xfff5f3ee)),
              );
            },
          ),
        ),
      );
      expect(
        LibraryWorkspace.open(browseContext, 1, (context) {
          detailContext = context;
          return _Probe(
            detail,
            child: const ColoredBox(color: Color(0xffe9e7e1)),
          );
        }),
        true,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 32));
      await tester.pump(const Duration(milliseconds: 16));
      final animation = tester
          .widget<ArchivePlaneTransition>(find.byType(ArchivePlaneTransition))
          .animation;
      final clock =
          (animation is CurvedAnimation ? animation.parent : animation)
              as AnimationController;
      clock.stop();
      clock.value = .25;
      await tester.pump();
      final layouts = (master.layouts, detail.layouts),
          paints = (master.paints, detail.paints);
      for (final value in [.3, .4, .5, .6]) {
        clock.value = value;
        await tester.pump();
      }
      expect((master.layouts, detail.layouts), layouts);
      expect((master.paints, detail.paints), paints);
      await shot(tester, key, 'tablet-retained-detail-transition');
      clock.value = 1;
      await tester.pumpAndSettle();
      expect(LibraryWorkspace.close(detailContext), true);
      await tester.pumpAndSettle();
      expect(master.layouts, layouts.$1 + 1);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'workspace close moves the existing shelf to its centered layout before dismissal',
    (tester) async {
      late BuildContext browse, detail;
      final marker = GlobalKey();
      await mount(
        tester,
        LibraryWorkspace(
          child: Builder(
            builder: (context) {
              browse = context;
              return Center(
                child: LibraryReflowPart(
                  id: 'shelf',
                  child: SizedBox(key: marker, width: 100, height: 100),
                ),
              );
            },
          ),
        ),
      );
      Rect rect() => tester.getRect(find.byKey(marker));
      final centered = rect();
      LibraryWorkspace.open(browse, 1, (context) {
        detail = context;
        return const SizedBox.expand();
      });
      await tester.pump();
      expect(rect().center.dx, closeTo(centered.center.dx, .01));
      await tester.pump(const Duration(milliseconds: 120));
      await tester.pumpAndSettle();
      final split = rect();
      expect(split.center.dx, lessThan(centered.center.dx));
      final detailPane = find.byKey(const ValueKey('library-detail-content'));
      final detailStart = tester.getRect(detailPane);
      LibraryWorkspace.close(detail);
      await tester.pump();
      expect(rect().center.dx, closeTo(split.center.dx, .01));
      expect(tester.getRect(detailPane).left, closeTo(detailStart.left, .01));
      await tester.pump(const Duration(milliseconds: 80));
      await tester.pump(const Duration(milliseconds: 16));
      expect(
        rect().center.dx,
        inExclusiveRange(split.center.dx, centered.center.dx),
      );
      final detailMoving = tester.getRect(detailPane);
      expect(
        detailMoving.left,
        greaterThan(detailStart.left),
        reason:
            'The expanding browser pushes the full detail pane out to the right.',
      );
      expect(detailMoving.width, closeTo(detailStart.width, .001));
      expect(detailMoving.height, closeTo(detailStart.height, .001));
      await tester.pumpAndSettle();
      expect(rect().center.dx, closeTo(centered.center.dx, .01));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'wide vertical motion reuses recorded glyph columns and refreshes listening highlights',
    (tester) async {
      const style = TextStyle(
        fontSize: 19,
        height: 1.72,
        color: Color(0xff373a3d),
      );
      final content = ReaderContent(
        List.generate(
          20,
          (i) => '第${i + 1}段。${List.filled(6, '书页随着光影移动，保持文字顺序与排版。').join()}',
        ),
      );
      final pagination = (await tester.runAsync(
        () => paginateReader(
          content: content,
          size: const Size(580, 680),
          style: style,
          preferences: const ReaderPreferences(mode: ReaderMode.vertical),
          scaler: TextScaler.noScaling,
          current: () => true,
        ),
      ))!;
      final clock = AnimationController(vsync: tester, value: .8);
      final glyphs = ReaderGlyphCache();
      addTearDown(clock.dispose);
      addTearDown(glyphs.dispose);
      late StateSetter update;
      var listening = 0;
      await mount(
        tester,
        Scaffold(
          body: Center(
            child: SizedBox(
              width: 580,
              height: 680,
              child: StatefulBuilder(
                builder: (context, setState) {
                  update = setState;
                  return ReaderTurnScope(
                    animation: clock,
                    direction: 1,
                    child: ReaderVerticalText(
                      page: pagination.pages.first,
                      style: style,
                      glyphCache: glyphs,
                      listeningParagraph: listening,
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      );
      final render = tester.renderObject<RenderReaderVerticalText>(
        find.byType(ReaderVerticalText),
      );
      expect(render.debugTurnColumnCount, greaterThan(8));
      final calls = render.debugGlyphPaintCalls;
      final pictures = render.debugPictureBuilds;
      expect(calls, greaterThan(400));
      for (final progress in [.83, .87, .92]) {
        clock.value = progress;
        await tester.pump();
        expect(render.debugGlyphPaintCalls, calls);
        expect(render.debugPictureBuilds, pictures);
      }
      final old = render.debugSpeechBands;
      update(() => listening = 1);
      await tester.pump();
      expect(render.debugGlyphPaintCalls, greaterThan(calls));
      expect(render.debugSpeechBands, isNot(old));
      expect(render.debugSpeechBands, isNotEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
