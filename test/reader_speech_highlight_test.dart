import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/listening/controller.dart';
import 'package:wenku8_flutter/listening/models.dart';
import 'package:wenku8_flutter/listening/store.dart';
import 'package:wenku8_flutter/listening/widgets.dart';
import 'package:wenku8_flutter/pages.dart';
import 'package:wenku8_flutter/reader_preferences.dart';
import 'package:wenku8_flutter/reader_speech_highlight.dart';
import 'package:wenku8_flutter/reader_vertical_text.dart';

import 'reader_modes_test.dart' show settleReader;
import 'support/listening_fixture.dart';
import 'support/visual_review.dart';

const _paragraphs = [
  '清晨，窗边传来翻动书页的声音。她把书签放在桌面上，准备继续昨天的故事。',
  '「就从这一段开始吧。」正在朗读的段落应当一眼就能找到，底色清楚而温和，文字仍然保持原来的排版。',
  '风拂过窗帘，下一段静静地等待。暂停和继续都不应该让高亮突然消失，切换段落时也不应改变文字的位置。',
];

void main({
  bool native = false,
  Future<void> Function(WidgetTester, GlobalKey, String)? capture,
}) {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (!native) setUpAll(loadReviewFonts);
  for (final brightness in Brightness.values) {
    for (final mode in ReaderMode.values) {
      testWidgets(
        '${mode.name} ${brightness.name} listening highlight remains clear while paused',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = const Size(390, 844);
          tester.view.padding = const FakeViewPadding(top: 28, bottom: 24);
          tester.view.viewPadding = tester.view.padding;
          addTearDown(tester.view.resetDevicePixelRatio);
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetPadding);
          addTearDown(tester.view.resetViewPadding);
          SharedPreferences.setMockInitialValues({'reduceMotion': true});
          final library = await LibraryState.load();
          await library.setReaderPreferences(ReaderPreferences(mode: mode));
          addTearDown(library.dispose);
          final book = Novel(
            id: 974501,
            title: '听书高亮',
            author: '',
            genre: '',
            summary: '',
            colors: const [Colors.grey, Colors.black],
            chapters: [NovelChapter('第一章 · 从这一段继续', _paragraphs.join('\n\n'))],
          );
          final controller = ListeningController(
            repository: const DemoNovelRepository(),
            audio: FakeSpeechAudio(),
            store: ListeningStore(await SharedPreferences.getInstance()),
            outputFactory: (_) async => FakeListeningOutput(),
          );
          void state(ListeningPhase phase) {
            controller.snapshot.value = ListeningSnapshot(
              novel: book,
              chapter: 0,
              segments: [
                SpeechSegment(1, 0, _paragraphs[1].length, _paragraphs[1]),
              ],
              phase: phase,
              playRequested: phase == ListeningPhase.playing,
            );
          }

          state(ListeningPhase.playing);
          final boundary = GlobalKey();
          await tester.pumpWidget(
            RepaintBoundary(
              key: boundary,
              child: ListeningScope(
                controller: controller,
                child: MaterialApp(
                  debugShowCheckedModeBanner: false,
                  theme: novelTheme(brightness),
                  home: ReaderPage(
                    novel: book,
                    state: library,
                    repository: const DemoNovelRepository(),
                    initialChapter: 0,
                  ),
                ),
              ),
            ),
          );
          await settleReader(tester);
          final body = find.byKey(const ValueKey('reader-article-boundary'));
          final palette = ReaderSpeechHighlightStyle.of(tester.element(body));
          expect(
            palette.fill.a,
            greaterThanOrEqualTo(brightness == Brightness.dark ? .21 : .11),
          );
          if (mode == ReaderMode.vertical) {
            final render = tester.renderObject<RenderReaderVerticalText>(
              find.byType(ReaderVerticalText).first,
            );
            expect(render.debugSpeechBands, isNotEmpty);
            expect(
              render.debugSpeechBands.any((rect) => rect.height > 100),
              true,
              reason:
                  'A spoken column has a continuous background, not isolated glyph boxes.',
            );
          } else {
            expect(
              find.byKey(const ValueKey('listening-highlight-1')),
              findsOneWidget,
            );
          }
          final before = tester.getRect(body);
          state(ListeningPhase.paused);
          await tester.pumpAndSettle();
          expect(tester.getRect(body), before);
          if (mode == ReaderMode.vertical) {
            expect(
              tester
                  .renderObject<RenderReaderVerticalText>(
                    find.byType(ReaderVerticalText).first,
                  )
                  .debugSpeechBands,
              isNotEmpty,
            );
          }
          if (capture == null) {
            await captureReview(
              tester,
              boundary,
              'speech-${mode.name}-${brightness.name}',
            );
          } else {
            await capture(
              tester,
              boundary,
              'speech-${mode.name}-${brightness.name}',
            );
          }
          expect(tester.binding.transientCallbackCount, 0);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          final closing = controller.dispose();
          for (var i = 0; i < 8; i++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 1)),
            );
            await tester.pump(const Duration(milliseconds: 16));
          }
          await closing;
        },
      );
    }
  }
}
