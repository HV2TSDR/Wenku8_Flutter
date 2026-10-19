import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/native_effects.dart';
import 'package:wenku8_flutter/reader_turn_motion.dart';
import 'package:wenku8_flutter/library_reflow.dart';

import '../test/archive_cover_flight_test.dart' as cover;
import '../test/reader_turn_motion_test.dart' as reader;
import '../test/reader_speech_highlight_test.dart' as speech;
import '../test/reader_appearance_test.dart' as appearance;
import '../test/library_polish_b22_test.dart' as library_polish;
import '../test/route_headers_illustrations_test.dart' as route_illustrations;
import '../test/tablet_workspace_test.dart' as tablet;
import '../test/wide_rendering_polish_test.dart' as wide;
import '../test/local_series_ui_test.dart' as series;
import '../test/reader_turn_visibility_test.dart' as visibility;
import '../test/local_import_batch_test.dart' as batch;
import 'support/glass_tint_edges.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    await NativeEffects.prepare();
    expect(ui.ImageFilter.isShaderFilterSupported, true);
  });
  Future<void> capture(WidgetTester tester, GlobalKey key, String name) async {
    final clocks = <AnimationController, AnimationStatus>{};
    void hold(Animation<double>? animation) {
      while (true) {
        if (animation is ProxyAnimation) {
          animation = animation.parent;
        } else if (animation is CurvedAnimation) {
          animation = animation.parent;
        } else if (animation is ReverseAnimation) {
          animation = animation.parent;
        } else {
          break;
        }
      }
      if (animation is AnimationController && animation.isAnimating) {
        clocks[animation] = animation.status;
        animation.stop();
      }
    }

    for (final scope in tester.widgetList<ReaderTurnScope>(
      find.byType(ReaderTurnScope),
    )) {
      hold(scope.animation);
    }
    for (final scope in tester.widgetList<LibraryReflowScope>(
      find.byType(LibraryReflowScope),
    )) {
      hold(scope.controller.debugClock);
    }
    for (final flight in tester.widgetList<PaperCoverFlight>(
      find.byType(PaperCoverFlight),
    )) {
      hold(flight.animation);
    }
    await tester.pump();
    final render =
        key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final image = await render.toImage(
      pixelRatio: tester.view.devicePixelRatio,
    );
    final file = File(
      '${(await getTemporaryDirectory()).path}/reader-turn/$name.png',
    );
    await file.parent.create(recursive: true);
    await file.writeAsBytes(
      (await image.toByteData(
        format: ui.ImageByteFormat.png,
      ))!.buffer.asUint8List(),
    );
    image.dispose();
    debugPrint('READER_TURN_CAPTURE=${file.path}');
    for (final entry in clocks.entries) {
      if (entry.value == AnimationStatus.reverse) {
        entry.key.reverse();
      } else {
        entry.key.forward();
      }
    }
    if (clocks.isNotEmpty) await tester.pump();
  }

  reader.main(native: true, capture: capture);
  speech.main(native: true, capture: capture);
  appearance.main(native: true, capture: capture);
  library_polish.main(native: true, capture: capture);
  route_illustrations.main(native: true, capture: capture);
  tablet.main(native: true, capture: capture);
  wide.main(native: true, capture: capture);
  registerGlassTintEdgeTests(capture: capture);
  cover.main(native: true, capture: capture);
  series.main(native: true, capture: capture);
  visibility.main(native: true, capture: capture);
  group('batch import', () => batch.main(native: true, capture: capture));
}
