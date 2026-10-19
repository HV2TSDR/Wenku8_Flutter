import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/book_collection_layout.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/local_books.dart';
import 'package:wenku8_flutter/local_library_page.dart';
import 'package:wenku8_flutter/pages.dart';

final inertiaBooks = List.generate(
  80,
  (i) => Novel(
    id: 54000 + i,
    title: '阅读书目 $i',
    author: '作者',
    genre: '',
    summary: '',
    colors: const [Colors.grey, Colors.black],
  ),
);

class InertiaLocalBooks extends LocalBookStore {
  InertiaLocalBooks() : super(Directory.systemTemp);
  @override
  List<Novel> get books => inertiaBooks;
  @override
  Novel? book(int id) => inertiaBooks.where((b) => b.id == id).firstOrNull;
}

void main() {
  testWidgets(
    'responsive collection builds only newly entering rows during inertia',
    (tester) async {
      final controller = ScrollController(), builds = <int, int>{};
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          scrollBehavior: const NovelScrollBehavior(),
          home: Scaffold(
            body: CustomScrollView(
              controller: controller,
              slivers: [
                BookCollectionSliver(
                  itemCount: 100,
                  itemBuilder: (_, i) {
                    builds.update(i, (n) => n + 1, ifAbsent: () => 1);
                    return SizedBox(
                      key: ValueKey(i),
                      height: 140,
                      child: Text('第 $i 本书'),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      controller.jumpTo(1200);
      await tester.pumpAndSettle();
      final before = Map.of(builds);
      (controller.position as ScrollPositionWithSingleContext).goBallistic(450);
      for (var i = 0; i < 14; i++) {
        await tester.pump(const Duration(microseconds: 8333));
      }
      final rebuilt = before.keys.where((i) => builds[i] != before[i]).toList();
      debugPrint(
        'COLLECTION_INERTIA existing_rows_rebuilt=${rebuilt.length} extra_builds=${before.keys.fold(0, (n, i) => n + builds[i]! - before[i]!)}',
      );
      expect(rebuilt, isEmpty);
      await tester.pumpAndSettle();
    },
  );
  testWidgets(
    'a cancelled book press cannot rebound during the following fling',
    (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          scrollBehavior: const NovelScrollBehavior(),
          home: Scaffold(
            body: CustomScrollView(
              controller: controller,
              slivers: [
                BookCollectionSliver(
                  itemCount: 80,
                  itemBuilder: (_, i) => JellyTapSurface(
                    key: ValueKey(i),
                    onTap: () {},
                    child: SizedBox(height: 140, child: Text('第 $i 本书')),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final row = find.byKey(const ValueKey(3));
      final transition = find.descendant(
        of: row,
        matching: find.byType(ScaleTransition),
      );
      final finger = await tester.startGesture(tester.getCenter(row));
      await tester.pump(const Duration(milliseconds: 180));
      await tester.pump(const Duration(milliseconds: 120));
      expect(
        tester.widget<ScaleTransition>(transition).scale.value,
        lessThan(1),
      );
      await finger.moveBy(const Offset(0, -40));
      await tester.pump(const Duration(milliseconds: 8));
      await finger.moveBy(const Offset(0, -80));
      await tester.pump(const Duration(milliseconds: 8));
      await finger.up();
      await tester.pump();
      expect(
        tester.widget<ScaleTransition>(transition).scale.value,
        1,
        reason: 'scroll won the gesture; only its translation should continue',
      );
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(microseconds: 8333));
        if (transition.evaluate().isNotEmpty) {
          expect(tester.widget<ScaleTransition>(transition).scale.value, 1);
        }
      }
      await tester.pumpAndSettle();
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.takeException(), isNull);
    },
  );

  for (final glass in [false, true]) {
    testWidgets(
      'accepted tap keeps its press and release motion; glass=$glass',
      (tester) async {
        var taps = 0;
        Widget surface(VoidCallback? onTap) => glass
            ? LiquidGlass(
                key: const ValueKey('press'),
                onTap: onTap,
                child: const SizedBox(width: 200, height: 80),
              )
            : JellyTapSurface(
                key: const ValueKey('press'),
                onTap: onTap,
                child: const SizedBox(width: 200, height: 80),
              );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: Center(child: surface(() => taps++))),
          ),
        );
        final finder = find
            .descendant(
              of: find.byKey(const ValueKey('press')),
              matching: find.byType(AnimatedScale),
            )
            .first;
        final finger = await tester.startGesture(tester.getCenter(finder));
        await tester.pump(const Duration(milliseconds: 150));
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.widget<AnimatedScale>(finder).scale, lessThan(1));
        await finger.up();
        await tester.pump();
        expect(taps, 1);
        expect(
          tester.widget<AnimatedScale>(finder).duration,
          NovelMotion.enter,
        );
        await tester.pumpAndSettle();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: Center(child: surface(null))),
          ),
        );
        for (final ink in tester.widgetList<InkWell>(find.byType(InkWell))) {
          expect(ink.onTap, isNull);
          expect(ink.onTapCancel, isNull);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final scene in ['discover', 'shelf', 'local']) {
    testWidgets(
      '$scene inertia does not rescale retained books or restart their entrance',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        SharedPreferences.setMockInitialValues({});
        final state = await LibraryState.load(), local = InertiaLocalBooks();
        addTearDown(state.dispose);
        addTearDown(local.dispose);
        if (scene == 'shelf') {
          for (final book in inertiaBooks) {
            await state.setShelfMembership(book.id, true, novel: book);
          }
        }
        final page = switch (scene) {
          'discover' => DiscoverPage(
            books: inertiaBooks,
            state: state,
            repository: const DemoNovelRepository(),
            onSearch: () {},
          ),
          'shelf' => ShelfPage(
            books: inertiaBooks,
            state: state,
            repository: const DemoNovelRepository(),
          ),
          _ => LocalLibraryPage(books: local, state: state, onOpen: (_, _) {}),
        };
        await tester.pumpWidget(
          MaterialApp(
            theme: novelTheme(Brightness.light),
            scrollBehavior: const NovelScrollBehavior(),
            home: Scaffold(body: Atmosphere(shareGlass: true, child: page)),
          ),
        );
        await tester.pumpAndSettle();
        final scroll = find
            .byWidgetPredicate(
              (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
            )
            .first;
        final position = tester.state<ScrollableState>(scroll).position;
        position.jumpTo(650);
        await tester.pumpAndSettle();
        final row = find.byType(NovelRow).evaluate().firstWhere((e) {
          final rect = tester.getRect(find.byWidget(e.widget));
          return rect.top > 160 && rect.bottom < 700;
        });
        final press = find
            .descendant(
              of: find.byWidget(row.widget),
              matching: find.byType(ScaleTransition),
            )
            .first;
        final ink = tester.widget<NovelRow>(find.byWidget(row.widget));
        final finger = await tester.startGesture(
          tester.getCenter(find.byWidget(ink)),
        );
        await tester.pump(const Duration(milliseconds: 150));
        await tester.pump(const Duration(milliseconds: 100));
        await finger.moveBy(const Offset(0, -40));
        await tester.pump(const Duration(milliseconds: 8));
        await finger.moveBy(const Offset(0, -60));
        await tester.pump(const Duration(milliseconds: 8));
        await finger.up();
        await tester.pump();
        expect(tester.widget<ScaleTransition>(press).scale.value, 1);
        final origin =
            tester.getTopLeft(find.byWidget(ink)).dy + position.pixels;
        var previous = position.pixels;
        for (var i = 0; i < 12; i++) {
          await tester.pump(const Duration(microseconds: 8333));
          expect(position.pixels, greaterThanOrEqualTo(previous));
          if (find.byWidget(ink).evaluate().isNotEmpty) {
            expect(tester.widget<ScaleTransition>(press).scale.value, 1);
            expect(
              tester.getTopLeft(find.byWidget(ink)).dy + position.pixels,
              closeTo(origin, .01),
            );
            expect(tester.widget(find.byWidget(ink)), same(ink));
          }
          previous = position.pixels;
        }
        await tester.pumpAndSettle();
        expect(tester.binding.transientCallbackCount, 0);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
