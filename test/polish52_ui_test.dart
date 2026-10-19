import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/app_interactions.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/author_works_page.dart';
import 'package:wenku8_flutter/book_identity.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/legacy_cover.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/pages.dart';
import 'package:wenku8_flutter/reader_illustrations.dart';
import 'package:wenku8_flutter/setting_menu.dart';
import 'support/book_cover_fixture.dart';
import 'support/visual_review.dart';

class _Books extends DemoNovelRepository {
  final books = List.generate(
    8,
    (i) => Novel(
      id: 800 + i,
      title: '书籍 $i',
      author: '作者 ${i ~/ 2}',
      genre: '奇幻',
      summary: '一段作品简介。',
      colors: const [Colors.grey, Colors.black],
      chapters: [
        NovelChapter(
          '第一章',
          List.filled(40, '这是阅读器里的一段正文。').join('\n\n'),
          id: 9000 + i,
        ),
      ],
    ),
  );
  @override
  Future<List<Novel>> list() async => books;
  @override
  Future<Novel?> find(int id) async =>
      books.where((b) => b.id == id).firstOrNull;
  @override
  Future<Novel> detail(Novel novel) async => (await find(novel.id))!;
  @override
  Future<NovelPage> authorPage(
    String author, {
    int page = 1,
    bool refresh = false,
  }) async => NovelPage.fromItems(
    books.where((b) => b.author == author).toList(),
    page,
  );
  @override
  Future<String> chapterContent(int id, NovelChapter chapter) async =>
      chapter.content;
}

class _Routes extends NavigatorObserver {
  final active = <Route<dynamic>>{};
  int pushes = 0;
  @override
  void didPush(Route route, Route? previousRoute) {
    active.add(route);
    pushes++;
  }

  @override
  void didPop(Route route, Route? previousRoute) => active.remove(route);
  @override
  void didRemove(Route route, Route? previousRoute) => active.remove(route);
}

class _Explore extends StatefulWidget {
  const _Explore(this.index);
  final int index;
  @override
  State<_Explore> createState() => _ExploreState();
}

class _ExploreState extends State<_Explore> {
  int counter = 0;
  void open(int index) => unawaited(
    pushNovelPage<void>(
      context,
      _Explore(index),
      reduceMotion: true,
      explorationKey: ('explore', index),
    ),
  );
  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        Text('页面 ${widget.index} · $counter'),
        TextButton(
          onPressed: () => setState(() => counter++),
          child: const Text('计数'),
        ),
        TextButton(
          onPressed: () => open(widget.index + 1),
          child: const Text('下一本'),
        ),
        TextButton(onPressed: () => open(0), child: const Text('回到起点')),
      ],
    ),
  );
}

class _NoticeHeader extends StatefulWidget {
  const _NoticeHeader();
  @override
  State<_NoticeHeader> createState() => _NoticeHeaderState();
}

class _NoticeHeaderState extends State<_NoticeHeader>
    with SingleTickerProviderStateMixin {
  late final AnimationController motion;
  VoidCallback? release;
  @override
  void initState() {
    super.initState();
    motion = AnimationController(
      vsync: this,
      value: 1,
      duration: const Duration(milliseconds: 300),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    release ??= bindNovelFeedbackHeader(context, motion);
  }

  @override
  void dispose() {
    release?.call();
    motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextButton(
            onPressed: () => showNovelFeedback(context, '一条提示'),
            child: const Text('提示'),
          ),
          TextButton(onPressed: motion.reverse, child: const Text('隐藏栏')),
        ],
      ),
    ),
  );
}

Finder action(String label) => find
    .descendant(
      of: find.byWidgetPredicate(
        (w) => w is GlassIconButton && w.label == label,
      ),
      matching: find.byType(InkWell),
    )
    .first;
