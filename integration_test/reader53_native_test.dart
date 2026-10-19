import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/pages.dart';
import 'package:wenku8_flutter/reader_illustrations.dart';
import 'package:wenku8_flutter/reader_paged_view.dart';
import 'package:wenku8_flutter/reader_preferences.dart';
import 'package:wenku8_flutter/reader_selection.dart';
import 'package:wenku8_flutter/reader_status.dart';
import 'package:wenku8_flutter/reader_vertical_text.dart';

class _Source extends DemoNovelRepository {
  @override
  Future<String> chapterContent(int id, NovelChapter chapter) async =>
      chapter.content;
}

Future<void> settleLayout(WidgetTester tester) async {
  await tester.pumpAndSettle(const Duration(milliseconds: 16));
  final paged = find.byType(ReaderPagedView);
  for (
    var n = 0;
    n < 200 &&
        paged.evaluate().isNotEmpty &&
        !tester.widget<ReaderPagedView>(paged).controller.ready;
    n++
  ) {
    await tester.pump(const Duration(milliseconds: 16));
  }
  await tester.pumpAndSettle(const Duration(milliseconds: 16));
  if (paged.evaluate().isNotEmpty) {
    expect(tester.widget<ReaderPagedView>(paged).controller.ready, isTrue);
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  Future<void> checkpoint(String name) async {
    debugPrint('READER53_NATIVE_READY $name');
    // Leave a deterministic inspection window for the emulator-only capture
    // runner. Live test bindings intentionally do not forward device touches.
    await Future<void>.delayed(const Duration(seconds: 8));
  }

  Widget app(Widget home) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: novelTheme(Brightness.light),
    home: home,
  );

  testWidgets(
    'native image canvas, immersive footer and long-press selection across all reading modes',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'readerChromeVisible': false,
        'readerChromeHintSeen': true,
        'reduceMotion': false,
      });
      final state = await LibraryState.load();
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawRect(
        const Rect.fromLTWH(0, 0, 300, 450),
        Paint()..color = const Color(0xFF647D88),
      );
      canvas.drawRect(
        const Rect.fromLTWH(12, 12, 276, 426),
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3,
      );
      final picture = recorder.endRecording();
      final image = await picture.toImage(300, 450);
      final bytes = (await image.toByteData(
        format: ui.ImageByteFormat.png,
      ))!.buffer.asUint8List();
      image.dispose();
      picture.dispose();
      final cache = ReaderIllustrationCache(request: (_) async => bytes);
      await tester.pumpWidget(
        app(
          ReaderIllustrationGallery(
            urls: const ['https://pic.wenku8.com/reader53-fixture.png'],
            initialUrl: 'https://pic.wenku8.com/reader53-fixture.png',
            cache: cache,
          ),
        ),
      );
      for (
        var n = 0;
        n < 100 &&
            !tester
                .widgetList<RawImage>(find.byType(RawImage))
                .any((w) => w.image != null);
        n++
      ) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.pumpAndSettle();
      final viewer = find.byType(InteractiveViewer).first;
      final controller = tester
          .widget<InteractiveViewer>(viewer)
          .transformationController!;
      expect(controller.value.entry(0, 0), closeTo(.9, .001));
      await checkpoint('IMAGE_FITTED');
      final size = tester.getSize(viewer);
      controller.value = Matrix4.identity()
        ..translateByDouble(-size.width / 2, -size.height / 2, 0, 1)
        ..scaleByDouble(2, 2, 1, 1);
      await tester.pumpAndSettle();
      await checkpoint('IMAGE_ZOOMED');

      const sentence = '微光穿过书页，故事沿着窗边的风继续。';
      final book = Novel(
        id: 53001,
        title: '阅读交互验证',
        author: '验证样本',
        genre: '',
        summary: '',
        colors: const [Colors.grey, Colors.white],
        chapters: [
          NovelChapter(
            '第一章',
            List.filled(45, '$sentence然后我们重新翻开下一页。').join('\n\n'),
            id: 5300101,
          ),
        ],
      );
      await state.setReaderPreferences(
        const ReaderPreferences(
          hideSystemStatus: true,
          indent: true,
          justify: true,
        ),
      );
      await tester.pumpWidget(
        app(
          ReaderPage(
            novel: book,
            state: state,
            repository: _Source(),
            initialChapter: 0,
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (
        var n = 0;
        n < 80 && find.byKey(const ValueKey('paragraph-0')).evaluate().isEmpty;
        n++
      ) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.pumpAndSettle();
      expect(find.byType(ReaderStatusFooter), findsOneWidget);
      await checkpoint('READER_STATUS_HIDDEN');
      for (final mode in ReaderMode.values) {
        await state.setReaderPreferences(
          state.readerPreferences.copyWith(mode: mode),
        );
        await settleLayout(tester);
        await tester.tapAt(
          tester.getCenter(find.byKey(const ValueKey('reader-content-tap'))),
        );
        await settleLayout(tester);
        await tester.tapAt(
          tester.getCenter(find.byKey(const ValueKey('reader-content-tap'))),
        );
        await settleLayout(tester);
        late Offset at;
        if (mode == ReaderMode.vertical) {
          final text = find.byType(ReaderVerticalText).first;
          final glyph = tester
              .widget<ReaderVerticalText>(text)
              .page
              .glyphs
              .firstWhere((g) => g.paragraph == 0 && g.sourceStart >= 3);
          at = tester
              .renderObject<RenderReaderVerticalText>(text)
              .localToGlobal(glyph.rect.center);
        } else {
          final text = find.textContaining('微光穿过', findRichText: true).first;
          final render = tester.renderObject<RenderParagraph>(text);
          at = render.localToGlobal(
            render
                .getBoxesForSelection(
                  const TextSelection(baseOffset: 4, extentOffset: 7),
                )
                .first
                .toRect()
                .center,
          );
        }
        await tester.longPressAt(at);
        await tester.pumpAndSettle();
        final selection = tester
            .widget<ReaderSelection>(find.byType(ReaderSelection))
            .controller;
        if (selection.quote.text.isEmpty) {
          debugPrint('READER53_SELECTION_MISS ${mode.name} at=$at');
          await checkpoint('SELECTION_FAILURE_${mode.name.toUpperCase()}');
        }
        expect(selection.quote.text.trim(), sentence);
        expect(
          find.byKey(const ValueKey('reader-selection-copy')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('reader-selection-bookmark')),
          findsOneWidget,
        );
        if (mode == ReaderMode.vertical) await checkpoint('VERTICAL_SELECTION');
        await tester.tap(find.byKey(const ValueKey('reader-selection-copy')));
        for (var n = 0; n < 100 && selection.value; n++) {
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(selection.value, false);
        debugPrint('READER53_NATIVE_SELECTION_OK ${mode.name}');
      }
      await tester.pumpWidget(
        app(const Scaffold(body: Center(child: Text('阅读器已退出')))),
      );
      await tester.pumpAndSettle();
      await checkpoint('STATUS_RESTORED');
      state.dispose();
      cache.clearMemory();
      expect(tester.takeException(), isNull);
      debugPrint(
        'READER53_NATIVE_COMPLETE image=ok status_footer=ok selection=3_modes',
      );
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
