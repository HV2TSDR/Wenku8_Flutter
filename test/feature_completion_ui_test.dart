import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/app_interactions.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/archive_carousel.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/feature_pages.dart';
import 'package:wenku8_flutter/legacy_cover.dart';
import 'package:wenku8_flutter/legacy_import_page.dart';
import 'package:wenku8_flutter/legacy_transport.dart';
import 'package:wenku8_flutter/legacy_wenku_repository.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/local_platform.dart';
import 'package:wenku8_flutter/reader_illustrations.dart';
import 'package:wenku8_flutter/review_pages.dart';
import 'package:wenku8_flutter/wenku_reviews.dart';

import 'feature_completion_state_test.dart' show AccountFixture, reviewXml;
import 'support/cover_fixture.dart';
import 'support/offline_fixture.dart';

typedef FeatureCapture =
    Future<void> Function(WidgetTester tester, GlobalKey key, String name);

Future<void> _pump(
  WidgetTester tester,
  Widget page, {
  GlobalKey? key,
  Brightness brightness = Brightness.light,
}) async {
  await tester.pumpWidget(
    RepaintBoundary(
      key: key,
      child: MaterialApp(theme: novelTheme(brightness), home: page),
    ),
  );
  await tester.pumpAndSettle();
}

void main({FeatureCapture? capture}) {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('wide glass actions respond across the complete visible plate', (
    tester,
  ) async {
    var taps = 0;
    const buttonKey = ValueKey('wide-glass-action');
    await _pump(
      tester,
      Scaffold(
        body: Center(
          child: SizedBox(
            width: 600,
            child: GlassTextButton(
              key: buttonKey,
              onPressed: () => taps++,
              child: const Text('完整触摸区域'),
            ),
          ),
        ),
      ),
    );
    final rect = tester.getRect(find.byKey(buttonKey));
    for (final point in [
      rect.center,
      rect.centerLeft + const Offset(40, 0),
      rect.centerRight - const Offset(40, 0),
    ]) {
      await tester.tapAt(point);
      await tester.pumpAndSettle();
    }
    expect(taps, 3);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'publication login gate never becomes an empty category and resumes after login',
    (tester) async {
      final fixture = AccountFixture();
      final state = await LibraryState.load();
      final repository = LegacyWenkuRepository(
        request: (_) async => '<metadata><item sort="1">文库甲</item></metadata>',
        publicationRequest: (_) async => fixture.session
            ? '<result><page num="1"/><item aid="71"><data name="Title" value="作品 71"/></item></result>'
            : '4',
      );
      await _pump(
        tester,
        PublicationLibraryPage(
          catalog: repository,
          repository: repository,
          state: state,
          account: fixture.account,
        ),
      );
      expect(find.text('此分类需要文库账号'), findsOneWidget);
      expect(find.text('暂无书籍'), findsNothing);
      await tester.tap(find.text('登录账号'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('account-username')),
        'reader',
      );
      await tester.enterText(
        find.byKey(const ValueKey('account-password')),
        'password',
      );
      await tester.ensureVisible(find.byKey(const ValueKey('account-login')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('account-login')));
      await tester.pumpAndSettle();
      expect(fixture.account.authenticated, isTrue);
      await tester.tap(
        find.byWidgetPredicate(
          (widget) => widget is GlassIconButton && widget.label == '返回',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ArchiveFileCarousel), findsOneWidget);
      expect(find.text('此分类需要文库账号'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      fixture.account.dispose();
      state.dispose();
    },
  );

  testWidgets(
    'publication refreshes when identity changes without leaving the page',
    (tester) async {
      final fixture = AccountFixture();
      final state = await LibraryState.load();
      var reads = 0;
      final repository = LegacyWenkuRepository(
        request: (_) async => '<metadata><item sort="1">文库甲</item></metadata>',
        publicationRequest: (_) async {
          reads++;
          return fixture.session
              ? '<result><page num="1"/><item aid="71"><data name="Title" value="作品 71"/></item></result>'
              : '4';
        },
      );
      await _pump(
        tester,
        PublicationLibraryPage(
          catalog: repository,
          repository: repository,
          state: state,
          account: fixture.account,
        ),
      );
      expect(find.text('此分类需要文库账号'), findsOneWidget);
      await fixture.login();
      await tester.pumpAndSettle();
      expect(reads, greaterThanOrEqualTo(2));
      expect(find.text('此分类需要文库账号'), findsNothing);
      expect(find.byType(ArchiveFileCarousel), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      fixture.account.dispose();
      state.dispose();
    },
  );
  testWidgets(
    'a rejected category request does not mislabel an authenticated account as a guest',
    (tester) async {
      final fixture = AccountFixture();
      await fixture.login();
      final state = await LibraryState.load();
      final repository = LegacyWenkuRepository(
        request: (_) async => '<metadata><item sort="1">文库甲</item></metadata>',
        publicationRequest: (_) async => '4',
      );
      await _pump(
        tester,
        PublicationLibraryPage(
          catalog: repository,
          repository: repository,
          state: state,
          account: fixture.account,
        ),
      );
      expect(find.text('分类暂未读取成功'), findsOneWidget);
      expect(find.text('此分类需要文库账号'), findsNothing);
      expect(fixture.account.authenticated, isTrue);
      expect(find.text('检查账号并重试'), findsNothing);
      await tester.tap(find.text('重新加载'));
      await tester.pumpAndSettle();
      expect(find.byType(WenkuAccountPage), findsNothing);
      expect(find.text('分类暂未读取成功'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      fixture.account.dispose();
      state.dispose();
    },
  );
  testWidgets(
    'account login clears password and cloud import preserves local progress',
    (tester) async {
      final fixture = AccountFixture();
      final state = await LibraryState.load();
      final repository = OfflineFixtureRepository();
      await state.setShelfMembership(71, true, novel: repository.books[71]);
      await state.setChapter(71, 2);
      final key = GlobalKey();
      await _pump(
        tester,
        WenkuAccountPage(
          account: fixture.account,
          state: state,
          repository: repository,
        ),
        key: key,
      );
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await tester.enterText(
        find.byKey(const ValueKey('account-username')),
        'reader',
      );
      await tester.enterText(
        find.byKey(const ValueKey('account-password')),
        'password',
      );
      await tester.ensureVisible(find.byKey(const ValueKey('account-login')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<GlassTextButton>(
              find.byKey(const ValueKey('account-login')),
            )
            .onPressed,
        isNotNull,
      );
      await tester.tap(find.byKey(const ValueKey('account-login')));
      await tester.pumpAndSettle();
      expect(
        fixture.account.authenticated,
        isTrue,
        reason: 'calls=${fixture.calls}; error=${fixture.account.error}',
      );
      expect(find.text('读者'), findsOneWidget);
      expect(fixture.account.authenticated, isTrue);
      if (capture != null) await capture(tester, key, 'account-profile');
      fixture.ids.add(72);
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('account-cloud')),
          matching: find.byType(InkWell),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('作品 71'), findsOneWidget);
      expect(find.text('作品 72'), findsOneWidget);
      if (capture != null) await capture(tester, key, 'cloud-bookshelf');
      await tester.tap(find.byKey(const ValueKey('cloud-download')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('合并收藏'));
      await tester.pumpAndSettle();
      expect(state.shelf, {71, 72});
      expect(state.chapterFor(71), 2);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      fixture.account.dispose();
      state.dispose();
    },
  );

  testWidgets(
    'failed login shows error and never displays a fabricated profile',
    (tester) async {
      final fixture = AccountFixture()..loginCode = 3;
      final state = await LibraryState.load();
      await _pump(
        tester,
        WenkuAccountPage(
          account: fixture.account,
          state: state,
          repository: const DemoNovelRepository(),
        ),
      );
      await tester.enterText(
        find.byKey(const ValueKey('account-username')),
        'reader',
      );
      await tester.enterText(
        find.byKey(const ValueKey('account-password')),
        'wrong',
      );
      await tester.ensureVisible(find.byKey(const ValueKey('account-login')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<GlassTextButton>(
              find.byKey(const ValueKey('account-login')),
            )
            .onPressed,
        isNotNull,
      );
      await tester.tap(find.byKey(const ValueKey('account-login')));
      await tester.pumpAndSettle();
      expect(fixture.account.error, '密码不正确', reason: '${fixture.calls}');
      expect(find.text('密码不正确'), findsOneWidget);
      expect(find.byKey(const ValueKey('account-cloud')), findsNothing);
      final password = tester
          .widget<TextField>(find.byKey(const ValueKey('account-password')))
          .controller!;
      expect(password.text, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      fixture.account.dispose();
      state.dispose();
    },
  );

  for (final brightness in Brightness.values) {
    testWidgets(
      'publication ${brightness.name} reuses loop shelf, matching skeleton and paging',
      (tester) async {
        final bytes = await tester.runAsync(coverFixtureBytes);
        final state = await LibraryState.load();
        for (var id = 100; id < 280; id++) {
          LegacyCover.seedLocalBytes(id, bytes!);
        }
        final hold = Completer<String>();
        var held = true;
        final repository = LegacyWenkuRepository(
          request: (action) async {
            if (action.contains('item=sort')) {
              return '<metadata><item sort="1">文库甲</item><item sort="2">文库乙</item></metadata>';
            }
            if (held) return hold.future;
            final params = Uri.splitQueryString(action);
            final library = int.parse(params['sort']!);
            final page = int.parse(params['page']!);
            return '<result><page num="3"/>${List.generate(20, (index) {
              final id = library * 100 + (page - 1) * 20 + index;
              return '<item aid="$id"><data name="Title" value="档案 $id"/></item>';
            }).join()}</result>';
          },
        );
        final key = GlobalKey();
        await _pump(
          tester,
          PublicationLibraryPage(
            catalog: repository,
            repository: repository,
            state: state,
          ),
          key: key,
          brightness: brightness,
        );
        expect(find.byType(ArchiveShelfSkeleton), findsOneWidget);
        expect(find.text('文库甲'), findsOneWidget);
        if (capture != null) {
          await capture(tester, key, 'publication-${brightness.name}-skeleton');
        }
        held = false;
        hold.complete(
          '<result><page num="3"/>${List.generate(20, (index) => '<item aid="${100 + index}"><data name="Title" value="档案 ${100 + index}"/></item>').join()}</result>',
        );
        await tester.pumpAndSettle();
        final shelf = tester.widget<ArchiveFileCarousel>(
          find.byType(ArchiveFileCarousel),
        );
        expect(shelf.books.length, 10);
        expect(find.byType(ArchiveShelfSkeleton), findsNothing);
        if (capture != null) {
          await capture(tester, key, 'publication-${brightness.name}-ready');
        }
        final control = find.byWidgetPredicate(
          (widget) => widget is GlassIconButton && widget.label == '分类与排序',
        );
        await tester.tap(control);
        await tester.pumpAndSettle();
        await tester.tap(find.text('文库乙'));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<ArchiveFileCarousel>(find.byType(ArchiveFileCarousel))
              .books
              .first
              .id,
          200,
        );
        expect(find.text('文库甲'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        state.dispose();
      },
    );
  }

  testWidgets(
    'illustration uses static skeleton, one arrival and zoom gallery',
    (tester) async {
      final held = Completer<Uint8List>();
      final bytes = await tester.runAsync(coverFixtureBytes);
      var calls = 0;
      final cache = ReaderIllustrationCache(
        request: (_) {
          calls++;
          return held.future;
        },
      );
      final key = GlobalKey();
      await _pump(
        tester,
        Scaffold(
          body: Center(
            child: SizedBox(
              width: 300,
              height: 440,
              child: ReaderIllustration(
                url: 'https://img.wenku8.com/a.jpg',
                cache: cache,
              ),
            ),
          ),
        ),
        key: key,
      );
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byType(LoadingSkeleton), findsOneWidget);
      if (capture != null) await capture(tester, key, 'reader-image-skeleton');
      held.complete(bytes!);
      await tester.pumpAndSettle();
      await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsOneWidget);
      expect(find.byType(LoadingSkeleton), findsNothing);
      if (capture != null) await capture(tester, key, 'reader-image-ready');
      await _pump(
        tester,
        ReaderIllustrationGallery(
          urls: const ['https://img.wenku8.com/a.jpg'],
          initialUrl: 'https://img.wenku8.com/a.jpg',
          cache: cache,
        ),
        key: key,
      );
      expect(find.byType(InteractiveViewer), findsOneWidget);
      expect(calls, 1);
      expect(tester.takeException(), isNull);
      if (capture != null) await capture(tester, key, 'reader-image-gallery');
      await tester.pumpWidget(const SizedBox.shrink());
      cache.clearMemory();
    },
  );

  testWidgets('legacy import is previewed before any local state change', (
    tester,
  ) async {
    final state = await LibraryState.load();
    await state.addShelfIds([71]);
    final key = GlobalKey();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      LocalPlatform.channel,
      (call) async {
        expect(call.method, 'importLegacyData');
        return {
          'documents': {
            'bookshelf_local.wk8': {'text': '72||73', 'modifiedAt': 1000},
            'read_saves_v1.wk8': {'text': '72:1:72002:3:4', 'modifiedAt': 1000},
          },
          'skippedFiles': 0,
        };
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        LocalPlatform.channel,
        null,
      ),
    );
    await _pump(tester, LegacyImportPage(state: state), key: key);
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('legacy-choose')),
        matching: find.byType(InkWell),
      ),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(
      () async => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    expect(state.shelf, {71});
    expect(find.text('导入预览'), findsOneWidget);
    if (capture != null) await capture(tester, key, 'legacy-import-preview');
    await tester.ensureVisible(find.byKey(const ValueKey('legacy-merge')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<GlassTextButton>(find.byKey(const ValueKey('legacy-merge')))
          .onPressed,
      isNotNull,
    );
    await tester.tap(find.byKey(const ValueKey('legacy-merge')));
    await tester.pumpAndSettle();
    expect(state.shelf, {71, 72, 73});
    expect(state.positionFor(72)!.chapterId, 72002);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });

  testWidgets('reviews load in sequence, paginate and expose concrete retry', (
    tester,
  ) async {
    final fixture = AccountFixture();
    await fixture.login();
    final state = await LibraryState.load();
    var calls = 0;
    final feed = WenkuReviewFeed(
      id: 71,
      request: (_) async {
        if (++calls == 2) throw StateError('offline');
        return reviewXml(calls == 1 ? 81 : 82);
      },
    );
    final key = GlobalKey();
    await _pump(
      tester,
      WenkuReviewsPage(
        novel: offlineFixtureBook(71),
        account: fixture.account,
        state: state,
        repository: const DemoNovelRepository(),
        feed: feed,
      ),
      key: key,
    );
    expect(find.text('书评 81'), findsOneWidget);
    if (capture != null) await capture(tester, key, 'reviews-ready');
    await tester.ensureVisible(find.text('更多书评'));
    await tester.tap(find.text('更多书评'));
    await tester.pumpAndSettle();
    expect(find.text('重试书评'), findsOneWidget);
    expect(find.text('书评 81'), findsOneWidget);
    await tester.tap(find.text('重试书评'));
    await tester.pumpAndSettle();
    expect(find.text('书评 82'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    feed.dispose();
    fixture.account.dispose();
    state.dispose();
  });

  testWidgets('review list opens complete thread, coalesces taps and reopens', (
    tester,
  ) async {
    final fixture = AccountFixture();
    final state = await LibraryState.load();
    final feed = WenkuReviewFeed(
      id: 71,
      request: (_) async => reviewXml(81, pages: 1),
    );
    final requests = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      LegacyTransport.channel,
      (call) async {
        if (call.method == 'hasSession') return false;
        if (call.method != 'request') {
          throw StateError('Unexpected bridge method ${call.method}');
        }
        final action = (call.arguments as Map)['action'] as String;
        requests.add(action);
        return '<result><page num="1"/>'
            '<item timestamp="20261005103000"><user uid="81">读者</user>'
            '<content>完整的书评正文\n第二段也必须保留。</content></item>'
            '<item timestamp="20261005113000"><user uid="82">回复者</user>'
            '<content>这是一条回复。</content></item></result>';
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        LegacyTransport.channel,
        null,
      ),
    );
    final key = GlobalKey();
    await _pump(
      tester,
      Scaffold(
        body: Builder(
          builder: (context) => GlassTextButton(
            child: const Text('打开书评'),
            onPressed: () => pushNovelPage<void>(
              context,
              WenkuReviewsPage(
                novel: offlineFixtureBook(71),
                account: fixture.account,
                state: state,
                repository: const DemoNovelRepository(),
                feed: feed,
              ),
              reduceMotion: false,
            ),
          ),
        ),
      ),
      key: key,
    );
    await tester.tap(find.text('打开书评'));
    await tester.pumpAndSettle();
    final card = tester.widget<ContentPanel>(
      find.byKey(const ValueKey('review-card-81')),
    );
    final cardPoint = tester.getCenter(find.text('书评 81'));
    await tester.tapAt(cardPoint);
    // On a real-clock binding a second pointer may hit the newly arrived page.
    // Re-enter the same originating action to test its navigation slot instead.
    card.onTap!();
    await tester.pumpAndSettle();
    for (
      var attempt = 0;
      attempt < 20 && find.text('完整的书评正文\n第二段也必须保留。').evaluate().isEmpty;
      attempt++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
    }
    if (capture != null) await capture(tester, key, 'review-thread-ready');
    expect(find.text('完整的书评正文\n第二段也必须保留。'), findsOneWidget);
    expect(find.text('这是一条回复。'), findsOneWidget);
    expect(requests, ['action=review&do=show&rid=81&page=1&t=0']);
    final back = find.byWidgetPredicate(
      (widget) => widget is GlassIconButton && widget.label == '返回',
    );
    await tester.tap(back);
    await tester.pumpAndSettle();
    expect(find.text('作品评论'), findsOneWidget);
    await tester.tap(find.text('书评 81'));
    await tester.pumpAndSettle();
    for (
      var attempt = 0;
      attempt < 20 && find.text('这是一条回复。').evaluate().isEmpty;
      attempt++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
    }
    expect(find.text('这是一条回复。'), findsOneWidget);
    expect(requests.length, 2);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    feed.dispose();
    fixture.account.dispose();
    state.dispose();
  });

  testWidgets(
    'review draft survives reopening and successful submit is not duplicated',
    (tester) async {
      final fixture = AccountFixture();
      await fixture.login();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        LegacyTransport.channel,
        (call) async {
          expect(call.method, 'encodeReview');
          return 'ENCODED';
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          LegacyTransport.channel,
          null,
        ),
      );
      Widget page() => ReviewComposerPage(
        novel: offlineFixtureBook(71),
        account: fixture.account,
        reduceMotion: false,
      );
      final key = GlobalKey();
      await _pump(tester, page(), key: key);
      await tester.enterText(
        find.byKey(const ValueKey('review-title')),
        '我的阅读记录',
      );
      await tester.enterText(
        find.byKey(const ValueKey('review-body')),
        '这是一段不少于十个字的真实阅读感受。',
      );
      await tester.pump(const Duration(milliseconds: 450));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await _pump(tester, page(), key: key);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('review-title')))
            .controller!
            .text,
        '我的阅读记录',
      );
      if (capture != null) await capture(tester, key, 'review-draft');
      await tester.ensureVisible(find.byKey(const ValueKey('review-submit')));
      await tester.tap(find.byKey(const ValueKey('review-submit')));
      await tester.pumpAndSettle();
      expect(
        fixture.calls
            .where((action) => action.startsWith('action=review&do=post'))
            .length,
        1,
      );
      expect(
        (await SharedPreferences.getInstance()).getString(
          'review_draft_81_71_0_body',
        ),
        isNull,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      fixture.account.dispose();
    },
  );

  testWidgets(
    'thread reply submits to its RID and refreshes only after success',
    (tester) async {
      final fixture = AccountFixture();
      await fixture.login();
      final state = await LibraryState.load();
      var requests = 0;
      final feed = WenkuReviewFeed(
        id: 81,
        replies: true,
        request: (_) async {
          requests++;
          return '<result><page num="1"/><item timestamp="20261005103000"><user uid="81">读者</user><content>原始正文</content></item></result>';
        },
      );
      var posted = 0;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        LegacyTransport.channel,
        (call) async {
          expect(call.method, 'encodeReview');
          return 'ENCODED';
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          LegacyTransport.channel,
          null,
        ),
      );
      await _pump(
        tester,
        WenkuReviewsPage(
          novel: offlineFixtureBook(71),
          account: fixture.account,
          state: state,
          repository: const DemoNovelRepository(),
          feed: feed,
          thread: WenkuReviewPage.parse(reviewXml(81)).items.single,
          onPosted: () => posted++,
        ),
      );
      await tester.tap(find.byKey(const ValueKey('review-compose')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('review-title')), findsNothing);
      await tester.enterText(
        find.byKey(const ValueKey('review-body')),
        '这是回复原书评的一段完整内容。',
      );
      await tester.ensureVisible(find.byKey(const ValueKey('review-submit')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('review-submit')));
      await tester.pumpAndSettle();
      expect(
        fixture.calls.where(
          (action) => action.startsWith('action=review&do=reply'),
        ),
        ['action=review&do=reply&rid=81&content=ENCODED'],
      );
      expect(posted, 1);
      expect(requests, 2);
      expect(find.text('原始正文'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      feed.dispose();
      fixture.account.dispose();
      state.dispose();
    },
  );
}
