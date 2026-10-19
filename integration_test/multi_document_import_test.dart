import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/book_documents.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/local_books.dart';
import 'package:wenku8_flutter/local_import_batch.dart';
import 'package:wenku8_flutter/local_import_review.dart';
import 'package:wenku8_flutter/native_effects.dart';

/// Optional private QA. Supply books to a dedicated emulator's Downloads and
/// select them together in SAF; no book data is bundled into the test target.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const count = int.fromEnvironment('BATCH_QA_COUNT');
  const chapters = int.fromEnvironment('BATCH_QA_CHAPTERS');
  testWidgets(
    'native multi-selection imports a complete batch before confirming its series',
    (tester) async {
      await NativeEffects.prepare();
      final documents = BookDocuments();
      final pending = documents.pickBooks();
      debugPrint('EPUB_BATCH_PICKER_READY');
      final selected = await pending.timeout(const Duration(minutes: 2));
      expect(selected.length, count);
      expect(selected.every((s) => s.error == null), true);
      expect(selected.map((s) => s.path).toSet().length, count);
      final root = await (await getTemporaryDirectory()).createTemp(
        'batch-qa-',
      );
      addTearDown(() => root.delete(recursive: true));
      final books = LocalBookStore(Directory('${root.path}/books'));
      addTearDown(books.dispose);
      await books.load();
      final report = await importLocalBatch(
        selections: selected,
        books: books,
        importFile: (name, path) => books.importFile(name, path),
      );
      expect(report.added, count);
      expect(report.failures, isEmpty);
      expect(books.series, isEmpty);
      await documents.releaseBooks(selected);
      for (final source in selected) {
        expect(await File(source.path!).exists(), false);
      }
      SharedPreferences.setMockInitialValues({'reduceMotion': true});
      final library = await LibraryState.load();
      addTearDown(library.dispose);
      final boundary = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: novelTheme(Brightness.light),
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => LocalImportReview(
                        books: books,
                        library: library,
                        report: report,
                      ),
                    ),
                  ),
                  child: const Text('查看批量结果'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('查看批量结果'));
      await tester.pumpAndSettle();
      final image =
          await (boundary.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage();
      final file = File(
        '${(await getTemporaryDirectory()).path}/reader-turn/epub-native-batch.png',
      );
      await file.parent.create(recursive: true);
      await file.writeAsBytes(
        (await image.toByteData(
          format: ui.ImageByteFormat.png,
        ))!.buffer.asUint8List(),
      );
      image.dispose();
      debugPrint('READER_TURN_CAPTURE=${file.path}');
      final confirm = find.byKey(const ValueKey('import-confirm-merge'));
      await tester.scrollUntilVisible(
        confirm,
        200,
        scrollable: find
            .descendant(
              of: find.byType(LocalImportReview),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      await tester.tap(confirm);
      for (
        var i = 0;
        i < 200 && find.byType(LocalImportReview).evaluate().isNotEmpty;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 25));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(find.byType(LocalImportReview), findsNothing);
      expect(books.series.single.volumes.length, count);
      if (chapters > 0) {
        expect(books.books.single.chapters.length, chapters);
      }
      debugPrint(
        'EPUB_NATIVE_BATCH=volumes:${books.series.single.volumes.length},chapters:${books.books.single.chapters.length},temporarySourcesReleased:true',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
    skip: count < 2,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
