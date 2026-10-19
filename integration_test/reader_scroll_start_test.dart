import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:wenku8_flutter/native_effects.dart';
import '../test/reader_scroll_start_test.dart' as cases;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  List<int>? reference;
  setUp(() async {
    await NativeEffects.prepare();
  });
  cases.main(
    capture: (tester, key, name) async {
      final image =
          await (key.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage();
      final pixels = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!.buffer.asUint8List().toList();
      if (name == 'reader-resume-reference') {
        reference = pixels;
      } else {
        expect(reference?.length, pixels.length);
        var maximum = 0;
        for (var i = 0; i < pixels.length; i++) {
          final error = (pixels[i] - reference![i]).abs();
          if (error > maximum) maximum = error;
        }
        // ignore: avoid_print
        print('READER_RESUME_PIXEL_PARITY max_channel_error=$maximum');
        expect(maximum, 0);
      }
      final bytes = (await image.toByteData(
        format: ui.ImageByteFormat.png,
      ))!.buffer.asUint8List();
      image.dispose();
      final directory = Directory(
        '${Directory.systemTemp.path}/reader-start-qa',
      );
      await directory.create(recursive: true);
      final file = File('${directory.path}/$name.png');
      await file.writeAsBytes(bytes);
      // ignore: avoid_print
      print('READER_START_CAPTURE=${file.path}');
    },
  );
}
