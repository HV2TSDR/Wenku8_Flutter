import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:wenku8_flutter/app_language.dart';
import 'package:wenku8_flutter/local_platform.dart';
import 'package:wenku8_flutter/reader_content.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native image save publishes original pixels and rejects invalid data',
    (tester) async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawRect(
        const Rect.fromLTWH(0, 0, 200, 300),
        Paint()..color = Colors.blueGrey,
      );
      final picture = recorder.endRecording();
      final image = await picture.toImage(200, 300);
      final bytes = (await image.toByteData(
        format: ui.ImageByteFormat.png,
      ))!.buffer.asUint8List();
      image.dispose();
      picture.dispose();
      expect(
        await LocalPlatform.saveBookImage(bytes, 'reader50-save-fixture'),
        true,
      );
      await expectLater(
        LocalPlatform.saveBookImage(Uint8List.fromList([1, 2, 3]), 'invalid'),
        throwsA(isA<PlatformException>()),
      );
      debugPrint(
        'READER50_NATIVE_IMAGE original_bytes=${bytes.length} width=200 height=300',
      );
    },
  );
  testWidgets(
    'large traditional chapter conversion yields the UI and keeps anchors',
    (tester) async {
      await ChineseText.prepare();
      final source = ReaderContent(
        List.generate(
          240,
          (i) => '$i ${List.filled(18, '头发在里面，软件可以下载书签。').join()}',
        ),
      );
      var beats = 0;
      final timer = Timer.periodic(
        const Duration(milliseconds: 1),
        (_) => beats++,
      );
      final watch = Stopwatch()..start();
      final result = await source.localizedAsync(const Locale('zh', 'TW'));
      timer.cancel();
      expect(result.paragraphs.first, contains('頭髮在裡面'));
      for (var i = 0; i < source.paragraphs.length; i++) {
        expect(result.paragraphs[i].length, source.paragraphs[i].length);
      }
      expect(beats, greaterThan(0));
      debugPrint(
        'READER50_NATIVE_SCRIPT milliseconds=${watch.elapsedMilliseconds} ui_heartbeats=$beats paragraphs=${result.paragraphs.length}',
      );
    },
  );
}
