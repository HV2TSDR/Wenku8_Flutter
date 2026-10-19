import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/archive_carousel.dart';
import 'package:wenku8_flutter/feature_pages.dart';
import 'package:wenku8_flutter/legacy_wenku_repository.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/wenku_account.dart';
import 'feature_completion_state_test.dart' show profileXml;

String _list(int page) =>
    '<result><page num="1"/><item aid="71"><data name="Title" value="真实接口结构"/><data name="Author" value="作者"/><data name="Tags" value="奇幻 冒险"/></item></result>';
Finder _back() => find.byWidgetPredicate(
  (widget) => widget is GlassIconButton && widget.label == '返回',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({'reduceMotion': true}));

  test(
    'publication cache cannot authorize a logged-out session or leak a late previous-session result',
    () async {
      var identity = 1, authenticated = true;
      final old = Completer<String>();
      var held = false, calls = 0;
      final repo = LegacyWenkuRepository(
        publicationSessionKey: () => (identity, authenticated),
        publicationRequest: (_) async {
          calls++;
          if (held) {
            held = false;
            return old.future;
          }
          return authenticated ? _list(1) : '4';
        },
      );
      await repo.browsePublication(1);
      await repo.browsePublication(1);
      expect(calls, 1);
      authenticated = false;
      identity++;
      await expectLater(
        repo.browsePublication(1),
        throwsA(isA<WenkuApiError>()),
      );
      expect(calls, 2);
      authenticated = true;
      identity++;
      held = true;
      final previous = repo.browsePublication(1);
      identity++;
      final current = await repo.browsePublication(1);
      old.complete(_list(1).replaceAll('真实接口结构', '旧会话书名'));
      await previous;
      expect((await repo.find(71))!.title, current.items.single.title);
      expect((await repo.browsePublication(1)).items.single.title, '真实接口结构');
      expect(calls, 4);
    },
  );

  testWidgets(
    'opening publication while restoring the account waits for its session',
    (tester) async {
      final restored = Completer<bool>();
      var reads = 0;
      final account = WenkuAccount(
        hasSession: () => restored.future,
        request: (action) async =>
            action == 'action=userinfo' ? profileXml : _list(1),
        clearSession: () async {},
      );
      final initialization = account.initialize();
      final library = LibraryState(await SharedPreferences.getInstance());
      final repo = LegacyWenkuRepository(
        request: (_) async => '<metadata><item sort="1">出版分类</item></metadata>',
        publicationRequest: (action) {
          reads++;
          return account.readPublication(action);
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: novelTheme(Brightness.light),
          home: PublicationLibraryPage(
            catalog: repo,
            repository: repo,
            state: library,
            account: account,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(reads, 0);
      restored.complete(true);
      await tester.pumpAndSettle();
      await initialization;
      expect(reads, 1);
      expect(find.byType(ArchiveFileCarousel), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      account.dispose();
      library.dispose();
    },
  );

  test(
    'normal login never submits the password to the separate website',
    () async {
      var session = false, websiteLogins = 0;
      final account = WenkuAccount(
        hasSession: () async => session,
        loginRequest: (_) async {
          session = true;
          return '1';
        },
        request: (_) async => profileXml,
        clearSession: () async {
          session = false;
        },
        publicationLogin: (_, _) async {
          websiteLogins++;
        },
      );
      addTearDown(account.dispose);
      await account.initialize();
      await account.login('reader', 'transient-test-value');
      expect(account.authenticated, true);
      expect(account.profile!.score, 12);
      expect(websiteLogins, 0);
    },
  );

  testWidgets(
    'publication login return waits for profile and refreshes exactly once with the same session',
    (tester) async {
      final profile = Completer<String>();
      var session = false, categoryReads = 0;
      final account = WenkuAccount(
        hasSession: () async => session,
        loginRequest: (_) async {
          session = true;
          return '1';
        },
        request: (action) async => action == 'action=userinfo'
            ? profile.future
            : session
            ? _list(1)
            : '4',
        clearSession: () async {
          session = false;
        },
        publicationLogin: (_, _) async {},
      );
      await account.initialize();
      final library = LibraryState(await SharedPreferences.getInstance());
      final repository = LegacyWenkuRepository(
        request: (_) async => '<metadata><item sort="1">出版分类</item></metadata>',
        publicationRequest: (action) async {
          categoryReads++;
          expect(action, 'action=novellist&sort=1&page=1&t=0');
          return account.readPublication(action);
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: novelTheme(Brightness.light),
          home: PublicationLibraryPage(
            catalog: repository,
            repository: repository,
            state: library,
            account: account,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('此分类需要文库账号'), findsOneWidget);
      expect(categoryReads, 1);
      await tester.tap(find.text('登录账号'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('account-username')),
        'reader',
      );
      await tester.enterText(
        find.byKey(const ValueKey('account-password')),
        'transient-test-value',
      );
      await tester.ensureVisible(find.byKey(const ValueKey('account-login')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('account-login')));
      await tester.pumpAndSettle();
      expect(account.authenticated, true);
      expect(account.busy, true);
      await tester.tap(_back());
      await tester.pumpAndSettle();
      expect(
        categoryReads,
        1,
        reason: 'Do not start a category request before login has finished',
      );
      profile.complete(profileXml);
      await tester.pumpAndSettle();
      expect(account.busy, false);
      expect(categoryReads, 2, reason: 'No second refresh on route return');
      expect(find.text('分类暂未读取成功'), findsNothing);
      final book = tester
          .widget<ArchiveFileCarousel>(find.byType(ArchiveFileCarousel))
          .books
          .single;
      expect(book.title, '真实接口结构');
      expect(book.tags, ['奇幻', '冒险']);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      account.dispose();
      library.dispose();
    },
  );

  testWidgets(
    'logging in from publication then returning after completion does not duplicate the list read',
    (tester) async {
      var session = false, reads = 0;
      final account = WenkuAccount(
        hasSession: () async => session,
        loginRequest: (_) async {
          session = true;
          return '1';
        },
        request: (action) async => action == 'action=userinfo'
            ? profileXml
            : session
            ? _list(1)
            : '4',
        clearSession: () async {
          session = false;
        },
        publicationLogin: (_, _) async {},
      );
      await account.initialize();
      final library = LibraryState(await SharedPreferences.getInstance());
      final repo = LegacyWenkuRepository(
        request: (_) async => '<metadata><item sort="1">出版分类</item></metadata>',
        publicationRequest: (action) {
          reads++;
          return account.readPublication(action);
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: novelTheme(Brightness.light),
          home: PublicationLibraryPage(
            catalog: repo,
            repository: repo,
            state: library,
            account: account,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('登录账号'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('account-username')),
        'reader',
      );
      await tester.enterText(
        find.byKey(const ValueKey('account-password')),
        'transient-test-value',
      );
      await tester.ensureVisible(find.byKey(const ValueKey('account-login')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('account-login')));
      await tester.pumpAndSettle();
      expect(
        reads,
        1,
        reason:
            'The covered category page does not prefetch while its login route is open',
      );
      await tester.tap(_back());
      await tester.pumpAndSettle();
      expect(reads, 2);
      expect(find.byType(ArchiveFileCarousel), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      account.dispose();
      library.dispose();
    },
  );

  test(
    'preauthenticated entry and retry use rich metadata without per-book or website requests',
    () async {
      final actions = <String>[];
      final account = WenkuAccount(
        hasSession: () async => true,
        request: (action) async {
          actions.add(action);
          return action == 'action=userinfo' ? profileXml : _list(1);
        },
        clearSession: () async {},
      );
      addTearDown(account.dispose);
      await account.initialize();
      var guestReads = 0;
      final repo = LegacyWenkuRepository(
        request: (_) async {
          guestReads++;
          throw StateError('No per-book hydration required');
        },
        publicationRequest: account.readPublication,
      );
      final result = await repo.browsePublication(1);
      expect(result.items.single.author, '作者');
      expect(result.items.single.tags, ['奇幻', '冒险']);
      await repo.browsePublication(1);
      expect(actions.length, 2);
      await repo.browsePublication(1, refresh: true);
      expect(actions.last, 'action=novellist&sort=1&page=1&t=0');
      expect(guestReads, 0);
    },
  );
}
