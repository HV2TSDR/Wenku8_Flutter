import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenku8_flutter/reader_find.dart';
import 'package:wenku8_flutter/reader_text.dart';
import 'package:wenku8_flutter/reader_selection.dart';
import 'package:wenku8_flutter/reader_content.dart';
import 'package:wenku8_flutter/reader_pagination.dart';
import 'package:wenku8_flutter/reader_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const style = TextStyle(
    fontFamily: 'SourceHanSerifCN',
    fontSize: 19,
    height: 1.72,
    inherit: false,
  );
  final prose = '这是一段可以同时首行缩进与两端对齐的测试文字。' * 18;
  setUpAll(() async {
    await (FontLoader('SourceHanSerifCN')..addFont(
          rootBundle.load('assets/fonts/SourceHanSerifCN-Regular.otf'),
        ))
        .load();
  });
  for (final scale in [1.0, 1.6]) {
    for (final align in [TextAlign.start, TextAlign.justify]) {
      testWidgets('fixed two-em first line in $align at scale $scale', (
        tester,
      ) async {
        final match = ValueNotifier<ReaderMatch?>(null);
        addTearDown(match.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(scale)),
              child: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 300,
                  child: ReaderHighlightText(
                    index: 0,
                    text: prose,
                    match: match,
                    style: style,
                    indent: true,
                    textAlign: align,
                  ),
                ),
              ),
            ),
          ),
        );
        final render = tester.renderObject<RenderParagraph>(
          find.descendant(
            of: find.byKey(const ValueKey('paragraph-0')),
            matching: find.byType(RichText),
          ),
        );
        final first = render
            .getBoxesForSelection(
              const TextSelection(
                baseOffset: readerIndentLength,
                extentOffset: readerIndentLength + 1,
              ),
            )
            .first;
        expect(first.left, closeTo(38 * scale, .5));
        match.value = const ReaderMatch(0, 0, 4);
        await tester.pump();
        final highlighted = tester.renderObject<RenderParagraph>(
          find.descendant(
            of: find.byKey(const ValueKey('paragraph-0')),
            matching: find.byType(RichText),
          ),
        );
        expect(
          highlighted
              .getBoxesForSelection(
                const TextSelection(baseOffset: 1, extentOffset: 2),
              )
              .first
              .left,
          closeTo(first.left, .1),
        );
        expect(tester.takeException(), isNull);
      });
    }
  }
  testWidgets(
    'indented justified sentence selection keeps exact quote anchors',
    (tester) async {
      final controller = ReaderSelectionController();
      final match = ValueNotifier<ReaderMatch?>(null);
      addTearDown(controller.dispose);
      addTearDown(match.dispose);
      const text = '第一句要保留完整。第二句也是完整的句子。';
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 300,
                child: ReaderSelection(
                  controller: controller,
                  child: ReaderSelectionFragment(
                    controller: controller,
                    text: text,
                    selectableOffset: readerIndentLength,
                    anchorForOffset: (offset) =>
                        (paragraph: 0, offset: offset.clamp(0, text.length)),
                    child: ReaderHighlightText(
                      index: 0,
                      text: text,
                      match: match,
                      style: style,
                      indent: true,
                      textAlign: TextAlign.justify,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final render = tester.renderObject<RenderParagraph>(
        find.descendant(
          of: find.byKey(const ValueKey('paragraph-0')),
          matching: find.byType(RichText),
        ),
      );
      for (final start in [0, text.indexOf('第二句')]) {
        final box = render
            .getBoxesForSelection(
              TextSelection(
                baseOffset: start + readerIndentLength + 1,
                extentOffset: start + readerIndentLength + 2,
              ),
            )
            .first;
        await tester.longPressAt(render.localToGlobal(box.toRect().center));
        await tester.pumpAndSettle();
        expect(controller.quote.text, start == 0 ? '第一句要保留完整。' : '第二句也是完整的句子。');
        expect(controller.quote.anchor, (paragraph: 0, offset: start));
        controller.clear();
        await tester.pumpAndSettle();
      }
      expect(tester.takeException(), isNull);
    },
  );
  test(
    'pagination uses the same indent box and source offsets remain exact',
    () async {
      final content = ReaderContent([prose, prose]);
      final pages = await paginateReader(
        content: content,
        preferences: const ReaderPreferences(
          mode: ReaderMode.paged,
          indent: true,
          justify: true,
        ),
        size: const Size(300, 400),
        style: style,
        scaler: TextScaler.noScaling,
        current: () => true,
      );
      expect(pages, isNotNull);
      for (var paragraph = 0; paragraph < 2; paragraph++) {
        final fragments = pages!.pages
            .expand((p) => p.fragments)
            .where((f) => f.paragraph == paragraph)
            .toList();
        expect(fragments.first.start, 0);
        expect(fragments.first.indent, true);
        expect(fragments.skip(1).every((f) => !f.indent), true);
        expect(fragments.map((f) => f.text).join(), prose);
      }
    },
  );
}
