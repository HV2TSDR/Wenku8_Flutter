import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/app_interactions.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/feature_pages.dart';
import 'package:wenku8_flutter/legacy_wenku_repository.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/pages.dart';

import 'support/visual_review.dart';

void main({
  bool native = false,
  Future<void> Function(WidgetTester, GlobalKey, String)? capture,
}) {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (!native) setUpAll(loadReviewFonts);
  setUp(() => SharedPreferences.setMockInitialValues({'reduceMotion': true}));
  Future<void> shot(WidgetTester tester, GlobalKey key, String name) async {
    if (capture == null) {
      await captureReview(tester, key, name);
    } else {
      await capture(tester, key, name);
    }
  }

  for (final compact in [false, true]) {
    Future<GlobalKey> mount(WidgetTester tester, Widget page) async {
      tester.view.physicalSize = Size(compact ? 320 : 390, 844);
      tester.view.devicePixelRatio = 1;
      tester.view.padding = const FakeViewPadding(top: 28, bottom: 24);
      tester.view.viewPadding = tester.view.padding;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.view.resetViewPadding);
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: novelTheme(compact ? Brightness.dark : Brightness.light),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(compact ? 1.4 : 1)),
              child: child!,
            ),
            home: page,
          ),
        ),
      );
      await tester.pumpAndSettle();
      return key;
    }

    testWidgets(
      '${compact ? 'compact' : 'phone'} publication header centers and category menu matches discovery',
      (tester) async {
        final state = await LibraryState.load();
        addTearDown(state.dispose);
        final repository = LegacyWenkuRepository(
          request: (_) async =>
              '<metadata><item sort="1">电击文库</item>'
              '<item sort="2">富士见文库</item><item sort="3">角川文库</item></metadata>',
          publicationRequest: (_) async => '<result><page num="0"/></result>',
        );
        final key = await mount(
          tester,
          PublicationLibraryPage(
            catalog: repository,
            repository: repository,
            state: state,
          ),
        );
        expect(
          tester.getCenter(find.text('出版文库')).dx,
          closeTo((compact ? 320 : 390) / 2, .1),
        );
        await tester.tap(
          find.byWidgetPredicate(
            (w) => w is GlassIconButton && w.label == '分类与排序',
          ),
        );
        await tester.pumpAndSettle();
        final menu = find.byType(GlassOverlaySurface);
        final items = find.descendant(
          of: menu,
          matching: find.byType(GlassMenuItem),
        );
        expect(items, findsNWidgets(3));
        expect(tester.widgetList<GlassMenuItem>(items).map((w) => w.selected), [
          true,
          false,
          false,
        ]);
        expect(
          find.descendant(of: menu, matching: find.byType(GlassTextButton)),
          findsNothing,
        );
        await shot(
          tester,
          key,
          'publication-menu-${compact ? 'compact-dark' : 'light'}',
        );
        await tester.tap(
          find.descendant(of: menu, matching: find.text('富士见文库')),
        );
        await tester.pumpAndSettle();
        expect(
          tester.widget<DiscoverPage>(find.byType(DiscoverPage)).categoryTitle,
          '富士见文库',
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets(
      '${compact ? 'compact' : 'phone'} feedback notice stays above the dock and keeps latest undo usable',
      (tester) async {
        final state = await LibraryState.load();
        addTearDown(state.dispose);
        final key = await mount(
          tester,
          HomeShell(state: state, repository: const DemoNovelRepository()),
        );
        final context = tester.element(find.byType(HomeShell));
        showNovelFeedback(context, '旧消息');
        await tester.pumpAndSettle();
        showNovelFeedback(
          context,
          '已移出书架，原书与阅读进度仍然保留。',
          actionLabel: '撤销',
          action: () async => throw StateError('fixture'),
          actionFailure: '撤销保存失败，请重试',
        );
        await tester.pumpAndSettle();
        expect(find.text('旧消息'), findsNothing);
        expect(find.byType(NovelFeedbackNotice), findsOneWidget);
        final notice = tester.getRect(
          find.byKey(const ValueKey('novel-feedback-surface')),
        );
        final dock = tester.getRect(find.byKey(const ValueKey('liquid-dock')));
        expect(
          notice.top,
          greaterThanOrEqualTo(28 + FrostedHeader.toolbarHeight),
        );
        expect(notice.bottom, lessThan(dock.top - 16));
        await shot(
          tester,
          key,
          'feedback-${compact ? 'compact-dark' : 'light'}',
        );
        await tester.tap(find.text('撤销'));
        await tester.pumpAndSettle();
        expect(find.text('撤销保存失败，请重试'), findsOneWidget);
        expect(find.byTooltip('关闭提示'), findsNothing);
        await tester.pump(const Duration(seconds: 5));
        await tester.pumpAndSettle();
        expect(find.byType(NovelFeedbackNotice), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'landscape feedback notice keeps a clear dock band even with long text',
    (tester) async {
      tester.view.physicalSize = const Size(740, 360);
      tester.view.devicePixelRatio = 1;
      tester.view.padding = const FakeViewPadding(top: 28, bottom: 24);
      tester.view.viewPadding = tester.view.padding;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.view.resetViewPadding);
      final state = await LibraryState.load();
      addTearDown(state.dispose);
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: novelTheme(Brightness.light),
            home: HomeShell(
              state: state,
              repository: const DemoNovelRepository(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      showNovelFeedback(
        tester.element(find.byType(HomeShell)),
        '这是一条较长的操作提示。' * 30,
      );
      await tester.pumpAndSettle();
      final notice = tester.getRect(
        find.byKey(const ValueKey('novel-feedback-surface')),
      );
      final dock = tester.getRect(find.byKey(const ValueKey('liquid-dock')));
      expect(notice.bottom, lessThanOrEqualTo(dock.top - 16));
      await shot(tester, key, 'feedback-landscape');
      expect(find.byTooltip('关闭提示'), findsNothing);
      await tester.pump(const Duration(seconds: 13));
      await tester.pumpAndSettle();
      expect(find.byType(NovelFeedbackNotice), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'feedback notice from a sheet is visible above its source and respects accessible navigation',
    (tester) async {
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            theme: novelTheme(Brightness.light),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(accessibleNavigation: true, disableAnimations: true),
              child: child!,
            ),
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showJellySheet<void>(
                    context: context,
                    reduceMotion: true,
                    builder: (sheet) => GlassTextButton(
                      onPressed: () => showNovelFeedback(sheet, '分类已保存'),
                      child: const Text('保存分类测试'),
                    ),
                  ),
                  child: const Text('打开抽屉'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('打开抽屉'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存分类测试'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 8));
      expect(find.text('分类已保存'), findsOneWidget);
      expect(find.byTooltip('关闭提示'), findsNothing);
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(find.byType(NovelFeedbackNotice), findsNothing);
      expect(find.byType(GlassOverlaySurface), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