Finder pressKey(String key) => find
    .descendant(of: find.byKey(ValueKey(key)), matching: find.byType(InkWell))
    .first;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadReviewFonts);
  setUp(
    () => SharedPreferences.setMockInitialValues({
      'reduceMotion': true,
      'readerChromeVisible': false,
      'readerChromeHintSeen': true,
    }),
  );
  void phone(WidgetTester tester, {double scale = 1}) {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(top: 28, bottom: 24);
    tester.view.viewPadding = tester.view.padding;
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  }

  Widget app(Widget home, GlobalKey key, {_Routes? observer}) =>
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: novelTheme(Brightness.light),
          navigatorObservers: [?observer],
          home: home,
        ),
      );
  Future<void> io(WidgetTester tester, bool Function() done) async {
    for (var n = 0; n < 120 && !done(); n++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pumpAndSettle();
  }

  testWidgets(
    'detail author list opens another book, coalesces repeated taps and retains the list',
    (tester) async {
      phone(tester);
      final state = await LibraryState.load(),
          source = _Books(),
          routes = _Routes(),
          key = GlobalKey();
      addTearDown(state.dispose);
      await tester.pumpWidget(
        app(
          Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  openDetail(context, source.books.first, state, source),
              child: const Text('打开'),
            ),
          ),
          key,
          observer: routes,
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      await tester.tap(pressKey('detail-author-works'));
      await tester.pumpAndSettle();
      final author = tester.element(find.byType(AuthorWorksPage));
      final row = find.byWidgetPredicate(
        (w) => w is NovelRow && w.novel.id == source.books[1].id,
      );
      final activate = tester.widget<NovelRow>(row).onTap;
      activate();
      activate();
      await tester.pumpAndSettle();
      expect(
        find.byWidgetPredicate(
          (w) => w is DetailPage && w.novel.id == source.books[1].id,
        ),
        findsOneWidget,
      );
      expect(routes.active.length, 4);
      await tester.tap(action('返回'));
      await tester.pumpAndSettle();
      expect(tester.element(find.byType(AuthorWorksPage)), same(author));
      expect(row, findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'related exploration keeps four live routes and reuses an existing identity',
    (tester) async {
      phone(tester);
      final routes = _Routes();
      await tester.pumpWidget(
        app(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => pushNovelPage<void>(
                context,
                const _Explore(0),
                reduceMotion: true,
                explorationKey: ('explore', 0),
              ),
              child: const Text('打开'),
            ),
          ),
          GlobalKey(),
          observer: routes,
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('计数'));
      await tester.pump();
      for (var n = 0; n < 2; n++) {
        await tester.tap(find.text('下一本'));
        await tester.pumpAndSettle();
      }
      final before = routes.pushes;
      await tester.tap(find.text('回到起点'));
      await tester.pumpAndSettle();
      expect(routes.pushes, before);
      expect(find.text('页面 0 · 1'), findsOneWidget);
      for (var n = 0; n < 10; n++) {
        await tester.tap(find.text('下一本'));
        await tester.pumpAndSettle();
      }
      expect(routes.active.length, 5);
      expect(find.byType(_Explore, skipOffstage: false), findsNWidgets(4));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'gallery fits at ninety percent on a full canvas, allows shrinking and closes on tap',
    (tester) async {
      phone(tester);
      final bytes = (await tester.runAsync(coverFixturePicture))!,
          key = GlobalKey();
      final cache = ReaderIllustrationCache(request: (_) async => bytes);
      await tester.pumpWidget(
        app(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => pushNovelPage<void>(
                context,
                ReaderIllustrationGallery(
                  urls: const ['https://pic.wenku8.com/a.png'],
                  initialUrl: 'https://pic.wenku8.com/a.png',
                  cache: cache,
                ),
                reduceMotion: true,
              ),
              child: const Text('看图'),
            ),
          ),
          key,
        ),
      );
      await tester.tap(find.text('看图'));
      await tester.pumpAndSettle();
      await io(
        tester,
        () => tester
            .widgetList<RawImage>(find.byType(RawImage))
            .any((i) => i.image != null),
      );
      final viewer = find.byType(InteractiveViewer).first;
      final rect = tester.getRect(viewer);
      expect(rect, const Rect.fromLTWH(0, 0, 390, 844));
      expect(tester.getRect(action('返回')).top, greaterThanOrEqualTo(28));
      expect(
        tester.getRect(find.byKey(const ValueKey('book-image-save'))).top,
        greaterThanOrEqualTo(28),
      );
      expect(tester.widget<InteractiveViewer>(viewer).minScale, .25);
      await captureReview(tester, key, 'image-fitted-with-gutters');
      final controller = tester
          .widget<InteractiveViewer>(viewer)
          .transformationController!;
      expect(controller.value.entry(0, 0), closeTo(.9, .001));
      controller.value = Matrix4.identity()..scaleByDouble(.4, .4, 1, 1);
      await tester.pump();
      tester.widget<InteractiveViewer>(viewer).onInteractionEnd!(
        ScaleEndDetails(),
      );
      await tester.pumpAndSettle();
      expect(controller.value.entry(0, 0), closeTo(.4, .001));
      await captureReview(tester, key, 'image-shrink-with-gutters');
      await tester.tapAt(rect.center);
      await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
      await tester.pumpAndSettle();
      expect(find.byType(ReaderIllustrationGallery), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('list cover has no long-press peek and retains normal opening', (
    tester,
  ) async {
    phone(tester);
    final bytes = (await tester.runAsync(coverFixturePicture))!,
        key = GlobalKey();
    LegacyCover.seedLocalBytes(coverFixtureBook.id, bytes);
    var opened = 0;
    await tester.pumpWidget(
      app(
        Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(24),
            child: NovelRow(novel: coverFixtureBook, onTap: () => opened++),
          ),
        ),
        key,
      ),
    );
    final cover = find.byType(NovelCover).first;
    await tester.longPress(cover);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('book-cover-peek')), findsNothing);
    final before = opened;
    await tester.tap(cover);
    await tester.pumpAndSettle();
    expect(opened, before + 1);
    expect(tester.takeException(), isNull);
  });
  testWidgets('language uses an anchored dropdown and persists its selection', (
    tester,
  ) async {
    phone(tester, scale: 1.6);
    final state = await LibraryState.load(), key = GlobalKey();
    addTearDown(state.dispose);
    await tester.pumpWidget(
      app(
        Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(24),
            child: LanguageSettingMenu(state: state),
          ),
        ),
        key,
      ),
    );
    await tester.tap(
      find
          .descendant(
            of: find.byType(LanguageSettingMenu),
            matching: find.byType(InkWell),
          )
          .first,
    );
    await tester.pumpAndSettle();
    expect(find.byType(GlassMenuSurface), findsOneWidget);
    expect(
      tester.getSize(find.byType(GlassMenuSurface)).height,
      lessThan(844 * .6),
    );
    await captureReview(tester, key, 'language-anchored-menu');
    final choice = find.byWidgetPredicate(
      (w) => w is GlassMenuItem && w.label == AppLanguage.hongKong.label,
    );
    await tester.tap(
      find.descendant(of: choice, matching: find.byType(InkWell)).first,
    );
    await io(tester, () => state.language == AppLanguage.hongKong);
    expect(state.language, AppLanguage.hongKong);
    expect(
      (await SharedPreferences.getInstance()).getString('appLanguage'),
      'hongKong',
    );
    expect(tester.takeException(), isNull);
  });
  for (final local in [false, true]) {
    testWidgets(
      '${local ? 'local' : 'online'} detail has no book file export entry',
      (tester) async {
        phone(tester);
        final state = await LibraryState.load(), source = _Books();
        addTearDown(state.dispose);
        final original = source.books.first;
        final book = local
            ? Novel(
                id: localBookIdStart,
                title: original.title,
                author: original.author,
                genre: original.genre,
                summary: original.summary,
                colors: original.colors,
                chapters: original.chapters,
              )
            : original;
        await tester.pumpWidget(
          app(
            DetailPage(novel: book, state: state, repository: source),
            GlobalKey(),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('detail-download-book')),
          findsNothing,
        );
        expect(
          find.byWidgetPredicate(
            (widget) =>
                widget is GlassIconButton &&
                const ['下载书籍', '导出书籍'].contains(widget.label),
          ),
          findsNothing,
        );
        expect(find.text('下载 EPUB / TXT'), findsNothing);
        if (local) expect(action('配置本地书籍'), findsOneWidget);
        expect(find.byType(ReaderPage), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'reader language entry uses the same anchored menu inside the settings panel',
    (tester) async {
      phone(tester, scale: 1.3);
      final state = await LibraryState.load(),
          source = _Books(),
          key = GlobalKey();
      addTearDown(state.dispose);
      await tester.pumpWidget(
        app(
          ReaderPage(
            novel: source.books.first,
            state: state,
            repository: source,
            initialChapter: 0,
          ),
          key,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(195, 460));
      await tester.pumpAndSettle();
      await tester.tap(action('阅读设置'));
      await tester.pumpAndSettle();
      final language = find.byKey(const ValueKey('reader-language'));
      await tester.ensureVisible(language);
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(of: language, matching: find.byType(InkWell)).first,
      );
      await tester.pumpAndSettle();
      expect(find.byType(GlassMenuSurface), findsOneWidget);
      final menu = tester.getRect(find.byType(GlassMenuSurface));
      expect(menu.left, greaterThanOrEqualTo(0));
      expect(menu.right, lessThanOrEqualTo(390));
      expect(menu.bottom, lessThanOrEqualTo(844));
      await captureReview(tester, key, 'reader-language-anchored-menu');
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.tap(action('关闭阅读设置'));
      await tester.pumpAndSettle();
      expect(find.byType(ReaderPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'reader hint dismisses immediately and hidden-chrome back notice floats up',
    (tester) async {
      phone(tester);
      SharedPreferences.setMockInitialValues({
        'reduceMotion': true,
        'readerChromeVisible': false,
        'readerChromeHintSeen': false,
      });
      final state = await LibraryState.load(),
          source = _Books(),
          key = GlobalKey();
      addTearDown(state.dispose);
      await tester.pumpWidget(
        app(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => pushNovelPage<void>(
                context,
                ReaderPage(
                  novel: source.books.first,
                  state: state,
                  repository: source,
                  initialChapter: 0,
                ),
                reduceMotion: true,
              ),
              child: const Text('阅读'),
            ),
          ),
          key,
        ),
      );
      await tester.tap(find.text('阅读'));
      await tester.pumpAndSettle();
      expect(find.text('点击屏幕显示控件'), findsOneWidget);
      await tester.tapAt(const Offset(195, 460));
      await tester.pump(const Duration(milliseconds: 10));
      expect(find.text('点击屏幕显示控件'), findsNothing);
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(195, 460));
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('再滑动一次退出阅读'), findsOneWidget);
      expect(
        tester
            .getRect(find.byKey(const ValueKey('novel-feedback-surface')))
            .top,
        closeTo(32, 1),
      );
      await captureReview(tester, key, 'reader-hidden-back-notice');
      await tester.pump(const Duration(milliseconds: 1600));
      await tester.pumpAndSettle();
      expect(find.text('再滑动一次退出阅读'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'a live notice moves with the header instead of keeping a stale offset',
    (tester) async {
      phone(tester);
      await tester.pumpWidget(app(const _NoticeHeader(), GlobalKey()));
      await tester.tap(find.text('提示'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      final notice = find.byKey(const ValueKey('novel-feedback-surface'));
      final start = tester.getRect(notice).top;
      await tester.tap(find.text('隐藏栏'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      expect(tester.getRect(notice).top, lessThan(start));
      await tester.pump(const Duration(milliseconds: 180));
      expect(tester.getRect(notice).top, closeTo(32, 1));
      final glass = tester.widget<LiquidGlass>(notice);
      expect(glass.tintColor, isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );
}
