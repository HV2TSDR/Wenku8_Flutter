import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/legacy_wenku_repository.dart';
import 'package:wenku8_flutter/native_effects.dart';

import '../test/author_works_test.dart' as author;
import '../test/reader_turn_motion_test.dart' as reader;
import '../test/reader_turn_visibility_test.dart' as visibility;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUp(NativeEffects.prepare);
  Future<void> capture(WidgetTester tester, GlobalKey key, String name) async {
    final render =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    if (render.debugNeedsPaint) tester.binding.rootPipelineOwner.flushPaint();
    final image = await render.toImage(pixelRatio: 1);
    final safeName = name
        .replaceAll('320', 'compact')
        .replaceAll('390', 'phone')
        .replaceAll('1280', 'tablet');
    final file = File(
      '${(await getTemporaryDirectory()).path}/ui-refinement/$safeName.png',
    );
    await file.parent.create(recursive: true);
    await file.writeAsBytes(
      (await image.toByteData(
        format: ui.ImageByteFormat.png,
      ))!.buffer.asUint8List(),
    );
    image.dispose();
    debugPrint('UI_REFINEMENT_CAPTURE=${file.path}');
  }

  reader.main(native: true, capture: capture);
  visibility.main(native: true, capture: capture);
  author.main(native: true, capture: capture);
  testWidgets(
    'author works reads real public author metadata through the Android bridge',
    (tester) async {
      final page = await LegacyWenkuRepository().authorPage('水泽梦');
      expect(page.items, isNotEmpty);
      expect(
        page.items.every((book) => sameNovelAuthor(book.author, '水泽梦')),
        isTrue,
      );
      debugPrint(
        'AUTHOR_PUBLIC_WORKS items=${page.items.length} total=${page.totalItems} ids=${page.items.map((b) => b.id).join(',')}',
      );
    },
  );
}
