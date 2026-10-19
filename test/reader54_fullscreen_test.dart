import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/local_platform.dart';
import 'package:wenku8_flutter/pages.dart';
import 'package:wenku8_flutter/reader_chrome.dart';
import 'package:wenku8_flutter/reader_paged_view.dart';
import 'package:wenku8_flutter/reader_preferences.dart';
import 'package:wenku8_flutter/reader_status.dart';
import 'reader_modes_test.dart' as fixture;
import 'support/visual_review.dart';

class _PendingBook extends DemoNovelRepository {
  final ready = Completer<Novel>();
  @override
  Future<Novel> detail(Novel novel) => ready.future;
  @override
  Future<List<NovelChapter>> chapters(int novelId) async =>
      fixture.book.chapters;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadReviewFonts);
  setUp(() {
    SharedPreferences.setMockInitialValues({
      'readerChromeVisible': false,
      'readerChromeHintSeen': true,
      'reduceMotion': true,
    });
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      LocalPlatform.readerControls,
      (_) async => null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('org.mewx.wenku8/reader_status'),
      (_) async => null,
    );
  });
  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(LocalPlatform.readerControls, null);
    messenger.setMockMethodCallHandler(
      const MethodChannel('org.mewx.wenku8/reader_status'),
      null,
    );
  });

  for (final visible in [false, true]) {
    testWidgets(
      'direct reader loading honours saved chrome $visible through handoff',
      (tester) async {
        final state = await LibraryState.load();
        addTearDown(state.dispose);
        await state.setReaderChromeVisible(visible);
        final source = _PendingBook();
        await tester.pumpWidget(
          MaterialApp(
            theme: novelTheme(Brightness.light),
            home: ReaderLoaderPage(
              novel: fixture.book,
              state: state,
              repository: source,
            ),
          ),
        );
        await tester.pump();
        expect(
          find.byType(FrostedHeader),
          visible ? findsOneWidget : findsNothing,
        );
        expect(find.byType(ReaderSkeleton), findsOneWidget);
        await tester.pump(const Duration(milliseconds: 200));
        expect(
          find.byType(FrostedHeader),
          visible ? findsOneWidget : findsNothing,
        );
        source.ready.complete(fixture.book);
        await fixture.settleReader(tester);
        final chrome = tester.widget<ReaderChromeLayer>(
          find.byKey(const ValueKey('reader-chrome-header')),
        );
        expect(chrome.animation.value, visible ? 1 : 0);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
  testWidgets(
    'failed direct loading exposes navigation and recovery even with hidden chrome',
    (tester) async {
      final state = await LibraryState.load();
      addTearDown(state.dispose);
      final source = _PendingBook();
      await tester.pumpWidget(
        MaterialApp(
          theme: novelTheme(Brightness.light),
          home: ReaderLoaderPage(
            novel: fixture.book,
            state: state,
            repository: source,
          ),
        ),
      );
      await tester.pump();
      source.ready.completeError(StateError('fixture unavailable'));
      await tester.pumpAndSettle();
      expect(find.byType(FrostedHeader), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final (name, size, scale, top) in [
    ('phone', const Size(390, 844), 1.0, 0.0),
    ('cutout-phone', const Size(390, 844), 1.0, 34.0),
    ('compact', const Size(320, 700), 1.6, 0.0),
    ('tablet', const Size(1280, 800), 1.0, 0.0),
  ]) {
    testWidgets(
      'system time/battery stay in status band; chapter and pages share the next row on $name',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        tester.view.padding = FakeViewPadding(top: top, bottom: 20);
        tester.view.viewPadding = tester.view.padding;
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPadding);
        addTearDown(tester.view.resetViewPadding);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final state = await LibraryState.load(), capture = GlobalKey();
        addTearDown(state.dispose);
        await state.setReaderPreferences(
          const ReaderPreferences(hideSystemStatus: true),
        );
        await tester.pumpWidget(
          RepaintBoundary(key: capture, child: fixture.app(state)),
        );
        await fixture.settleReader(tester);
        final status = find.byType(ReaderStatusFooter);
        final retained = tester.state(status);
        void broadcast() => ServicesBinding.instance.channelBuffers.push(
          'org.mewx.wenku8/reader_status',
          const StandardMethodCodec().encodeSuccessEnvelope({
            'time': DateTime(2026, 10, 18, 9, 41).millisecondsSinceEpoch,
            'battery': 71,
            'charging': false,
          }),
          (_) {},
        );
        broadcast();
        await tester.pumpAndSettle();
        for (final mode in ReaderMode.values) {
          await state.setReaderPreferences(
            state.readerPreferences.copyWith(mode: mode),
          );
          await fixture.settleReader(tester);
          expect(tester.state(status), same(retained));
          final time = tester.getRect(
            find.byKey(const ValueKey('reader-status-time')),
          );
          final battery = tester.getRect(
            find.byKey(const ValueKey('reader-status-battery')),
          );
          final title = tester.getRect(
            find.byKey(const ValueKey('reader-chapter-title')),
          );
          final band = tester.getRect(status);
          expect(band.top, 0);
          expect(time.center.dy, closeTo(battery.center.dy, 1));
          expect(time.center.dy, closeTo(band.center.dy, 1));
          expect(time.left, 26);
          expect(battery.right, closeTo(size.width - 26, 1));
          expect(title.top, greaterThan(band.bottom));
          expect(
            find.descendant(
              of: status,
              matching: find.byKey(const ValueKey('reader-page-count')),
            ),
            findsNothing,
          );
          if (mode.paginated) {
            final locationText = find.byKey(
              const ValueKey('reader-page-count'),
            );
            final location = tester.getRect(locationText);
            expect(location.center.dy, closeTo(title.center.dy, 1));
            expect(
              tester
                  .renderObject<RenderParagraph>(
                    find.descendant(
                      of: locationText,
                      matching: find.byType(RichText),
                    ),
                  )
                  .didExceedMaxLines,
              false,
            );
            final paged = tester.widget<ReaderPagedView>(
              find.byType(ReaderPagedView),
            );
            expect(paged.showPageCount, true);
            expect(
              paged.padding.top,
              greaterThanOrEqualTo(
                ReaderStatusFooter.heightFor(tester.element(status)) +
                    state.readerPreferences.marginTop,
              ),
            );
            expect(
              paged.padding.bottom,
              state.readerPreferences.marginBottom + 20,
            );
            paged.controller.pageBy(1);
            await fixture.settleReader(tester);
            expect(find.textContaining('页'), findsWidgets);
          } else {
            expect(
              find.byKey(const ValueKey('reader-page-count')),
              findsNothing,
            );
            final viewport = tester.getRect(
              find.byKey(const ValueKey('reader-scroll-safe-viewport')),
            );
            expect(
              viewport.top,
              closeTo(
                ReaderStatusFooter.heightFor(tester.element(status)) +
                    4 +
                    state.readerPreferences.marginTop,
                1,
              ),
            );
            expect(viewport.bottom, closeTo(size.height - 20, 1));
            expect(
              tester
                  .widget<ReaderEdgeBlur>(
                    find.byType(ReaderEdgeBlur, skipOffstage: false),
                  )
                  .blurBottom,
              false,
            );
            final article = tester.widget(
              find.byKey(const ValueKey('paragraph-0')),
            );
            broadcast();
            await tester.pump();
            expect(
              tester.widget(find.byKey(const ValueKey('paragraph-0'))),
              same(article),
            );
          }
          await captureReview(tester, capture, 'fullscreen-$name-${mode.name}');
          await tester.tapAt(Offset(size.width / 2, size.height / 2));
          await fixture.settleReader(tester);
          final header = tester.getRect(find.byType(ArchiveHeaderBar));
          expect(
            header.top,
            greaterThanOrEqualTo(tester.getRect(status).bottom),
          );
          await tester.tapAt(Offset(size.width / 2, size.height / 2));
          await fixture.settleReader(tester);
          expect(tester.takeException(), isNull);
        }
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
