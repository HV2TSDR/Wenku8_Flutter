import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart' as easy;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/listening/controller.dart';
import 'package:wenku8_flutter/listening/store.dart';
import 'package:wenku8_flutter/listening/widgets.dart';
import 'package:wenku8_flutter/pages.dart';
import 'package:wenku8_flutter/reader_tools.dart';

import 'support/listening_fixture.dart';
import 'support/visual_review.dart';

void main({
  Future<void> Function(WidgetTester, GlobalKey, String)? capture,
  bool native = false,
}) {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (!native) setUpAll(loadReviewFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> snapshot(
    WidgetTester tester,
    GlobalKey boundary,
    String name,
  ) async {
    if (capture != null) {
      await capture(tester, boundary, name);
    } else {
      await captureReview(tester, boundary, name);
    }
    expect(tester.takeException(), isNull);
  }

  Widget app(Widget Function(BuildContext) content) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: novelTheme(Brightness.light),
    home: Scaffold(
      body: Center(
        child: SizedBox(width: 280, child: Builder(builder: content)),
      ),
    ),
  );

  Finder switchThumb() => find.descendant(
    of: find.byType(easy.LiquidGlassSwitch),
    matching: find.byWidgetPredicate(
      (widget) => widget is ColoredBox && widget.color == ArchiveDesign.milk,
    ),
  );

  testWidgets('package switch follows the finger and settles after tap/drag', (
    tester,
  ) async {
    var value = false;
    final boundary = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: app(
          (context) => StatefulBuilder(
            builder: (context, update) => AppControls.toggle(
              context,
              value: value,
              onChanged: (next) => update(() => value = next),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final start = tester.getCenter(switchThumb());
    await tester.tap(find.byType(easy.LiquidGlassSwitch));
    await tester.pumpAndSettle();
    expect(value, true);
    expect(tester.getCenter(switchThumb()).dx, greaterThan(start.dx));
    final gesture = await tester.startGesture(tester.getCenter(switchThumb()));
    await tester.pump(const Duration(milliseconds: 160));
    await gesture.moveBy(const Offset(-35, 0));
    await tester.pump(const Duration(milliseconds: 120));
    final bounds = tester.getRect(find.byType(AppGlassSwitch));
    final held = tester.getRect(switchThumb());
    expect(held.width, greaterThan(40));
    expect(bounds.inflate(.5).contains(held.topLeft), true);
    expect(bounds.inflate(.5).contains(held.bottomRight), true);
    await snapshot(tester, boundary, 'switch-held');
    await gesture.up();
    await tester.pumpAndSettle();
    expect(value, false);
    expect(tester.getCenter(switchThumb()).dx, closeTo(start.dx, .1));
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('switch reconciles a rejected save while the finger is held', (
    tester,
  ) async {
    final save = Completer<void>();
    await tester.pumpWidget(
      app(
        (context) => Center(
          child: AppControls.toggle(
            context,
            value: false,
            // A failed/cancelled action leaves the controlled value unchanged.
            onChanged: (_) => save.future,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final start = tester.getCenter(switchThumb());
    final gesture = await tester.startGesture(start);
    await gesture.moveBy(const Offset(45, 0));
    await tester.pump();
    save.complete();
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.getCenter(switchThumb()).dx, closeTo(start.dx, .1));
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('package slider quantizes, previews and commits once on cancel', (
    tester,
  ) async {
    var value = 20.0;
    final previews = <double>[];
    final commits = <double>[];
    final interactions = <bool>[];
    final boundary = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: app(
          (context) => StatefulBuilder(
            builder: (context, update) => ReaderValueSlider(
              sliderKey: const ValueKey('actual-slider'),
              label: '字号',
              value: value,
              min: 10,
              max: 30,
              divisions: 20,
              format: (value) => '${value.round()}',
              onPreview: previews.add,
              onCommitted: (next) {
                commits.add(next);
                update(() => value = next);
              },
              onInteractionChanged: interactions.add,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final slider = find.byType(easy.LiquidGlassSlider);
    final start = tester.getCenter(slider);
    final gesture = await tester.startGesture(start);
    await gesture.moveBy(const Offset(23, 0));
    for (var frame = 0; frame < 14; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(previews, isNotEmpty);
    expect(commits, isEmpty);
    expect(previews.every((value) => value == value.round()), true);
    final heldThumb = find.descendant(
      of: slider,
      matching: find.byWidgetPredicate(
        (widget) => widget is ColoredBox && widget.color == ArchiveDesign.milk,
      ),
    );
    expect(tester.getSize(heldThumb).width, greaterThan(45));
    await snapshot(tester, boundary, 'slider-held');
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(commits, hasLength(1));
    expect(commits.single, previews.last);
    expect(interactions, [true, false]);
    final control = tester.widget<easy.LiquidGlassSlider>(slider);
    final layout = control.layout.copyWith(
      width: control.width,
      height: control.height,
    );
    final inset = layout.resolveHorizontalInset(control.motion.maxDeformation);
    final thumb = find.descendant(
      of: slider,
      matching: find.byWidgetPredicate(
        (widget) => widget is ColoredBox && widget.color == ArchiveDesign.milk,
      ),
    );
    final minimum = inset + layout.thumbWidth / 2;
    final travel = layout.width - 2 * minimum;
    expect(
      tester.getCenter(thumb).dx - tester.getTopLeft(slider).dx,
      closeTo(minimum + travel * ((value - 10) / 20), .1),
    );
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('glass controls retain disabled, keyboard and semantic actions', (
    tester,
  ) async {
    var value = .5;
    var toggled = false;
    var disabledCalls = 0;
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      app(
        (context) => StatefulBuilder(
          builder: (context, update) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppControls.toggle(
                context,
                key: const ValueKey('keyboard-switch'),
                value: toggled,
                onChanged: (next) => update(() => toggled = next),
              ),
              AppControls.toggle(context, value: false, onChanged: null),
              AppControls.slider(
                context,
                value: value,
                divisions: 10,
                onChanged: (next) => update(() => value = next),
              ),
              AppControls.segments<int>(
                context,
                groupValue: 0,
                children: const {0: Text('可用'), 1: Text('待开发')},
                disabledChildren: const {1},
                onValueChanged: (_) => disabledCalls++,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(AppGlassSwitch).last, warnIfMissed: false);
    await tester.tap(find.text('待开发'));
    await tester.pumpAndSettle();
    expect(toggled, false);
    expect(disabledCalls, 0);
    Focus.of(
      tester.element(find.byType(easy.LiquidGlassSwitch).first),
    ).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(toggled, true);
    final node = tester.getSemantics(find.byType(AppGlassSlider));
    expect(node.value, '50%');
    node.owner!.performAction(node.id, SemanticsAction.increase);
    await tester.pumpAndSettle();
    expect(value, .6);
    expect(tester.getSemantics(find.byType(AppGlassSlider)).value, '60%');
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets(
    'a slider tap with no intermediate frame leaves no capture pump',
    (tester) async {
      var value = .3;
      await tester.pumpWidget(
        app(
          (context) => StatefulBuilder(
            builder: (context, update) => AppControls.slider(
              context,
              value: value,
              onChanged: (next) => update(() => value = next),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(easy.LiquidGlassSlider));
      // No active frame is built before the package's delayed contraction runs.
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle(const Duration(milliseconds: 16));
      expect(value, closeTo(.5, .01));
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.takeException(), isNull);
    },
  );

  for (final useSwitch in [false, true]) {
    testWidgets(
      'vertical scroll through ${useSwitch ? 'switch' : 'slider'} does not edit it',
      (tester) async {
        final controller = ScrollController();
        addTearDown(controller.dispose);
        final values = <Object>[];
        await tester.pumpWidget(
          MaterialApp(
            theme: novelTheme(Brightness.light),
            home: Scaffold(
              body: ListView(
                controller: controller,
                children: [
                  const SizedBox(height: 220),
                  Center(
                    child: SizedBox(
                      width: 280,
                      child: Builder(
                        builder: (context) => useSwitch
                            ? AppControls.toggle(
                                context,
                                value: false,
                                onChanged: values.add,
                              )
                            : ReaderValueSlider(
                                sliderKey: const ValueKey('scroll-slider'),
                                label: '字号',
                                value: 19,
                                min: 15,
                                max: 27,
                                format: (value) => '$value',
                                onCommitted: values.add,
                              ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 1000),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final control = useSwitch
            ? find.byType(easy.LiquidGlassSwitch)
            : find.byType(easy.LiquidGlassSlider);
        final gesture = await tester.startGesture(tester.getCenter(control));
        // Include a held press before scrolling, not only a fast flick.
        await tester.pump(const Duration(milliseconds: 120));
        await gesture.moveBy(const Offset(0, -30));
        await tester.pump(const Duration(milliseconds: 16));
        await gesture.moveBy(const Offset(0, -140));
        await tester.pump(const Duration(milliseconds: 80));
        await gesture.up();
        await tester.pumpAndSettle();
        expect(controller.offset, greaterThan(100));
        expect(values, isEmpty);
        expect(tester.binding.transientCallbackCount, 0);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  for (final brightness in Brightness.values) {
    testWidgets(
      'actual settings/listening remain readable in ${brightness.name}',
      (tester) async {
        tester.view.physicalSize = const Size(320, 760);
        tester.view.devicePixelRatio = 1;
        tester.view.padding = const FakeViewPadding(top: 28, bottom: 24);
        tester.view.viewPadding = tester.view.padding;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPadding);
        addTearDown(tester.view.resetViewPadding);
        final state = await LibraryState.load();
        final controller = ListeningController(
          repository: const DemoNovelRepository(),
          audio: FakeSpeechAudio(),
          store: ListeningStore(await SharedPreferences.getInstance()),
          outputFactory: (_) async => FakeListeningOutput(),
        );
        final boundary = GlobalKey();
        Widget screen(Widget child) => RepaintBoundary(
          key: boundary,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: novelTheme(brightness),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(1.5)),
              child: child!,
            ),
            home: Scaffold(body: child),
          ),
        );
        await tester.pumpWidget(screen(SettingsPage(state: state)));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('settings-usage-entry')));
        await tester.pumpAndSettle();
        final offline = find.byKey(const ValueKey('settings-adapt-offline'));
        await tester.ensureVisible(offline);
        await tester.pumpAndSettle();
        expect(
          tester
              .getRect(offline)
              .overlaps(tester.getRect(find.text('断网后隐藏发现，书架只显示已缓存的收藏'))),
          false,
        );
        await snapshot(tester, boundary, 'settings-glass-${brightness.name}');
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        await tester.pumpWidget(
          screen(
            ListeningPanel(
              controller: controller,
              novel: demoNovels.first,
              chapter: 0,
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.byKey(const ValueKey('listening-follow')),
        );
        await tester.pumpAndSettle();
        await snapshot(tester, boundary, 'listening-glass-${brightness.name}');
        await tester.pumpWidget(const SizedBox.shrink());
        final closing = controller.dispose();
        for (var i = 0; i < 8; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 16));
        }
        await closing;
        state.dispose();
      },
    );
  }
}
