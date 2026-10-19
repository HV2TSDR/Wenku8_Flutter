import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/reader_panels.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/pages.dart';
import 'package:wenku8_flutter/reader_landing_highlight.dart';
import 'package:wenku8_flutter/reader_preferences.dart';
import 'package:wenku8_flutter/reader_tools.dart';
import 'package:wenku8_flutter/reader_paged_view.dart';
import 'support/visual_review.dart';
import 'reader_modes_test.dart' show settleReader;

import 'support/offline_fixture.dart';

Finder _control(String label) => find
    .descendant(
      of: find.byWidgetPredicate(
        (widget) => widget is GlassIconButton && widget.label == label,
      ),
      matching: find.byType(InkWell),
    )
    .first;

ScrollableState _article(WidgetTester tester) => tester.state<ScrollableState>(
  find
      .descendant(
        of: find.byKey(const ValueKey('reader-scroll')),
        matching: find.byType(Scrollable),
      )
      .first,
);

void _expectBookmarkCentred(WidgetTester tester, ReadingPosition saved) {
  final paragraph = find.byKey(ValueKey('paragraph-${saved.paragraphIndex}'));
  expect(paragraph, findsOneWidget);
  final rect = tester.getRect(paragraph);
  final viewport = tester.getRect(find.byKey(const ValueKey('reader-scroll')));
  final media = MediaQuery.of(tester.element(paragraph));
  final top =
      media.viewPadding.top + FrostedHeader.toolbarHeight + 12 - viewport.top;
  final bottom =
      _article(tester).position.viewportDimension - media.padding.bottom - 96;
  final point = rect.height <= bottom - top
      ? rect.center.dy
      : rect.top + rect.height * saved.paragraphFraction;
  expect(point, closeTo(viewport.top + (top + bottom) / 2, 1));
}

Future<void> _io(WidgetTester tester) async {
  for (var step = 0; step < 8; step++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 16));
  }
  await tester.pumpAndSettle();
}

