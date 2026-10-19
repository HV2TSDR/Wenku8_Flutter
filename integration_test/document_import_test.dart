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
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/local_books.dart';
import 'package:wenku8_flutter/local_book_media.dart';
import 'package:wenku8_flutter/native_effects.dart';
import 'package:wenku8_flutter/offline_cache.dart';
import 'package:wenku8_flutter/offline_repository.dart';
import 'package:wenku8_flutter/pages.dart';
import 'package:wenku8_flutter/reader_content.dart';

/// Optional QA: select EPUB_QA_NAME in Android's document picker on a dedicated
/// test device. Books are supplied locally, never bundled into this test target.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const name = String.fromEnvironment('EPUB_QA_NAME');
  testWidgets(
    'native document picker imports an illustrated EPUB larger than 40 MiB',
    (tester) async {
      await NativeEffects.prepare();
      final selected = BookDocuments().pickBook();
      debugPrint('EPUB_DOCUMENT_PICKER_READY');
      final document = await selected.timeout(const Duration(minutes: 2));
      expect(document?.name, name);
      expect(
        await File(document!.path).length(),
        greaterThan(40 * 1024 * 1024),
      );
      final parent = await Directory(
        '${(await getTemporaryDirectory()).path}/epub-document-qa',
      ).create(recursive: true);
      final root = await parent.createTemp('import-');
      addTearDown(() => root.delete(recursive: true));
      final books = LocalBookStore(Directory('${root.path}/books'));
      addTearDown(books.dispose);
      await books.load();
      final book = await books.importFile(document.name, document.path);
      expect(book.chapters.length, greaterThan(1));
      LocalBookMedia.root = books.directory;
      addTearDown(() => LocalBookMedia.root = null);
      var illustrationCount = 0;
      for (final chapter in book.chapters) {
        illustrationCount += ReaderContent(
          (await books.chapterContent(book.id, chapter)).split('\n\n'),
        ).illustrations.length;
      }
      expect(illustrationCount, greaterThan(0));
      final cover = await LocalBookMedia.load(book.coverUrl!);
      final codec = await ui.instantiateImageCodec(cover, targetWidth: 128);
      final frame = await codec.getNextFrame();
      expect(frame.image.width, 128);
      frame.image.dispose();
      codec.dispose();
      SharedPreferences.setMockInitialValues({'reduceMotion': true});
      final state = await LibraryState.load();
      addTearDown(state.dispose);
      final cache = OfflineCacheStore(Directory('${root.path}/cache'));
      addTearDown(cache.dispose);
      final repository = OfflineNovelRepository(
        remote: const DemoNovelRepository(),
        cache: cache,
        local: books,
      );
      addTearDown(repository.dispose);
      final boundary = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: novelTheme(Brightness.light),
            home: DetailPage(novel: book, state: state, repository: repository),
          ),
        ),
      );
      for (var i = 0; i < 80; i++) {
        await tester.pump(const Duration(milliseconds: 25));
        if (tester
            .widgetList<RawImage>(find.byType(RawImage))
            .any((w) => w.image != null)) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await tester.pumpAndSettle();
      expect(
        tester
            .widgetList<RawImage>(find.byType(RawImage))
            .any((w) => w.image != null),
        isTrue,
      );
      final render =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await render.toImage();
      final capture = File(
        '${(await getTemporaryDirectory()).path}/reader-turn/epub-native-document.png',
      );
      await capture.parent.create(recursive: true);
      await capture.writeAsBytes(
        (await image.toByteData(
          format: ui.ImageByteFormat.png,
        ))!.buffer.asUint8List(),
      );
      image.dispose();
      debugPrint('READER_TURN_CAPTURE=${capture.path}');
      debugPrint(
        'EPUB_NATIVE_IMPORT=${{'title': book.title, 'chapters': book.chapters.length, 'illustrations': illustrationCount}}',
      );
      expect(tester.takeException(), isNull);
    },
    skip: name.isEmpty,
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
