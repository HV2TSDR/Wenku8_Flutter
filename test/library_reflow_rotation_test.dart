import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenku8_flutter/library_workspace.dart';
import 'package:wenku8_flutter/library_reflow.dart';

void main() {
  testWidgets(
    'rotation retains one PageView position through the wide breakpoint',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1318, 824);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = PageController(initialPage: 2);
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: LibraryWorkspace(
            child: LibraryReflowPart(
              id: 'rotation-pager',
              child: PageView(
                controller: controller,
                children: List.generate(5, (i) => Text('Page $i')),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final scrollable = tester.state<ScrollableState>(find.byType(Scrollable));
      for (final size in [
        const Size(824, 1318),
        const Size(390, 844),
        const Size(1318, 824),
      ]) {
        tester.view.physicalSize = size;
        await tester.pumpAndSettle();
        expect(
          tester.state<ScrollableState>(find.byType(Scrollable)),
          same(scrollable),
        );
        expect(controller.positions.length, 1);
        expect(controller.page, 2);
        expect(tester.takeException(), isNull);
      }
    },
  );
}
