import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/reader_content.dart';
import 'package:wenku8_flutter/reader_page_anchor.dart';
import 'package:wenku8_flutter/reader_paged_view.dart';
import 'package:wenku8_flutter/reader_preferences.dart';
import 'package:wenku8_flutter/reader_reflow.dart';
import 'package:wenku8_flutter/reader_turn_motion.dart';
import 'package:wenku8_flutter/reader_vertical_text.dart';
import 'reader_modes_test.dart' show settleReader;
import 'support/visual_review.dart';

void main({
  bool native = false,
  Future<void> Function(WidgetTester, GlobalKey, String)? capture,
}) {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (!native) setUpAll(loadReviewFonts);
  for (final wide in [false, true]) {
    for (final mode in [ReaderMode.paged, ReaderMode.vertical]) {
      testWidgets(
        '${wide ? 'tablet' : 'phone'} ${mode.name} never paints idle neighbouring text during a turn',
        (tester) async {
          tester.view.physicalSize = Size(wide ? 1318 : 390, wide ? 824 : 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          const style = TextStyle(
            fontFamily: 'Roboto',
            fontSize: 19,
            height: 1.72,
            color: Color(0xff36383b),
          );
          final controller = ReaderPagedController();
          final cache = ReaderGlyphCache();
          addTearDown(cache.dispose);
          final boundary = GlobalKey();
          await tester.pumpWidget(
            RepaintBoundary(
              key: boundary,
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: novelTheme(Brightness.light),
                home: Material(
                  color: const Color(0xfff4f2eb),
                  child: ReaderPagedView(
                    controller: controller,
                    style: style,
                    preferences: ReaderPreferences(mode: mode),
                    title: '书页之间 · 顺序与留白',
                    padding: const EdgeInsets.fromLTRB(26, 56, 26, 40),
                    content: ReaderContent(
                      List.generate(
                        200,
                        (i) =>
                            '第 ${i + 1} 段。风吹过书页，故事沿着阅读的顺序展开。没有提前出现的下一页，也没有重叠的文字。',
                      ),
                    ),
                    onReady: () {},
                    onChanged: () {},
                    onUserScroll: () {},
                    onBoundary: (_) {},
                    pageBuilder: (leaf) => mode == ReaderMode.vertical
                        ? ReaderVerticalText(
                            page: leaf,
                            style: style,
                            glyphCache: cache,
                          )
                        : Stack(
                            children: [
                              for (final (i, fragment)
                                  in leaf.fragments.indexed)
                                Positioned.fromRect(
                                  rect: fragment.rect,
                                  child: ReaderFragmentMotion(
                                    fragment: fragment,
                                    index: i,
                                    count: leaf.fragments.length,
                                    child: Text(fragment.text, style: style),
                                  ),
                                ),
                            ],
                          ),
                  ),
                ),
              ),
            ),
          );
          Element? arriving;
          if (!native) {
            final leaf = find.byKey(const ValueKey('reader-retained-leaf-0'));
            for (var i = 0; i < 100 && leaf.evaluate().isEmpty; i++) {
              await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 2)),
              );
              await tester.pump(const Duration(milliseconds: 1));
            }
            arriving = tester.element(leaf);
            expect(find.byType(ReaderTurnPlaceholder), findsWidgets);
          }
          await settleReader(tester);
          if (arriving != null) {
            expect(
              tester.element(
                find.byKey(const ValueKey('reader-retained-leaf-0')),
              ),
              same(arriving),
              reason:
                  'Completing the initial skeleton handoff retains the laid-out article.',
            );
            expect(find.byType(ReaderTurnPlaceholder), findsNothing);
          }
          void check() {
            final anchors = find.byType(ReaderPageAnchor).evaluate().toList();
            expect(anchors, isNotEmpty);
            for (final element in anchors) {
              final anchor = element.widget as ReaderPageAnchor;
              final scopes = find
                  .descendant(
                    of: find.byElementPredicate((e) => e == element),
                    matching: find.byType(ReaderTurnScope),
                  )
                  .evaluate()
                  .map((e) => e.widget as ReaderTurnScope)
                  .toList();
              if (anchor.visible &&
                  anchor.index !=
                      controller.page ~/ controller.pagesPerSpread) {
                expect(
                  scopes.any((s) => s.enabled),
                  true,
                  reason:
                      'A retained neighbour cannot paint until its turn scope is ready.',
                );
              }
            }
            final visible = anchors
                .where((e) => (e.widget as ReaderPageAnchor).visible)
                .length;
            expect(visible, inInclusiveRange(1, 2));
          }

          check();
          controller.pageBy(1);
          await tester.pump();
          check();
          for (var frame = 0; frame < 40; frame++) {
            await tester.pump(const Duration(milliseconds: 16));
            check();
          }
          await tester.pumpAndSettle();
          check();
          final view = find.byType(PageView);
          final gesture = await tester.startGesture(tester.getCenter(view));
          final dx = mode == ReaderMode.vertical ? 1.0 : -1.0;
          for (final distance in [4.0, 14.0, 90.0, -45.0, -63.0]) {
            await gesture.moveBy(Offset(distance * dx, 0));
            await tester.pump();
            check();
            await tester.pump(const Duration(milliseconds: 16));
            check();
          }
          await gesture.up();
          await tester.pumpAndSettle();
          check();
          final held = await tester.startGesture(tester.getCenter(view));
          final width = tester.getSize(view).width;
          await held.moveBy(Offset(width * .34 * dx, 0));
          await tester.pump();
          await tester.pump();
          check();
          final incoming = tester
              .widgetList<ReaderTurnScope>(find.byType(ReaderTurnScope))
              .where((s) => s.enabled && !s.outgoing)
              .toList();
          expect(incoming.first.animation.value, inExclusiveRange(.2, .4));
          if (wide) {
            expect(
              incoming.firstWhere((s) => s.slot == 1).progressFor(0, 10),
              0,
            );
          }
          if (capture != null) {
            await capture(
              tester,
              boundary,
              'visibility-${wide ? 'tablet' : 'phone'}-${mode.name}-first-leaf',
            );
          }
          await held.moveBy(Offset(width * .36 * dx, 0));
          await tester.pump();
          await tester.pump();
          check();
          if (capture != null) {
            await capture(
              tester,
              boundary,
              'visibility-${wide ? 'tablet' : 'phone'}-${mode.name}-second-leaf',
            );
          } else {
            await captureReview(
              tester,
              boundary,
              'visibility-${wide ? 'tablet' : 'phone'}-${mode.name}',
            );
          }
          await held.moveBy(Offset(-width * .65 * dx, 0));
          await tester.pump(const Duration(milliseconds: 200));
          await held.up();
          await tester.pumpAndSettle();
          check();
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }
}
