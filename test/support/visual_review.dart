import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Optional local visual review. No host paths or proprietary fonts are bundled.
Future<void> loadReviewFonts() async {
  const path = String.fromEnvironment('REVIEW_FONT');
  if (path.isEmpty) return;
  final bytes = await File(path).readAsBytes();
  for (final family in ['.SF Pro Text', 'Roboto', 'monospace']) {
    await (FontLoader(
      family,
    )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
  }
  await (FontLoader('packages/cupertino_icons/CupertinoIcons')..addFont(
        rootBundle.load('packages/cupertino_icons/assets/CupertinoIcons.ttf'),
      ))
      .load();
}

Future<void> captureReview(
  WidgetTester tester,
  GlobalKey key,
  String name,
) async {
  const output = String.fromEnvironment('REVIEW_ARTIFACTS');
  if (output.isEmpty) return;
  // The Skia package capture invalidates its lens at the end of the frame.
  // Flush that paint without advancing the animation being inspected.
  final render =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  if (render.debugNeedsPaint) tester.binding.rootPipelineOwner.flushPaint();
  final image = render.toImageSync(pixelRatio: 1);
  await tester.runAsync(() async {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(output).create(recursive: true);
    await File('$output/$name.png').writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
  });
}
