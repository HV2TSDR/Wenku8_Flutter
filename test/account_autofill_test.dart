import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/feature_pages.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/wenku_account.dart';

import 'feature_completion_state_test.dart' show profileXml;
import 'support/visual_review.dart';

const _username = ValueKey('account-username');
const _password = ValueKey('account-password');
const _login = ValueKey('account-login');

List<bool> _finished(WidgetTester tester) => [
  for (final call in tester.testTextInput.log)
    if (call.method == 'TextInput.finishAutofillContext')
      call.arguments as bool,
];

Future<({WenkuAccount account, LibraryState library})> _open(
  WidgetTester tester, {
  Future<String> Function(String)? login,
  Future<String> Function(String)? profile,
  GlobalKey? boundary,
  Brightness brightness = Brightness.light,
  double textScale = 1,
}) async {
  final account = WenkuAccount(
    hasSession: () async => false,
    clearSession: () async {},
    loginRequest: login ?? (_) async => '1',
    request: profile ?? (_) async => profileXml,
  );
  await account.initialize();
  final library = LibraryState(await SharedPreferences.getInstance());
  await tester.pumpWidget(
    RepaintBoundary(
      key: boundary,
      child: MaterialApp(
        theme: novelTheme(brightness),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: WenkuAccountPage(
          account: account,
          state: library,
          repository: const DemoNovelRepository(),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (account: account, library: library);
}

Future<void> _fill(WidgetTester tester) async {
  await tester.enterText(find.byKey(_username), 'reader');
  await tester.enterText(find.byKey(_password), 'test-only-password');
}

Future<void> _submit(WidgetTester tester) async {
  await tester.ensureVisible(find.byKey(_login));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(_login));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadReviewFonts);
  setUp(() => SharedPreferences.setMockInitialValues({'reduceMotion': true}));

  testWidgets('system autofill fills username and password as one credential', (
    tester,
  ) async {
    String? submitted;
    final fixture = await _open(
      tester,
      login: (action) async {
        submitted = action;
        return '1';
      },
    );
    final userField = tester.widget<TextField>(find.byKey(_username));
    final passwordField = tester.widget<TextField>(find.byKey(_password));
    expect(userField.autofillHints, [AutofillHints.username]);
    expect(passwordField.autofillHints, [AutofillHints.password]);
    expect(passwordField.keyboardType, TextInputType.visiblePassword);
    expect(passwordField.textInputAction, TextInputAction.done);
    final group = AutofillGroup.of(tester.element(find.byKey(_password)));
    expect(group.autofillClients.length, 2);

    await tester.showKeyboard(find.byKey(_username));
    final configs = tester.testTextInput.setClientArgs!['fields'] as List;
    final fields = <String, String>{
      for (final config in configs)
        (config['autofill']['hints'] as List).single as String:
            config['autofill']['uniqueIdentifier'] as String,
    };
    expect(fields.keys, containsAll(['username', 'password']));
    expect(
      tester.testTextInput.log.map((call) => call.method),
      contains('TextInput.requestAutofill'),
    );
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      SystemChannels.textInput.name,
      SystemChannels.textInput.codec.encodeMethodCall(
        MethodCall('TextInputClient.updateEditingStateWithTag', [
          -1,
          {
            fields['username']!: const TextEditingValue(
              text: 'reader@example.net',
            ).toJSON(),
            fields['password']!: const TextEditingValue(
              text: 'test-only-password',
            ).toJSON(),
          },
        ]),
      ),
      (_) {},
    );
    await tester.pump();
    expect(userField.controller!.text, 'reader@example.net');
    expect(passwordField.controller!.text, 'test-only-password');
    await tester.ensureVisible(find.byTooltip('显示密码'));
    await tester.tap(find.byTooltip('显示密码'));
    await tester.pump();
    expect(tester.widget<TextField>(find.byKey(_password)).obscureText, false);
    expect(
      group.autofillClients.map((client) => client.autofillId),
      containsAll(fields.values),
    );
    await tester.showKeyboard(find.byKey(_password));
    tester.testTextInput.log.clear();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(Uri.splitQueryString(submitted!), {
      'action': 'loginemail',
      'username': 'reader@example.net',
      'password': 'test-only-password',
    });
    expect(_finished(tester), [true]);
    expect(passwordField.controller!.text, isEmpty);
    await tester.pumpWidget(const SizedBox());
    fixture.account.dispose();
    fixture.library.dispose();
  });

  testWidgets('save waits for accepted login and precedes clearing the form', (
    tester,
  ) async {
    final reply = Completer<String>();
    final fixture = await _open(tester, login: (_) => reply.future);
    await _fill(tester);
    final password = tester
        .widget<TextField>(find.byKey(_password))
        .controller!;
    final input = _SaveObserver(() => password.text);
    TextInput.setInputControl(input);
    addTearDown(TextInput.restorePlatformInputControl);
    tester.testTextInput.log.clear();
    await _submit(tester);
    expect(input.finished, isEmpty);
    expect(password.text, 'test-only-password');
    expect(fixture.account.busy, true);
    reply.complete('1');
    await tester.pumpAndSettle();
    expect(input.finished, [(true, 'test-only-password')]);
    expect(password.text, isEmpty);
    expect(find.text('读者'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    fixture.account.dispose();
    fixture.library.dispose();
  });

  testWidgets('rejected password is cancelled and a corrected retry can save', (
    tester,
  ) async {
    var attempts = 0;
    final fixture = await _open(
      tester,
      login: (_) async => ++attempts == 1 ? '3' : '1',
    );
    await _fill(tester);
    tester.testTextInput.log.clear();
    await _submit(tester);
    expect(_finished(tester), [false]);
    expect(find.text('密码不正确'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byKey(_password)).controller!.text,
      isEmpty,
    );
    await tester.enterText(find.byKey(_password), 'correct-test-password');
    tester.testTextInput.log.clear();
    await _submit(tester);
    expect(_finished(tester), [true]);
    expect(fixture.account.authenticated, true);
    await tester.pumpWidget(const SizedBox());
    fixture.account.dispose();
    fixture.library.dispose();
  });

  testWidgets(
    'accepted credentials can save when optional profile is offline',
    (tester) async {
      final fixture = await _open(
        tester,
        profile: (_) async => throw StateError('offline'),
      );
      await _fill(tester);
      tester.testTextInput.log.clear();
      await _submit(tester);
      expect(fixture.account.authenticated, true);
      expect(fixture.account.error, isNotNull);
      expect(_finished(tester), [true]);
      await tester.pumpWidget(const SizedBox());
      fixture.account.dispose();
      fixture.library.dispose();
    },
  );

  testWidgets('leaving an unsubmitted login never offers to save credentials', (
    tester,
  ) async {
    final fixture = await _open(tester);
    await _fill(tester);
    tester.testTextInput.log.clear();
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(_finished(tester), [false]);
    fixture.account.dispose();
    fixture.library.dispose();
  });

  testWidgets(
    'an expired login session does not save its rejected credentials',
    (tester) async {
      final fixture = await _open(tester, profile: (_) async => '4');
      await _fill(tester);
      tester.testTextInput.log.clear();
      await _submit(tester);
      expect(fixture.account.authenticated, false);
      expect(_finished(tester), [false]);
      expect(
        tester.widget<TextField>(find.byKey(_password)).controller!.text,
        isEmpty,
      );
      await tester.pumpWidget(const SizedBox());
      fixture.account.dispose();
      fixture.library.dispose();
    },
  );

  testWidgets('late login cannot finish a different page autofill context', (
    tester,
  ) async {
    final reply = Completer<String>();
    final fixture = await _open(tester, login: (_) => reply.future);
    await _fill(tester);
    await _submit(tester);
    tester.testTextInput.log.clear();
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: AutofillGroup(
            onDisposeAction: AutofillContextAction.cancel,
            child: TextField(autofillHints: [AutofillHints.email]),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(_finished(tester), [false]);
    await tester.showKeyboard(find.byType(TextField));
    tester.testTextInput.log.clear();
    reply.complete('1');
    await tester.pumpAndSettle();
    expect(_finished(tester), isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    fixture.account.dispose();
    fixture.library.dispose();
  });

  for (final brightness in Brightness.values) {
    testWidgets('compact ${brightness.name} credential form keeps its layout', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final boundary = GlobalKey();
      final fixture = await _open(
        tester,
        boundary: boundary,
        brightness: brightness,
        textScale: 1.3,
      );
      await tester.ensureVisible(find.byKey(_login));
      await tester.pumpAndSettle();
      expect(find.text('用户名 / 邮箱'), findsOneWidget);
      expect(find.text('密码'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await captureReview(
        tester,
        boundary,
        'account-autofill-${brightness.name}',
      );
      await tester.pumpWidget(const SizedBox());
      fixture.account.dispose();
      fixture.library.dispose();
    });
  }
}

class _SaveObserver with TextInputControl {
  _SaveObserver(this.password);
  final String Function() password;
  final finished = <(bool, String)>[];

  @override
  void finishAutofillContext({bool shouldSave = true}) {
    finished.add((shouldSave, password()));
  }
}
