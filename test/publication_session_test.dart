import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:wenku8_flutter/wenku_account.dart';

import 'feature_completion_state_test.dart' show profileXml;

const _category = 'action=novellist&sort=1&page=1&t=0';
const _books = '<result><page num="1"/><item aid="71"/></result>';

void main() {
  test(
    'publication waits for session restoration before its first request',
    () async {
      final restored = Completer<bool>();
      final calls = <String>[];
      final account = WenkuAccount(
        hasSession: () => restored.future,
        clearSession: () async => fail('A valid account must not be cleared'),
        request: (action) async {
          calls.add(action);
          return action == 'action=userinfo' ? profileXml : _books;
        },
      );
      addTearDown(account.dispose);
      final result = account.readPublication(_category);
      await Future<void>.delayed(Duration.zero);
      expect(calls, isEmpty);
      restored.complete(true);
      expect(await result, _books);
      expect(calls, ['action=userinfo', _category]);
    },
  );

  test(
    'category refusal refreshes native account cookies and retries once',
    () async {
      final calls = <String>[];
      var categories = 0;
      final account = WenkuAccount(
        hasSession: () async => true,
        clearSession: () async =>
            fail('Category refusal is not account expiry'),
        request: (action) async {
          calls.add(action);
          if (action == 'action=userinfo') return profileXml;
          return ++categories == 1 ? '4' : _books;
        },
      );
      addTearDown(account.dispose);
      await account.initialize();
      calls.clear();
      expect(await account.readPublication(_category), _books);
      expect(calls, [_category, 'action=userinfo', _category]);
      expect(account.authenticated, isTrue);
      expect(account.profile!.score, 12);
    },
  );

  test(
    'persistent category-only rejection retains a valid profile without looping',
    () async {
      var categories = 0, cleared = 0;
      final account = WenkuAccount(
        hasSession: () async => true,
        clearSession: () async {
          cleared++;
        },
        request: (action) async {
          if (action == 'action=userinfo') return profileXml;
          categories++;
          return '4';
        },
      );
      addTearDown(account.dispose);
      expect(await account.readPublication(_category), '4');
      expect(categories, 2);
      expect(cleared, 0);
      expect(account.authenticated, isTrue);
      expect(account.profile!.displayName, '读者');
    },
  );

  test('a userinfo-confirmed expiry still clears an invalid session', () async {
    var expired = false, categories = 0, cleared = 0;
    final account = WenkuAccount(
      hasSession: () async => true,
      clearSession: () async {
        cleared++;
      },
      request: (action) async {
        if (action == 'action=userinfo') return expired ? '4' : profileXml;
        categories++;
        return '4';
      },
    );
    addTearDown(account.dispose);
    await account.initialize();
    expired = true;
    await expectLater(
      account.readPublication(_category),
      throwsA(isA<WenkuApiError>()),
    );
    expect(categories, 1);
    expect(cleared, 1);
    expect(account.authenticated, isFalse);
    expect(account.profile, isNull);
  });

  test('logout during a category read rejects its late response', () async {
    final reply = Completer<String>();
    final account = WenkuAccount(
      hasSession: () async => true,
      clearSession: () async {},
      request: (action) async {
        if (action == 'action=userinfo') return profileXml;
        if (action == _category) return reply.future;
        return '1';
      },
    );
    addTearDown(account.dispose);
    await account.initialize();
    final result = account.readPublication(_category);
    final checked = expectLater(result, throwsStateError);
    await Future<void>.delayed(Duration.zero);
    await account.logout();
    reply.complete(_books);
    await checked;
    expect(account.authenticated, isFalse);
  });
}
