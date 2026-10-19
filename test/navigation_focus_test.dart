import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/app_interactions.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/main.dart';
import 'package:wenku8_flutter/pages.dart';

Finder get _hostInput => find.byKey(const ValueKey('host-input'));
Finder get _shelfInput => find.byKey(const ValueKey('expanded-search-input'));

Future<void> _openShelfSearch(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('shelf-search-entry')));
  await tester.pumpAndSettle();
}

FocusNode _inputFocus(WidgetTester tester, Finder input) => tester
    .widget<EditableText>(
      find.descendant(of: input, matching: find.byType(EditableText)),
    )
    .focusNode;

Future<void> _expectDismissed(WidgetTester tester, FocusNode previous) async {
  await tester.pumpAndSettle();
  expect(previous.hasFocus, isFalse);
  expect(tester.testTextInput.isVisible, isFalse);
}

Future<void> _mountHome(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({'reduceMotion': true});
  final state = await LibraryState.load();
  addTearDown(state.dispose);
  await state.rememberNovel(demoNovels.first);
  await state.toggleShelf(demoNovels.first.id);
  await tester.pumpWidget(
    NovelApp(state: state, repository: const DemoNovelRepository()),
  );
  await tester.pumpAndSettle();
  await tester.tapAt(
    tester.getCenter(find.byKey(const ValueKey('dock-tab-1'))),
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final reduceMotion in [false, true]) {
    testWidgets('page return does not reopen an IME dismissed by Android back '
        '(reduceMotion=$reduceMotion)', (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: _FocusFixture(reduceMotion: reduceMotion)),
      );
      await tester.enterText(_hostInput, '保留查询');
      final previous = _inputFocus(tester, _hostInput);
      expect(previous.hasFocus, isTrue);
      // Android can hide the IME without clearing Flutter's input focus.
      tester.testTextInput.hide();
      await tester.tap(find.byKey(const ValueKey('open-page')));
      await tester.pumpAndSettle();
      expect(find.text('目标页面'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await _expectDismissed(tester, previous);
      expect(find.text('保留查询'), findsOneWidget);
      await tester.tap(_hostInput);
      await tester.pumpAndSettle();
      expect(previous.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);
    });
  }

  for (final overlay in ['sheet', 'menu']) {
    testWidgets('$overlay return does not revive the underlying input', (
      tester,
    ) async {
      await tester.pumpWidget(const MaterialApp(home: _FocusFixture()));
      await tester.enterText(_hostInput, '保留查询');
      final previous = _inputFocus(tester, _hostInput);
      await tester.tap(find.byKey(ValueKey('open-$overlay')));
      await tester.pumpAndSettle();
      if (overlay == 'sheet') {
        final input = find.byKey(const ValueKey('overlay-input'));
        await tester.enterText(input, '抽屉内仍可输入');
        expect(_inputFocus(tester, input).hasFocus, isTrue);
        expect(tester.testTextInput.isVisible, isTrue);
      }
      await tester.binding.handlePopRoute();
      await _expectDismissed(tester, previous);
      expect(find.text('保留查询'), findsOneWidget);
    });
  }

  testWidgets(
    'shelf query survives a book round trip without keyboard revival',
    (tester) async {
      await _mountHome(tester);
      await _openShelfSearch(tester);
      await tester.enterText(_shelfInput, demoNovels.first.title);
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      final previous = _inputFocus(tester, _shelfInput);
      tester.testTextInput.hide();
      await tester.tap(
        find
            .descendant(
              of: find.byType(InlineSearchResults),
              matching: find.text(demoNovels.first.title),
            )
            .last,
      );
      await tester.pumpAndSettle();
      expect(find.byType(DetailLoaderPage), findsOneWidget);
      await tester.binding.handlePopRoute();
      await _expectDismissed(tester, previous);
      expect(
        tester.widget<TextField>(_shelfInput).controller!.text,
        demoNovels.first.title,
      );
    },
  );

  testWidgets(
    'hidden shelf cannot retain or reacquire input focus in settings',
    (tester) async {
      await _mountHome(tester);
      await _openShelfSearch(tester);
      await tester.enterText(_shelfInput, '查询');
      final previous = _inputFocus(tester, _shelfInput);
      await tester.pump(const Duration(milliseconds: 350));
      await tester.tap(find.byKey(const ValueKey('inline-search-close')));
      await tester.pumpAndSettle();
      await tester.tapAt(
        tester.getCenter(find.byKey(const ValueKey('dock-tab-3'))),
      );
      await _expectDismissed(tester, previous);
      expect(previous.canRequestFocus, isFalse);
      previous.requestFocus();
      await _expectDismissed(tester, previous);
      final about = find.byKey(const ValueKey('my-about'));
      final scrollable = find
          .descendant(
            of: find.byKey(const PageStorageKey('my-page')),
            matching: find.byType(Scrollable),
          )
          .first;
      // Start in the gutter rather than dragging a slider/switch at the center.
      for (var i = 0; i < 20 && about.evaluate().isEmpty; i++) {
        final viewport = tester.getRect(scrollable);
        await tester.dragFrom(
          Offset(viewport.left + 8, viewport.center.dy),
          const Offset(0, -400),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.ensureVisible(about);
      await tester.pumpAndSettle();
      await tester.tapAt(tester.getCenter(about));
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await _expectDismissed(tester, previous);
      await tester.tapAt(
        tester.getCenter(find.byKey(const ValueKey('dock-tab-1'))),
      );
      await _expectDismissed(tester, previous);
      expect(_shelfInput, findsNothing);
      expect(previous.canRequestFocus, isFalse);
      await _openShelfSearch(tester);
      expect(tester.widget<TextField>(_shelfInput).controller!.text, '查询');
      expect(previous.canRequestFocus, isTrue);
      expect(previous.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);
    },
  );

  testWidgets('leaving during search expansion cancels its deferred keyboard', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final state = await LibraryState.load();
    addTearDown(state.dispose);
    await tester.pumpWidget(
      NovelApp(state: state, repository: const DemoNovelRepository()),
    );
    await tester.pumpAndSettle();
    final search = find.byWidgetPredicate(
      (widget) => widget is GlassIconButton && widget.label == '搜索',
    );
    await tester.tap(search);
    await tester.pump();
    await tester.pump(NovelMotion.enter * .15);
    final input = find.byKey(const ValueKey('expanded-search-input'));
    final previous = _inputFocus(tester, input);
    final context = tester.element(find.byType(HomeShell));
    final trip = pushNovelPage<void>(
      context,
      const Scaffold(body: Text('目标页面')),
      reduceMotion: true,
    );
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await trip;
    await _expectDismissed(tester, previous);
    await tester.tap(input);
    await tester.pumpAndSettle();
    expect(previous.hasFocus, isTrue);
  });

  for (final reduceMotion in [false, true]) {
    testWidgets('explicitly opening search still focuses once and can reopen '
        '(reduceMotion=$reduceMotion)', (tester) async {
      SharedPreferences.setMockInitialValues({'reduceMotion': reduceMotion});
      final state = await LibraryState.load();
      addTearDown(state.dispose);
      await tester.pumpWidget(
        NovelApp(state: state, repository: const DemoNovelRepository()),
      );
      await tester.pumpAndSettle();
      final search = find.byWidgetPredicate(
        (widget) => widget is GlassIconButton && widget.label == '搜索',
      );
      final input = find.byKey(const ValueKey('expanded-search-input'));
      for (var attempt = 0; attempt < 2; attempt++) {
        await tester.tap(search);
        await tester.pumpAndSettle();
        expect(_inputFocus(tester, input).hasFocus, isTrue);
        expect(
          tester.testTextInput.isVisible,
          isTrue,
          reason: 'Search opening ${attempt + 1} must still show the keyboard.',
        );
        await tester.tap(find.byKey(const ValueKey('inline-search-close')));
        await tester.pumpAndSettle();
        expect(input, findsNothing);
        expect(tester.testTextInput.isVisible, isFalse);
      }
    });
  }
}

class _FocusFixture extends StatelessWidget {
  const _FocusFixture({this.reduceMotion = true});
  final bool reduceMotion;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        const TextField(key: ValueKey('host-input')),
        TextButton(
          key: const ValueKey('open-page'),
          onPressed: () => pushNovelPage<void>(
            context,
            const Scaffold(body: Text('目标页面')),
            reduceMotion: reduceMotion,
          ),
          child: const Text('进入页面'),
        ),
        TextButton(
          key: const ValueKey('open-sheet'),
          onPressed: () => showJellySheet<void>(
            context: context,
            reduceMotion: true,
            builder: (_) => const SizedBox(
              height: 200,
              child: TextField(key: ValueKey('overlay-input')),
            ),
          ),
          child: const Text('打开抽屉'),
        ),
        Builder(
          builder: (buttonContext) => TextButton(
            key: const ValueKey('open-menu'),
            onPressed: () => showGlassMenu<void>(
              context: buttonContext,
              reduceMotion: true,
              builder: (_) => const Text('菜单'),
            ),
            child: const Text('打开菜单'),
          ),
        ),
      ],
    ),
  );
}
