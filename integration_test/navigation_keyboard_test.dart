import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show InkWell;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/main.dart';
import 'package:wenku8_flutter/native_effects.dart';
import 'package:wenku8_flutter/pages.dart';
import 'package:wenku8_flutter/updates/update_page.dart';

// Real Android IME/insets, not TestTextInput's simulated visibility.
Future<void> _keyboard(WidgetTester tester, bool visible) async {
  var consecutive = 0;
  for (var frame = 0; frame < 80; frame++) {
    await tester.pump(const Duration(milliseconds: 50));
    if ((tester.view.viewInsets.bottom > 0) == visible) {
      if (++consecutive == 6) return;
    } else {
      consecutive = 0;
    }
  }
  expect(
    tester.view.viewInsets.bottom > 0,
    visible,
    reason: 'Native IME should remain ${visible ? 'visible' : 'hidden'}.',
  );
}

Future<void> _tab(WidgetTester tester, int index) async {
  await tester.tapAt(tester.getCenter(find.byKey(ValueKey('dock-tab-$index'))));
  await tester.pumpAndSettle();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Android IME stays closed after book and settings round trips', (
    tester,
  ) async {
    await NativeEffects.prepare();
    SharedPreferences.setMockInitialValues({'reduceMotion': true});
    final state = await LibraryState.load();
    addTearDown(state.dispose);
    await state.rememberNovel(demoNovels.first);
    await state.toggleShelf(demoNovels.first.id);
    await tester.pumpWidget(
      NovelApp(state: state, repository: const DemoNovelRepository()),
    );
    await tester.pumpAndSettle();
    await _tab(tester, 1);
    final input = find.byKey(const ValueKey('shelf-search'));
    final field = tester.widget<CupertinoSearchTextField>(input);
    field.controller!.text = demoNovels.first.title;
    await tester.tap(input);
    await _keyboard(tester, true);
    final focus = tester
        .widget<EditableText>(
          find.descendant(of: input, matching: find.byType(EditableText)),
        )
        .focusNode;
    // Model Android back dismissing only the keyboard, leaving input focus.
    await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    await _keyboard(tester, false);
    expect(focus.hasFocus, isTrue);
    await tester.tap(find.text(demoNovels.first.title).last);
    await tester.pumpAndSettle();
    expect(find.byType(DetailLoaderPage), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await _keyboard(tester, false);
    expect(focus.hasFocus, isFalse);
    expect(field.controller!.text, demoNovels.first.title);
    debugPrint('NATIVE_KEYBOARD_CHECK=book-return-hidden');
    await tester.pump(const Duration(milliseconds: 800));

    await tester.tap(input);
    await _keyboard(tester, true);
    await _tab(tester, 2);
    await _keyboard(tester, false);
    expect(focus.canRequestFocus, isFalse);
    final about = find.byKey(const ValueKey('settings-app-update'));
    await tester.scrollUntilVisible(
      about,
      300,
      scrollable: find
          .descendant(
            of: find.byKey(const PageStorageKey('settings')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(about);
    await tester.pumpAndSettle();
    final aboutButton = find
        .descendant(of: about, matching: find.byType(InkWell))
        .first;
    await tester.tap(aboutButton);
    await tester.pumpAndSettle();
    expect(find.byType(AppUpdatePage), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await _keyboard(tester, false);
    debugPrint('NATIVE_KEYBOARD_CHECK=settings-return-hidden');
    await tester.pump(const Duration(milliseconds: 800));
    await _tab(tester, 1);
    await _keyboard(tester, false);
    expect(focus.hasFocus, isFalse);
    await tester.tap(input);
    await _keyboard(tester, true);
    debugPrint('NATIVE_KEYBOARD_CHECK=explicit-tap-shows-ime');
    await tester.pump(const Duration(milliseconds: 800));
    FocusManager.instance.primaryFocus?.unfocus();
    await _keyboard(tester, false);
    expect(tester.takeException(), isNull);
  });
}
