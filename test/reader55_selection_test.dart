import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/listening/controller.dart';
import 'package:wenku8_flutter/listening/store.dart';
import 'package:wenku8_flutter/listening/widgets.dart';
import 'package:wenku8_flutter/pages.dart';
import 'package:wenku8_flutter/reader_paged_view.dart';
import 'package:wenku8_flutter/reader_preferences.dart';
import 'package:wenku8_flutter/reader_selection.dart';
import 'package:wenku8_flutter/reader_vertical_text.dart';
import 'package:wenku8_flutter/reader_volume_illustrations.dart';
import 'reader53_selection_test.dart' show selectionBook;
import 'reader_modes_test.dart' show settleReader;
import 'support/listening_fixture.dart';
import 'support/visual_review.dart';

Offset selectionPoint(WidgetTester tester, ReaderMode mode) {
  if (mode == ReaderMode.vertical) {
    for (final element in find.byType(ReaderVerticalText).evaluate()) {
      final render = element.renderObject! as RenderReaderVerticalText;
      final text = element.widget as ReaderVerticalText;
      for (final glyph in text.page.glyphs) {
        final point = render.localToGlobal(glyph.rect.center);
        if (glyph.sourceStart >= 3 &&
            point.dy > 180 &&
            point.dy < 550 &&
            point.dx > 30 &&
            point.dx < 360) {
          return point;
        }
      }
    }
  } else {
    for (final element in find.byType(RichText).evaluate()) {
      final render = element.renderObject!;
      if (render is! RenderParagraph ||
          !render.text.toPlainText().contains('微光穿过')) {
        continue;
      }
      final at = render.text.toPlainText().indexOf('微光穿过') + 3;
      final boxes = render.getBoxesForSelection(
        TextSelection(baseOffset: at, extentOffset: at + 1),
      );
      if (boxes.isEmpty) continue;
      final point = render.localToGlobal(boxes.first.toRect().center);
      if (point.dy > 180 && point.dy < 650 && point.dx > 30 && point.dx < 360) {
        return point;
      }
    }
  }
  throw StateError('No visible prose glyph in $mode');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadReviewFonts);
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('org.mewx.wenku8/reader_status'),
          (_) async => null,
        );
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('org.mewx.wenku8/reader_status'),
          null,
        );
  });
  for (final (mode, effect) in [
    (ReaderMode.scroll, ReaderPageEffect.staggered),
    for (final mode in [ReaderMode.paged, ReaderMode.vertical])
      for (final effect in ReaderPageEffect.values) (mode, effect),
  ]) {
    testWidgets(
      '${mode.name}/${effect.name} long press after chrome reflow selects and exposes copy/bookmark',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        SharedPreferences.setMockInitialValues({
          'readerChromeVisible': true,
          'readerChromeHintSeen': true,
        });
        final state = await LibraryState.load();
        addTearDown(state.dispose);
        String? copied;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              copied = (call.arguments as Map)['text'] as String;
            }
            if (call.method == 'Clipboard.getData') return {'text': copied};
            if (call.method == 'Clipboard.hasStrings') {
              return {'value': copied?.isNotEmpty == true};
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
        await state.setReaderPreferences(
          ReaderPreferences(
            mode: mode,
            pageEffect: effect,
            indent: true,
            justify: true,
            hideSystemStatus: true,
          ),
        );
        final listening = ListeningController(
          repository: const DemoNovelRepository(),
          audio: FakeSpeechAudio(),
          store: ListeningStore(await SharedPreferences.getInstance()),
          outputFactory: (_) async => FakeListeningOutput(),
        );
        final capture = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: capture,
            child: MaterialApp(
              theme: novelTheme(Brightness.light),
              builder: (context, child) =>
                  ListeningScope(controller: listening, child: child!),
              home: ReaderPage(
                novel: selectionBook,
                state: state,
                repository: const DemoNovelRepository(),
                initialChapter: 0,
              ),
            ),
          ),
        );
        await settleReader(tester);
        debugPrint('SELECTION55 $mode mounted');
        await tester.tapAt(const Offset(195, 422));
        await settleReader(tester);
        debugPrint('SELECTION55 $mode chrome hidden');
        if (mode.paginated) {
          tester
              .widget<ReaderPagedView>(find.byType(ReaderPagedView))
              .controller
              .pageBy(1);
          await settleReader(tester);
        }
        await tester.longPressAt(selectionPoint(tester, mode));
        debugPrint('SELECTION55 $mode long pressed');
        await settleReader(tester);
        debugPrint('SELECTION55 $mode selected');
        final selection = tester
            .widget<ReaderSelection>(find.byType(ReaderSelection))
            .controller;
        expect(selection.value, true);
        expect(selection.quote.text.trim(), isNotEmpty);
        expect(
          selection.key.currentState!.selectableRegion.selectionEndpoints,
          hasLength(2),
        );
        expect(
          find.byKey(const ValueKey('reader-selection-copy')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('reader-selection-bookmark')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('reader-selection-illustrations')),
          findsOneWidget,
        );
        await captureReview(
          tester,
          capture,
          'selection-after-reflow-${mode.name}-${effect.name}',
        );
        final text = selection.quote.text;
        await tester.tap(
          find
              .descendant(
                of: find.byKey(const ValueKey('reader-selection-copy')),
                matching: find.byType(InkWell),
              )
              .first,
        );
        await tester.pumpAndSettle();
        debugPrint('SELECTION55 $mode copied');
        expect(copied, text);
        expect(selection.value, false);
        if (effect == ReaderPageEffect.cover) {
          await tester.longPressAt(selectionPoint(tester, mode));
          await settleReader(tester);
          final quote = selection.quote;
          expect(quote.anchor, isNotNull);
          await tester.tap(
            find
                .descendant(
                  of: find.byKey(const ValueKey('reader-selection-bookmark')),
                  matching: find.byType(InkWell),
                )
                .first,
          );
          await settleReader(tester);
          final saved = state.bookmarksFor(selectionBook.id).single;
          expect(saved.quote, quote.text);
          expect(saved.position.paragraphIndex, quote.anchor!.paragraph);
          expect(saved.position.textOffset, quote.anchor!.offset);
          expect(selection.value, false);
        }
        if (effect == ReaderPageEffect.staggered) {
          await tester.longPressAt(selectionPoint(tester, mode));
          await settleReader(tester);
          await tester.tap(
            find
                .descendant(
                  of: find.byKey(
                    const ValueKey('reader-selection-illustrations'),
                  ),
                  matching: find.byType(InkWell),
                )
                .first,
          );
          await settleReader(tester);
          expect(find.byType(ReaderVolumeIllustrationsPage), findsOneWidget);
          expect(find.text('本卷没有找到插图。'), findsOneWidget);
          expect(selection.value, false);
          await tester.binding.handlePopRoute();
          await settleReader(tester);
          expect(find.byType(ReaderSelection), findsOneWidget);
          expect(state.readerChromeVisible, false);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        debugPrint('SELECTION55 $mode unmounted');
        final closing = listening.dispose();
        await tester.pump();
        await tester.runAsync(listeningMicrotasks);
        await tester.pump();
        await closing;
      },
    );
  }
}
