import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:wenku8_flutter/native_effects.dart';

import '../test/glass_controls_test.dart' as controls;
import '../test/reader_book_layout_test.dart' as book;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    await NativeEffects.prepare();
    expect(ui.ImageFilter.isShaderFilterSupported, isTrue);
  });
  Future<void> capture(WidgetTester tester, GlobalKey key, String name) async {
    final render =
        key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final image = await render.toImage(
      pixelRatio: tester.view.devicePixelRatio,
    );
    final file = File(
      '${(await getTemporaryDirectory()).path}/glass-controls/$name.png',
    );
    await file.parent.create(recursive: true);
    await file.writeAsBytes(
      (await image.toByteData(
        format: ui.ImageByteFormat.png,
      ))!.buffer.asUint8List(),
    );
    image.dispose();
    debugPrint('GLASS_CONTROL_CAPTURE=${file.path}');
  }

  controls.main(native: true, capture: capture);
  book.main(native: true, capture: capture);
}
