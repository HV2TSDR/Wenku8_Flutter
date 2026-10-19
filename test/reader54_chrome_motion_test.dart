import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenku8_flutter/reader_preferences.dart';
import 'package:wenku8_flutter/reader_paged_view.dart';
import 'package:wenku8_flutter/reader_reflow.dart';
import 'reader_modes_test.dart' as fixture;
import 'support/visual_review.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadReviewFonts);
  for (final mode in ReaderMode.values) {
    testWidgets('${mode.name} chrome reflow has continuous retained ink', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      tester.view.viewPadding = const FakeViewPadding(top: 28, bottom: 24);
      tester.view.padding = tester.view.viewPadding;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewPadding);
      addTearDown(tester.view.resetPadding);
      final state = await fixture.library(mode);
      addTearDown(state.dispose);
      await state.setReduceMotion(false);
      await tester.pumpWidget(fixture.app(state));
      await fixture.settleReader(tester);
      final paged = find.byType(ReaderPagedView);
      if (mode.paginated) {
        tester.widget<ReaderPagedView>(paged).controller.seek(.4);
        await fixture.settleReader(tester);
      }
      final frames = <Map<String, Object?>>[];
      Uint8List? before;
      Rect? originalViewport;
      var verified = 0;
      Future<void> frame(String phase, int elapsed) async {
        final parts = find.byType(ReaderFragmentMotion);
        final motion = find.byType(ReaderIncrementalViewport);
        final point = parts.evaluate().isEmpty
            ? Offset.zero
            : tester.getTopLeft(parts.first);
        frames.add({
          'phase': phase,
          'elapsed': elapsed,
          'y': point.dy,
          if (motion.evaluate().isNotEmpty)
            'progress': tester
                .widget<ReaderIncrementalViewport>(motion)
                .animation
                .value,
        });
        const output = String.fromEnvironment('REVIEW_ARTIFACTS');
        final progress = motion.evaluate().isEmpty
            ? 1.0
            : tester.widget<ReaderIncrementalViewport>(motion).animation.value;
        final publication =
            mode.paginated &&
            elapsed >= 0 &&
            progress == 0 &&
            tester.widget<ReaderPagedView>(paged).controller.ready;
        final compare = mode.paginated && (elapsed == -1 || publication);
        if (output.isEmpty && !compare) return;
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('reader-article-boundary')),
        );
        if (boundary.debugNeedsPaint) {
          tester.binding.rootPipelineOwner.flushPaint();
        }
        final image = boundary.toImageSync();
        await tester.runAsync(() async {
          if (output.isNotEmpty) {
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await Directory(output).create(recursive: true);
            await File(
              '$output/${mode.name}-$phase-$elapsed.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
          }
          if (compare) {
            final pixels = (await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            ))!.buffer.asUint8List();
            if (elapsed == -1) {
              before = pixels;
              originalViewport = tester.getRect(motion);
              verified = 0;
            } else {
              final rect = originalViewport!;
              var changed = 0;
              for (var y = rect.top.ceil(); y < rect.bottom.floor(); y++) {
                for (var x = rect.left.ceil(); x < rect.right.floor(); x++) {
                  final at = (y * image.width + x) * 4;
                  if (pixels[at] != before![at] ||
                      pixels[at + 1] != before![at + 1] ||
                      pixels[at + 2] != before![at + 2]) {
                    changed++;
                  }
                }
              }
              expect(
                changed,
                0,
                reason:
                    '${mode.name} $phase at $elapsed ms published new pagination before motion',
              );
              verified++;
            }
          }
          image.dispose();
        });
      }

      for (final phase in ['hide', 'show']) {
        await frame(phase, -1);
        await tester.tapAt(const Offset(195, 422));
        var previous = 0;
        for (final elapsed in [
          0,
          1,
          8,
          16,
          32,
          64,
          96,
          144,
          216,
          320,
          420,
          520,
        ]) {
          await tester.pump(Duration(milliseconds: elapsed - previous));
          previous = elapsed;
          await frame(phase, elapsed);
        }
        await fixture.settleReader(tester);
        if (mode.paginated) expect(verified, greaterThan(0));
        expect(tester.takeException(), isNull);
      }
      const output = String.fromEnvironment('REVIEW_ARTIFACTS');
      if (output.isNotEmpty) {
        await tester.runAsync(
          () => File(
            '$output/${mode.name}-frames.json',
          ).writeAsString(const JsonEncoder.withIndent('  ').convert(frames)),
        );
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
