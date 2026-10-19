import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/pages.dart';
import 'reader_modes_test.dart' show settleReader;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'system back uses a transient double-back notice; toolbar exits directly',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'readerChromeVisible': true,
        'readerChromeHintSeen': true,
        'reduceMotion': true,
      });
      final state = await LibraryState.load();
      addTearDown(state.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: novelTheme(Brightness.light),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => ReaderPage(
                      novel: demoNovels.first,
                      state: state,
                      repository: const DemoNovelRepository(),
                      initialChapter: 0,
                    ),
                  ),
                ),
                child: const Text('打开阅读'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开阅读'));
      await settleReader(tester);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('退出阅读？'), findsNothing);
      expect(find.text('再滑动一次退出阅读'), findsOneWidget);
      expect(find.byType(ReaderPage), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(ReaderPage), findsNothing);
      expect(find.text('再滑动一次退出阅读'), findsNothing);
      await tester.tap(find.text('打开阅读'));
      await settleReader(tester);
      await tester.tap(
        find.byWidgetPredicate(
          (w) => w is GlassIconButton && w.label == '返回详情',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('退出阅读？'), findsNothing);
      expect(find.byType(ReaderPage), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
