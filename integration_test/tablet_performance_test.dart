import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/native_effects.dart';
import 'package:wenku8_flutter/pages.dart';

class _ManyBooks extends DemoNovelRepository {
  const _ManyBooks();
  @override
  Future<List<Novel>> list() async => [
    for (var i = 0; i < 120; i++)
      Novel(
        id: 91000 + i,
        title: '星海图书馆：第 ${i + 1} 份档案',
        author: '尺寸与性能测试',
        genre: '测试目录',
        summary: '用于固定工作负载的本地目录。',
        colors: const [Color(0xff373737), Color(0xff686868)],
      ),
  ];
  @override
  Future<List<NovelChapter>> chapters(int id) async => [
    for (var i = 0; i < 1200; i++) NovelChapter('第 ${i + 1} 章', '测试正文。'),
  ];
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('tablet detail entry exit frame workload', (tester) async {
    SharedPreferences.setMockInitialValues({'reduceMotion': false});
    final library = await LibraryState.load();
    await NativeEffects.prepare();
    tester.view.physicalSize = const Size(1318, 824);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
    tester.view.viewPadding = tester.view.padding;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);
    addTearDown(library.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: novelTheme(Brightness.light),
        home: HomeShell(state: library, repository: const _ManyBooks()),
      ),
    );
    await tester.pumpAndSettle();
    await Scrollable.ensureVisible(
      tester.element(find.text('更多书籍')),
      alignment: .2,
    );
    await tester.pumpAndSettle();
    final timings = <FrameTiming>[];
    final phases = <({int at, String name})>[];
    void collect(List<FrameTiming> value) => timings.addAll(value);
    WidgetsBinding.instance.addTimingsCallback(collect);
    for (var i = 0; i < 5; i++) {
      phases.add((at: developer.Timeline.now, name: 'open-$i'));
      final book = find.byType(NovelRow).first;
      await tester.tap(
        find.descendant(of: book, matching: find.byType(InkWell)).first,
      );
      await tester.pumpAndSettle(const Duration(milliseconds: 16));
      expect(find.byType(DetailPage), findsOneWidget);
      final back = find
          .byWidgetPredicate((w) => w is GlassIconButton && w.label == '返回')
          .last;
      phases.add((at: developer.Timeline.now, name: 'close-$i'));
      await tester.tap(
        find.descendant(of: back, matching: find.byType(InkWell)).first,
      );
      await tester.pumpAndSettle(const Duration(milliseconds: 16));
      expect(find.byType(DetailPage), findsNothing);
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
    WidgetsBinding.instance.removeTimingsCallback(collect);
    Map<String, Object> stats(Iterable<Duration> values) {
      final sorted = values.map((v) => v.inMicroseconds).toList()..sort();
      return {
        'frames': sorted.length,
        'medianUs': sorted[sorted.length ~/ 2],
        'p95Us': sorted[((sorted.length - 1) * .95).round()],
        'maxUs': sorted.last,
        'over8333': sorted.where((v) => v > 8333).length,
        'over16667': sorted.where((v) => v > 16667).length,
      };
    }

    expect(timings, isNotEmpty);
    final slowest = [...timings]
      ..sort((a, b) => b.buildDuration.compareTo(a.buildDuration));
    debugPrint(
      'TABLET_DETAIL_SLOWEST=${jsonEncode(slowest.take(12).map((frame) {
        final at = frame.timestampInMicroseconds(FramePhase.buildStart);
        final matches = phases.where((phase) => phase.at <= at);
        return {'buildUs': frame.buildDuration.inMicroseconds, 'phase': matches.isEmpty ? 'before-workload' : matches.last.name, 'afterActionUs': matches.isEmpty ? null : at - matches.last.at};
      }).toList())}',
    );
    debugPrint('TABLET_SHADER_FILTERS=${ImageFilter.isShaderFilterSupported}');
    debugPrint(
      'TABLET_DETAIL_PERF=${jsonEncode({'build': stats(timings.map((t) => t.buildDuration)), 'raster': stats(timings.map((t) => t.rasterDuration)), 'total': stats(timings.map((t) => t.totalSpan))})}',
    );
    expect(tester.takeException(), isNull);
  });
}
