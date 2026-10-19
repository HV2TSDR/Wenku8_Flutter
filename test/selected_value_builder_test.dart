import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenku8_flutter/ui_notifiers.dart';

class _ObservedNotifier<T> extends ValueNotifier<T> {
  _ObservedNotifier(super.value);
  bool get listening => hasListeners;
}

void main() {
  testWidgets('unrelated source values do not rebuild the selected subtree', (
    tester,
  ) async {
    final source = _ObservedNotifier((paragraph: 1, clip: 0));
    var builds = 0;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: SelectedValueBuilder<({int paragraph, int clip}), int>(
          listenable: source,
          select: (value) => value.paragraph,
          builder: (context, value, _) {
            builds++;
            return Text('paragraph $value');
          },
        ),
      ),
    );
    for (var clip = 1; clip < 10; clip++) {
      source.value = (paragraph: 1, clip: clip);
      await tester.pump();
    }
    expect(builds, 1);
    source.value = (paragraph: 2, clip: 0);
    await tester.pump();
    expect(builds, 2);
    expect(find.text('paragraph 2'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(source.listening, false);
    source.dispose();
  });

  testWidgets(
    'a changed source or projection is read immediately and detached',
    (tester) async {
      final first = _ObservedNotifier((a: 1, b: 2));
      final second = _ObservedNotifier((a: 3, b: 4));
      Widget view(ValueNotifier<({int a, int b})> source, bool alternate) =>
          Directionality(
            textDirection: TextDirection.ltr,
            child: SelectedValueBuilder<({int a, int b}), int>(
              listenable: source,
              select: (value) => alternate ? value.b : value.a,
              builder: (context, value, _) => Text('$value'),
            ),
          );
      await tester.pumpWidget(view(first, false));
      expect(find.text('1'), findsOneWidget);
      await tester.pumpWidget(view(first, true));
      expect(find.text('2'), findsOneWidget);
      await tester.pumpWidget(view(second, true));
      expect(find.text('4'), findsOneWidget);
      expect(first.listening, false);
      first.value = (a: 9, b: 9);
      second.value = (a: 3, b: 5);
      await tester.pump();
      expect(find.text('5'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(second.listening, false);
      first.dispose();
      second.dispose();
    },
  );
}
