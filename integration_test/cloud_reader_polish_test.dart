import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:wenku8_flutter/cloud_sources.dart';
import 'package:wenku8_flutter/book_documents.dart';
import 'package:wenku8_flutter/local_books.dart';
import 'dart:convert';
import 'package:wenku8_flutter/native_effects.dart';
import '../test/cloud_library_ui_test.dart' as cloud;
import '../test/reader_polish_test.dart' as reader;
import '../test/reader_incremental_test.dart' as incremental;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  late Directory captureDirectory;
  setUpAll(() async {
    captureDirectory = Directory(
      '${(await getTemporaryDirectory()).path}/cloud-reader-review',
    );
  });
  setUp(() async {
    await NativeEffects.prepare();
    expect(ui.ImageFilter.isShaderFilterSupported, true);
  });
  Future<void> capture(WidgetTester tester, GlobalKey key, String name) async {
    final render =
        key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final image = await render.toImage(
      pixelRatio: tester.view.devicePixelRatio,
    );
    final file = File('${captureDirectory.path}/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(
      (await image.toByteData(
        format: ui.ImageByteFormat.png,
      ))!.buffer.asUint8List(),
    );
    image.dispose();
    // ignore: avoid_print
    print('CLOUD_READER_CAPTURE=${file.path}');
  }

  testWidgets(
    'native cloud vault survives reopen without involving library backup',
    (tester) async {
      final settings = CloudSourceSettings();
      try {
        await settings.save(
          CloudSourceKind.quark,
          const CloudSourceConfig(
            kind: CloudSourceKind.quark,
            cookie: '__puus=isolated-device-fixture',
          ),
        );
        final reopened = CloudSourceSettings();
        await reopened.load();
        expect(reopened.error, isNull);
        expect(
          reopened[CloudSourceKind.quark]!.cookie,
          '__puus=isolated-device-fixture',
        );
        reopened.dispose();
      } finally {
        await settings.save(CloudSourceKind.quark, null);
        settings.dispose();
      }
    },
  );
  cloud.main(capture: capture, configureView: false);
  testWidgets(
    'cloud TXT decoder accepts downloaded books and keeps sync paths confined',
    (tester) async {
      final cache = await getTemporaryDirectory();
      final dir = await Directory(
        '${cache.path}/cloud-book-import',
      ).create(recursive: true);
      final batch = await dir.createTemp('native-');
      final books = LocalBookStore(Directory('${batch.path}/library'));
      await books.load();
      final documents = BookDocuments();
      try {
        final source = File('${batch.path}/book');
        await source.writeAsString('第一章\n来自网盘的完整原书。');
        final text = await documents.decodeText(source.path);
        expect(text, '第一章\n来自网盘的完整原书。');
        final book = await books.import(
          LocalBookInput('云端原书.txt', await source.readAsBytes(), text: text),
        );
        expect(
          await books.chapterContent(book.id, book.chapters.single),
          contains('完整原书'),
        );
        await source.writeAsBytes([0xd6, 0xd0, 0xce, 0xc4]);
        expect(await documents.decodeText(source.path), '中文');
        final outside = File('${cache.path}/not-a-cloud-book');
        await outside.writeAsBytes(utf8.encode('private'));
        try {
          await expectLater(
            documents.decodeText(outside.path),
            throwsA(isA<Exception>()),
          );
        } finally {
          await outside.delete();
        }
      } finally {
        books.dispose();
        await batch.delete(recursive: true);
      }
    },
  );
  reader.main(capture: capture, configureView: false);
  incremental.main(capture: capture, configureView: false);
}
