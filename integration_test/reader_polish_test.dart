import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:wenku8_flutter/native_effects.dart';
import '../test/reader_polish_test.dart' as polish;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    await NativeEffects.prepare();
    expect(ui.ImageFilter.isShaderFilterSupported, isTrue);
  });
  polish.main(
    configureView: false,
    capture: (tester, key, name) async {
      final render =
          key.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final image = await render.toImage(
        pixelRatio: tester.view.devicePixelRatio,
      );
      final file = File(
        '${(await getTemporaryDirectory()).path}/reader-polish/$name.png',
      );
      await file.parent.create(recursive: true);
      await file.writeAsBytes(
        (await image.toByteData(
          format: ui.ImageByteFormat.png,
        ))!.buffer.asUint8List(),
      );
      image.dispose();
      // ignore: avoid_print
      print('READER_POLISH_CAPTURE=${file.path}');
    },
  );
}
