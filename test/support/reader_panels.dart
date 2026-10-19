import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenku8_flutter/app_ui.dart';

Finder readerPanelControl(String label) => find
    .descendant(
      of: find.byWidgetPredicate(
        (w) => w is GlassIconButton && w.label == label,
      ),
      matching: find.byType(InkWell),
    )
    .first;

Future<void> openReaderPanel(WidgetTester tester, {String tab = '排版'}) async {
  await tester.tap(readerPanelControl('阅读设置'));
  await tester.pumpAndSettle();
  if (tab != '排版') {
    await tester.tap(find.text(tab));
    await tester.pumpAndSettle();
  }
}

Future<void> openReaderChapterProgress(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('dock-tab-1')));
  await tester.pumpAndSettle();
  await tester.tap(find.text('本章进度'));
  await tester.pumpAndSettle();
}
