import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/pages.dart';
import 'package:wenku8_flutter/reader_preferences.dart';
import 'package:wenku8_flutter/reader_selection.dart';
import 'package:wenku8_flutter/reader_vertical_text.dart';
import 'reader_modes_test.dart' show settleReader;

const sentence = '微光穿过书页，故事沿着窗边的风继续。';
final selectionBook = Novel(
  id: 53000,
  title: '选字回归',
  author: '作者',
  genre: '',
  summary: '',
  colors: const [Colors.grey, Colors.white],
  chapters: [
    NovelChapter(
      '第一章',
      List.filled(35, '$sentence然后我们重新翻开下一页。').join('\n\n'),
      id: 1,
    ),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await (FontLoader('SourceHanSerifCN')..addFont(
          rootBundle.load('assets/fonts/SourceHanSerifCN-Regular.otf'),
        ))
        .load();
  });
  for (final mode in ReaderMode.values) {
    for (final indent in [false, true]) {
      testWidgets('$mode Chinese long press, indent=$indent, hidden chrome', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        SharedPreferences.setMockInitialValues({
          'reduceMotion': false,
          'readerChromeVisible': false,
          'readerChromeHintSeen': true,
        });
        final state = await LibraryState.load();
        addTearDown(state.dispose);
        await state.setReaderPreferences(
          ReaderPreferences(mode: mode, indent: indent, justify: true),
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: novelTheme(Brightness.light, fontFamily: 'SourceHanSerifCN'),
            home: ReaderPage(
              novel: selectionBook,
              state: state,
              repository: const DemoNovelRepository(),
              initialChapter: 0,
            ),
          ),
        );
        await settleReader(tester);
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
          final bounds = render
              .getBoxesForSelection(
                TextSelection(
                  baseOffset: 3 + (indent ? 1 : 0),
                  extentOffset: 6 + (indent ? 1 : 0),
                ),
              )
              .first
              .toRect();
          at = render.localToGlobal(bounds.center);
        }
        await tester.longPressAt(at);
        await settleReader(tester);
        final controller = tester
            .widget<ReaderSelection>(find.byType(ReaderSelection))
            .controller;
        expect(controller.quote.text.trim(), sentence);
        expect(
          find.byKey(const ValueKey('reader-selection-copy')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('reader-selection-bookmark')),
          findsOneWidget,
        );
        if (mode == ReaderMode.vertical) {
          final text = find.byType(ReaderVerticalText).first;
          final render = tester.renderObject<RenderReaderVerticalText>(text);
          final length = tester
              .widget<ReaderVerticalText>(text)
              .page
              .text
              .length;
          render.dispatchSelectionEvent(const SelectAllSelectionEvent());
          for (final event in const [
            GranularlyExtendSelectionEvent(
              forward: false,
              isEnd: false,
              granularity: TextGranularity.character,
            ),
            GranularlyExtendSelectionEvent(
              forward: true,
              isEnd: true,
              granularity: TextGranularity.character,
            ),
            DirectionallyExtendSelectionEvent(
              dx: 0,
              isEnd: false,
              direction: SelectionExtendDirection.backward,
            ),
            DirectionallyExtendSelectionEvent(
              dx: 0,
              isEnd: true,
              direction: SelectionExtendDirection.forward,
            ),
          ]) {
            render.dispatchSelectionEvent(event);
            expect(render.getSelection()?.startOffset, 0);
            expect(render.getSelection()?.endOffset, length);
          }
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
}
