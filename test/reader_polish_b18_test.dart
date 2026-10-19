import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart' as easy;
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/glass_dock.dart';
import 'package:wenku8_flutter/legacy_wenku_repository.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/pages.dart';
import 'package:wenku8_flutter/review_pages.dart';
import 'package:wenku8_flutter/wenku_features.dart';
import 'package:wenku8_flutter/wenku_reviews.dart';

import 'feature_completion_state_test.dart' show AccountFixture, reviewXml;
import 'support/visual_review.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadReviewFonts);
  setUp(
    () => SharedPreferences.setMockInitialValues({
      'readerChromeVisible': true,
      'readerChromeHintSeen': true,
    }),
  );

  for (final brightness in Brightness.values) {
    testWidgets(
      'package glass controls share a soft palette in ${brightness.name}',
      (tester) async {
        final capture = GlobalKey();
        var enabled = false;
        await tester.pumpWidget(
          MaterialApp(
            theme: novelTheme(brightness),
            home: RepaintBoundary(
              key: capture,
              child: Scaffold(
                body: Center(
                  child: SizedBox(
                    width: 280,
                    child: StatefulBuilder(
                      builder: (context, update) => CupertinoTheme(
                        // A sheet or a system theme must not recolor these controls.
                        data: CupertinoThemeData(
                          brightness: brightness == Brightness.dark
                              ? Brightness.light
                              : Brightness.dark,
                          primaryColor: CupertinoColors.systemGreen,
                        ),
                        child: ContentPanel(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Text('共用控件'),
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  const Text('开启状态'),
                                  AppControls.toggle(
                                    context,
                                    key: const ValueKey('switch-enabled'),
                                    value: true,
                                    onChanged: (_) {},
                                  ),
                                ],
                              ),
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  const Text('交互开关'),
                                  AppControls.toggle(
                                    context,
                                    key: const ValueKey('switch-interactive'),
                                    value: enabled,
                                    onChanged: (value) =>
                                        update(() => enabled = value),
                                  ),
                                ],
                              ),
                              AppControls.toggle(
                                context,
                                key: const ValueKey('switch-disabled'),
                                value: false,
                                onChanged: null,
                              ),
                              AppControls.slider(
                                context,
                                value: .45,
                                onChanged: (_) {},
                              ),
                              AppControls.segments<int>(
                                context,
                                groupValue: 0,
                                children: const {
                                  0: Text('排版'),
                                  1: Text('操作'),
                                  2: Text('书签'),
                                },
                                onValueChanged: (_) {},
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final toggle = tester.widget<AppGlassSwitch>(
          find.byKey(const ValueKey('switch-enabled')),
        );
        final scheme = novelTheme(brightness).colorScheme;
        expect(
          toggle.activeColor.computeLuminance(),
          inInclusiveRange(.18, .4),
        );
        expect(toggle.activeColor, isNot(scheme.primary));
        expect(toggle.thumbColor, ArchiveDesign.milk);
        expect(toggle.inactiveColor, isNot(toggle.activeColor));
        expect(find.byType(easy.LiquidGlassSwitch), findsNWidgets(3));
        expect(find.byType(easy.LiquidGlassSlider), findsOneWidget);
        expect(find.byType(easy.LiquidGlassSegmented), findsOneWidget);
        final semantics = tester.ensureSemantics();
        expect(
          tester.getSemantics(find.byKey(const ValueKey('switch-disabled'))),
          matchesSemantics(
            isEnabled: false,
            hasEnabledState: true,
            hasToggledState: true,
          ),
        );
        semantics.dispose();
        await tester.tap(find.byKey(const ValueKey('switch-interactive')));
        await tester.pumpAndSettle();
        expect(enabled, true);
        await captureReview(tester, capture, 'controls-${brightness.name}');
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'mode dock unfolds retained controls without row fades or duplicate glass',
    (tester) async {
      final capture = GlobalKey();
      late StateSetter change;
      var reader = false;
      const items = [
        GlassDockItem(CupertinoIcons.house, '发现'),
        GlassDockItem(CupertinoIcons.book, '书架'),
        GlassDockItem(CupertinoIcons.folder, '本地'),
        GlassDockItem(CupertinoIcons.settings, '设置'),
      ];
      await tester.pumpWidget(
        MaterialApp(
          theme: novelTheme(Brightness.light),
          home: RepaintBoundary(
            key: capture,
            child: Scaffold(
              body: Center(
                child: StatefulBuilder(
                  builder: (context, update) {
                    change = update;
                    return GlassDock(
                      selectedIndex: reader ? 1 : 3,
                      onSelected: (_) {},
                      items: reader ? items.sublist(2) : items,
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final dock = find.byType(GlassDock);
      final surface = tester.element(
        find.byKey(const ValueKey('dock-fluid-surface')),
      );
      final width = tester.getSize(dock).width;
      final iconWidth = tester
          .getSize(find.byIcon(CupertinoIcons.settings))
          .width;
      change(() => reader = true);
      await tester.pump();
      expect(tester.getSize(dock).width, width);
      await tester.pump(const Duration(milliseconds: 120));
      final middle = tester.getSize(dock).width;
      expect(middle, lessThan(width));
      expect(middle, greaterThan(2 * 184 / 3 + 12));
      expect(
        tester.getSize(find.byIcon(CupertinoIcons.settings)).width,
        iconWidth,
      );
      expect(find.text('设置'), findsOneWidget);
      expect(
        find.descendant(of: dock, matching: find.byType(AnimatedSwitcher)),
        findsNothing,
      );
      expect(
        find.descendant(of: dock, matching: find.byType(FadeTransition)),
        findsNothing,
      );
      expect(
        tester.element(find.byKey(const ValueKey('dock-fluid-surface'))),
        same(surface),
      );
      await captureReview(tester, capture, 'dock-contracting');
      change(() => reader = false);
      await tester.pump();
      expect(tester.getSize(dock).width, closeTo(middle, .001));
      await tester.pump(const Duration(milliseconds: 100));
      await captureReview(tester, capture, 'dock-expanding');
      await tester.pumpAndSettle();
      expect(tester.getSize(dock).width, width);
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('reader dock deformation stays inside its chrome clip', (
    tester,
  ) async {
    final library = await LibraryState.load();
    final capture = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        theme: novelTheme(Brightness.light),
        home: RepaintBoundary(
          key: capture,
          child: ReaderPage(
            novel: demoNovels.first,
            state: library,
            repository: const DemoNovelRepository(),
            initialChapter: 0,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final dock = find.byKey(const ValueKey('reader-liquid-dock'));
    final clip = tester.getRect(
      find.ancestor(of: dock, matching: find.byType(ClipRect)).first,
    );
    final surface = find.byKey(const ValueKey('dock-fluid-surface'));
    final gesture = await tester.startGesture(tester.getCenter(dock));
    await tester.pump(const Duration(milliseconds: 120));
    for (final delta in [18.0, -36.0]) {
      await gesture.moveBy(
        Offset(delta, 0),
        timeStamp: Duration(milliseconds: delta > 0 ? 180 : 240),
      );
      await tester.pump(const Duration(milliseconds: 16));
      final rect = tester.getRect(surface);
      expect(clip.contains(rect.topLeft), true);
      expect(clip.contains(rect.bottomRight), true);
      await captureReview(
        tester,
        capture,
        delta > 0 ? 'reader-dock-right' : 'reader-dock-left',
      );
    }
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    library.dispose();
  });

  for (final scale in [1.0, 1.8]) {
    testWidgets('detail community actions remain one readable row at $scale', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final library = await LibraryState.load();
      final fixture = AccountFixture();
      final capture = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: novelTheme(Brightness.light),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: RepaintBoundary(
            key: capture,
            child: WenkuFeaturesScope(
              features: WenkuFeatures(
                account: fixture.account,
                publications: LegacyWenkuRepository(),
              ),
              child: Scaffold(
                body: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: BookCommunityActions(
                      novel: demoNovels.first,
                      state: library,
                      repository: const DemoNovelRepository(),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final rects = [
        for (final key in [
          'detail-cloud-save',
          'detail-recommend',
          'detail-reviews',
          'detail-share',
        ])
          tester.getRect(find.byKey(ValueKey(key))),
      ];
      for (final rect in rects) {
        expect(rect.top, rects.first.top);
        expect(rect.height, rects.first.height);
      }
      for (final key in [
        'detail-cloud-save',
        'detail-recommend',
        'detail-reviews',
        'detail-share',
      ]) {
        expect(
          tester.widget(find.byKey(ValueKey(key))),
          isA<GlassTextButton>(),
        );
      }
      if (scale == 1) expect(rects.last.right, lessThanOrEqualTo(296));
      await captureReview(tester, capture, 'detail-actions-$scale');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      fixture.account.dispose();
      library.dispose();
    });
  }

  testWidgets('reply skeleton uses text columns at large type, not book covers', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final library = await LibraryState.load();
    final fixture = AccountFixture();
    final pending = Completer<String>();
    final feed = WenkuReviewFeed(
      id: 81,
      replies: true,
      request: (_) => pending.future,
    );
    final capture = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        theme: novelTheme(Brightness.dark),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.8)),
          child: child!,
        ),
        home: RepaintBoundary(
          key: capture,
          child: WenkuReviewsPage(
            novel: demoNovels.first,
            account: fixture.account,
            state: library,
            repository: const DemoNovelRepository(),
            feed: feed,
            thread: const WenkuReview(
              id: 81,
              user: '读者',
              userId: 1,
              title: '作品讨论',
              content: '',
              timestamp: '',
              replies: 1,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('skeleton-reviewThread')),
      findsNWidgets(3),
    );
    expect(find.byKey(const ValueKey('skeleton-bookRow')), findsNothing);
    await captureReview(tester, capture, 'replies-loading-large-dark');
    pending.complete(
      '<result><page num="1"/><item timestamp="20261005103000"><user uid="81">读者</user><content>完整正文与回复。</content></item></result>',
    );
    await tester.pumpAndSettle();
    expect(find.text('完整正文与回复。'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    feed.dispose();
    fixture.account.dispose();
    library.dispose();
  });

  testWidgets(
    'review cards retain matching skeletons through their content handoff',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final library = await LibraryState.load();
      final fixture = AccountFixture();
      final pending = Completer<String>();
      final feed = WenkuReviewFeed(id: 71, request: (_) => pending.future);
      final capture = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: novelTheme(Brightness.light),
          home: RepaintBoundary(
            key: capture,
            child: WenkuReviewsPage(
              novel: demoNovels.first,
              account: fixture.account,
              state: library,
              repository: const DemoNovelRepository(),
              feed: feed,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ReviewCardSkeleton), findsNWidgets(3));
      expect(find.byKey(const ValueKey('skeleton-bookRow')), findsNothing);
      await captureReview(tester, capture, 'reviews-loading');
      pending.complete(reviewXml(81, pages: 1));
      await tester.pump();
      await tester.pump();
      expect(find.byType(ReviewCardSkeleton), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 100));
      await captureReview(tester, capture, 'reviews-handoff');
      await tester.pumpAndSettle();
      expect(find.byType(ReviewCardSkeleton), findsNothing);
      expect(find.text('书评 81'), findsOneWidget);
      await captureReview(tester, capture, 'reviews-loaded');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      feed.dispose();
      fixture.account.dispose();
      library.dispose();
    },
  );
}