void main({
  Future<void> Function(WidgetTester tester, GlobalKey key, String name)?
  capture,
}) {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadReviewFonts);
  late LibraryState state;
  late OfflineFixtureRepository remote;
  late GlobalKey boundary;
  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'readerChromeVisible': true,
      'readerChromeHintSeen': true,
      'reduceMotion': true,
    });
    state = await LibraryState.load();
    remote = OfflineFixtureRepository();
    boundary = GlobalKey();
  });
  tearDown(() {
    state.dispose();
  });

  Future<void> reader(
    WidgetTester tester, {
    double scale = 1,
    Brightness brightness = Brightness.light,
  }) async {
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: novelTheme(brightness),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: ReaderPage(
            novel: remote.books[71]!,
            state: state,
            repository: remote,
            initialChapter: 0,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> settings(WidgetTester tester, {bool bookmarks = false}) async {
    await tester.tap(_control('阅读设置'));
    await tester.pumpAndSettle();
    if (bookmarks) {
      await tester.tap(find.text('书签'));
      await tester.pumpAndSettle();
    }
  }

  Future<void> shot(WidgetTester tester, String name) async {
    if (capture != null) await capture(tester, boundary, name);
  }

  testWidgets(
    'page-effect choices wrap at large text, persist and do not repaginate',
    (tester) async {
      tester.view.physicalSize = const Size(320, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(
        () => state.setReaderPreferences(
          const ReaderPreferences(mode: ReaderMode.paged),
        ),
      );
      await reader(tester, scale: 1.4, brightness: Brightness.dark);
      await settleReader(tester);
      final controller = tester
          .widget<ReaderPagedView>(find.byType(ReaderPagedView))
          .controller;
      final generation = controller.debugLayoutGeneration;
      await settings(tester);
      await tester.ensureVisible(find.text('翻页效果'));
      await tester.pumpAndSettle();
      await captureReview(tester, boundary, 'reader-effects-compact-dark');
      for (final effect in ReaderPageEffect.values.reversed) {
        final button = find.byKey(
          ValueKey('reader-page-effect-${effect.name}'),
        );
        await tester.ensureVisible(button);
        await tester.pumpAndSettle();
        await tester.tap(button);
        await _io(tester);
        expect(state.readerPreferences.pageEffect, effect);
        expect(controller.debugLayoutGeneration, generation);
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'typography previews live through a clear sheet and persists only on release',
    (tester) async {
      await reader(tester);
      final original = tester.widget(find.byKey(const ValueKey('paragraph-0')));
      final calls = remote.calls.length;
      var notifications = 0;
      state.readerSettingsChanges.addListener(() => notifications++);
      await settings(tester);
      tester
          .widget<AppGlassSlider>(
            find.byKey(const ValueKey('reader-font-slider')),
          )
          .onChangeStart!(19);
      for (var index = 0; index < 120; index++) {
        final slider = tester.widget<AppGlassSlider>(
          find.byKey(const ValueKey('reader-font-slider')),
        );
        slider.onChanged!(15 + index % 13);
        await tester.pump();
      }
      expect(
        tester.widget(find.byKey(const ValueKey('paragraph-0'))),
        isNot(same(original)),
      );
      expect(notifications, greaterThan(0));
      expect(state.fontSize, 17);
      expect(
        tester
            .widget<GlassOverlaySurface>(find.byType(GlassOverlaySurface))
            .transparent,
        isTrue,
      );
      expect(remote.calls.length, calls);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('readerFontSize'), isFalse);
      tester
          .widget<AppGlassSlider>(
            find.byKey(const ValueKey('reader-font-slider')),
          )
          .onChanged!(23);
      await tester.pump();
      await shot(tester, 'reader-font-live-preview');
      tester
          .widget<AppGlassSlider>(
            find.byKey(const ValueKey('reader-font-slider')),
          )
          .onChangeEnd!(23);
      await _io(tester);
      expect(state.fontSize, 23);
      expect(prefs.getDouble('readerFontSize'), 23);
      expect(
        tester
            .widget<GlassOverlaySurface>(find.byType(GlassOverlaySurface))
            .transparent,
        isFalse,
      );
      final line = tester.widget<AppGlassSlider>(
        find.byKey(const ValueKey('reader-line-height-slider')),
      );
      line.onChangeStart!(line.value);
      line.onChanged!(1.95);
      await tester.pump();
      expect(state.lineHeight, 1.95);
      expect(prefs.containsKey('readerLineHeight'), isFalse);
      expect(
        tester
            .widget<GlassOverlaySurface>(find.byType(GlassOverlaySurface))
            .transparent,
        isTrue,
      );
      await shot(tester, 'reader-line-live-preview');
      line.onChangeEnd!(1.95);
      await _io(tester);
      expect(state.lineHeight, 1.95);
      expect(prefs.getDouble('readerLineHeight'), 1.95);
      await shot(tester, 'reader-tools-layout');
      await tester.scrollUntilVisible(
        find.text('恢复默认排版'),
        140,
        scrollable: find.descendant(
          of: find.byKey(const ValueKey('reader-settings-scroll')),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.tap(find.text('恢复默认排版'));
      await _io(tester);
      expect(state.fontSize, 19);
      expect(state.lineHeight, 1.72);
      expect(tester.takeException(), isNull);
    },
  );

  for (final (name, initial, next) in [
    ('margin', 24.0, 40.0),
    ('paragraph-gap', 16.0, 28.0),
  ]) {
    testWidgets(
      '$name adjustment previews live through a transparent panel and commits only on release',
      (tester) async {
        await reader(tester);
        await settings(tester);
        final finder = find.byKey(ValueKey('reader-$name-slider'));
        await tester.ensureVisible(finder);
        await tester.pumpAndSettle();
        final stored = await SharedPreferences.getInstance();
        final before = stored.getString('readerPreferences');
        var slider = tester.widget<AppGlassSlider>(finder);
        slider.onChangeStart!(initial);
        slider.onChanged!(next);
        await tester.pump();
        expect(
          tester
              .widget<GlassOverlaySurface>(find.byType(GlassOverlaySurface))
              .transparent,
          isTrue,
        );
        expect(
          name == 'margin'
              ? state.readerPreferences.margin
              : state.readerPreferences.paragraphGap,
          next,
        );
        expect(stored.getString('readerPreferences'), before);
        slider = tester.widget<AppGlassSlider>(finder);
        slider.onChangeEnd!(next);
        await _io(tester);
        expect(
          tester
              .widget<GlassOverlaySurface>(find.byType(GlassOverlaySurface))
              .transparent,
          isFalse,
        );
        expect(
          stored.getString('readerPreferences'),
          contains(name == 'margin' ? '"margin":40' : '"paragraphGap":28'),
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'reader accessibility increments commit without waiting for pointer release',
    (tester) async {
      final semantics = tester.ensureSemantics();
      await reader(tester);
      await settings(tester);
      final key = find.byKey(const ValueKey('reader-slider-semantics-字体大小'));
      final node = tester.getSemantics(key);
      expect(node.getSemanticsData().value, '19 pt');
      node.owner!.performAction(node.id, ui.SemanticsAction.increase);
      await _io(tester);
      expect(state.fontSize, 20);
      expect(
        (await SharedPreferences.getInstance()).getDouble('readerFontSize'),
        20,
      );
      await state.setFontSize(27);
      await tester.pumpAndSettle();
      expect(
        tester
            .getSemantics(key)
            .getSemanticsData()
            .hasAction(ui.SemanticsAction.increase),
        isFalse,
      );
      expect(tester.takeException(), isNull);
      semantics.dispose();
    },
  );

  testWidgets(
    'bookmark captures position, restores without body refetch, and persists removal',
    (tester) async {
      await reader(tester);
      _article(tester).position.jumpTo(960);
      await tester.pumpAndSettle();
      final position = _article(tester).position.pixels;
      await settings(tester, bookmarks: true);
      await tester.tap(find.text('添加当前位置书签'));
      await _io(tester);
      expect(find.text('已添加书签'), findsOneWidget);
      final mark = state.bookmarksFor(71).single;
      expect(mark.position.offset, closeTo(position, 1));
      expect((await LibraryState.load()).bookmarksFor(71).single.id, mark.id);
      await shot(tester, 'reader-tools-bookmarks');
      await tester.tap(_control('关闭阅读设置'));
      await tester.pumpAndSettle();
      _article(tester).position.jumpTo(0);
      await tester.pumpAndSettle();
      final requests = remote.calls.length;
      await settings(tester, bookmarks: true);
      await tester.tap(
        find
            .descendant(
              of: find.byKey(ValueKey('reader-bookmark-${mark.id}')),
              matching: find.byType(InkWell),
            )
            .first,
      );
      await tester.pumpAndSettle();
      _expectBookmarkCentred(tester, mark.position);
      final landing = _article(tester).position.pixels;
      expect(landing, lessThan(position));
      expect(remote.calls.length, requests);
      expect(find.byType(ReaderLandingHighlight), findsOneWidget);
      await shot(tester, 'reader-bookmark-landing');
      await tester.pump(const Duration(milliseconds: 2250));
      expect(find.byType(ReaderLandingHighlight), findsNothing);
      expect(_article(tester).position.pixels, closeTo(landing, 1));
      final resume = state.positionFor(71)!.toJson();
      await settings(tester, bookmarks: true);
      await tester.tap(_control('删除书签 ${mark.id}'));
      await _io(tester);
      expect(state.bookmarksFor(71), isEmpty);
      expect(state.positionFor(71)!.toJson(), resume);
      expect((await LibraryState.load()).bookmarksFor(71), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'bookmark switches to its chapter and restores after a pending request',
    (tester) async {
      await reader(tester);
      _article(tester).position.jumpTo(850);
      await tester.pumpAndSettle();
      await settings(tester, bookmarks: true);
      await tester.tap(find.text('添加当前位置书签'));
      await _io(tester);
      final mark = state.bookmarksFor(71).single;
      await tester.tap(_control('关闭阅读设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('dock-tab-2')));
      await tester.pumpAndSettle();
      expect(
        state.positionFor(71)!.chapterId,
        remote.books[71]!.chapters[1].id,
      );
      await settings(tester, bookmarks: true);
      await tester.tap(
        find
            .descendant(
              of: find.byKey(ValueKey('reader-bookmark-${mark.id}')),
              matching: find.byType(InkWell),
            )
            .first,
      );
      await tester.pumpAndSettle();
      expect(state.positionFor(71)!.chapterId, mark.position.chapterId);
      _expectBookmarkCentred(tester, mark.position);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'the unified settings bookmark tab opens saved positions with an explicit guide',
    (tester) async {
      await reader(tester);
      await openReaderPanel(tester, tab: '书签');
      expect(find.byKey(const ValueKey('reader-add-bookmark')), findsOneWidget);
      expect(find.text('先添加当前位置，再点按下方书签即可回到这里。'), findsOneWidget);
      await shot(tester, 'reader-bookmark-entry');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'bookmark stays centred after larger typography and includes safe insets',
    (tester) async {
      tester.view.physicalSize = const Size(390, 760);
      tester.view.devicePixelRatio = 1;
      tester.view.padding = const FakeViewPadding(top: 28, bottom: 24);
      tester.view.viewPadding = const FakeViewPadding(top: 28, bottom: 24);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.view.resetViewPadding);
      await reader(tester);
      _article(tester).position.jumpTo(1600);
      await tester.pumpAndSettle();
      await settings(tester, bookmarks: true);
      await tester.tap(find.text('添加当前位置书签'));
      await _io(tester);
      final mark = state.bookmarksFor(71).single;
      await tester.tap(_control('关闭阅读设置'));
      await tester.pumpAndSettle();
      await state.setFontSize(27);
      await state.setLineHeight(1.95);
      await tester.pumpAndSettle();
      _article(tester).position.jumpTo(0);
      await tester.pumpAndSettle();
      await settings(tester, bookmarks: true);
      await tester.tap(
        find
            .descendant(
              of: find.byKey(ValueKey('reader-bookmark-${mark.id}')),
              matching: find.byType(InkWell),
            )
            .first,
      );
      await tester.pumpAndSettle();
      _expectBookmarkCentred(tester, mark.position);
      expect(find.byType(ReaderLandingHighlight), findsOneWidget);
      await shot(tester, 'reader-bookmark-centred-large');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'chapter progress detents are light, rate limited and only run during dragging',
    (tester) async {
      final haptics = <Object?>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'HapticFeedback.vibrate') {
            haptics.add(call.arguments);
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
      await tester.pumpWidget(
        MaterialApp(
          home: ReaderValueSlider(
            sliderKey: const ValueKey('test-progress'),
            label: '本章进度',
            value: 0,
            min: 0,
            max: 1,
            divisions: 500,
            hapticSteps: 100,
            format: (value) => '${(value * 100).round()}%',
            onCommitted: (_) {},
          ),
        ),
      );
      final slider = tester.widget<AppGlassSlider>(
        find.byKey(const ValueKey('test-progress')),
      );
      slider.onChangeStart!(0);
      slider.onChanged!(.001);
      expect(haptics, isEmpty);
      slider.onChanged!(.011);
      slider.onChanged!(.022);
      expect(haptics, ['HapticFeedbackType.selectionClick']);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 75)),
      );
      slider.onChanged!(.034);
      expect(haptics.length, 2);
      slider.onChangeEnd!(.034);
      slider.onChanged!(.08);
      expect(haptics.length, 2);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'progress scrubs through a transparent sheet, commits on release and continues with the existing Dock',
    (tester) async {
      tester.view.physicalSize = const Size(390, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await reader(tester);
      await openReaderChapterProgress(tester);
      await tester.ensureVisible(
        find.ancestor(
          of: find.byKey(const ValueKey('reader-progress-slider')),
          matching: find.byType(ReaderValueSlider),
        ),
      );
      await tester.pumpAndSettle();
      final progress = tester.widget<AppGlassSlider>(
        find.byKey(const ValueKey('reader-progress-slider')),
      );
      progress.onChangeStart!(progress.value);
      progress.onChanged!(.65);
      await tester.pump(const Duration(milliseconds: 64));
      expect(
        tester
            .widget<GlassOverlaySurface>(find.byType(GlassOverlaySurface))
            .transparent,
        isTrue,
      );
      expect(_article(tester).position.pixels, greaterThan(0));
      await captureReview(
        tester,
        boundary,
        'reader-progress-transparent-preview',
      );
      progress.onChangeEnd!(.65);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<GlassOverlaySurface>(find.byType(GlassOverlaySurface))
            .transparent,
        isFalse,
      );
      expect(_article(tester).position.pixels, greaterThan(0));
      expect(state.positionFor(71)!.fraction, closeTo(.65, .02));
      await tester.ensureVisible(find.text('跳至章末'));
      await tester.tap(find.text('跳至章末'));
      await tester.pumpAndSettle();
      final scroll = _article(tester).position;
      expect(scroll.pixels, closeTo(scroll.maxScrollExtent, 1));
      expect(find.text('继续向下阅读下一章'), findsOneWidget);
      await tester.drag(
        find.byKey(const ValueKey('reader-scroll')),
        const Offset(0, -160),
      );
      await tester.pumpAndSettle();
      expect(state.positionFor(71)!.chapter, 1);
      expect(_article(tester).position.pixels, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'reader tools remain scrollable with large text and a small keyboard viewport',
    (tester) async {
      tester.view.physicalSize = const Size(390, 440);
      tester.view.devicePixelRatio = 1;
      tester.view.viewInsets = const FakeViewPadding(bottom: 200);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      await reader(tester, scale: 2, brightness: Brightness.dark);
      await settings(tester);
      expect(tester.takeException(), isNull);
      final scroll = find.descendant(
        of: find.byKey(const ValueKey('reader-settings-scroll')),
        matching: find.byType(Scrollable),
      );
      await tester.scrollUntilVisible(
        find.text('恢复默认排版'),
        160,
        scrollable: scroll,
      );
      await shot(tester, 'reader-tools-small-dark');
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await openReaderChapterProgress(tester);
      await tester.ensureVisible(find.text('跳至章末'));
      await tester.tap(find.text('跳至章末'));
      await tester.pumpAndSettle();
      expect(
        _article(tester).position.pixels,
        closeTo(_article(tester).position.maxScrollExtent, 1),
      );
      expect(tester.takeException(), isNull);
    },
  );
}
