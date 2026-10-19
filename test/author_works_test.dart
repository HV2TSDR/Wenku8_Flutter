import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/author_works_page.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/legacy_wenku_repository.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/local_books.dart';
import 'package:wenku8_flutter/network_status.dart';
import 'package:wenku8_flutter/offline_cache.dart';
import 'package:wenku8_flutter/offline_repository.dart';
import 'package:wenku8_flutter/pages.dart';

import 'support/visual_review.dart';

Novel _book(int id, String title, {String author = '水泽梦'}) => Novel(
  id: id,
  title: title,
  author: author,
  genre: '轻小说',
  summary: '故事与书页。',
  colors: const [Color(0xffaaa9ae), Color(0xff747780)],
  chapters: [NovelChapter('第一章', '窗外的风掠过书页。', id: id * 1000 + 1)],
);

class _AuthorSource extends DemoNovelRepository {
  final books = [
    _book(71, '星轨之间'),
    _book(72, '晨光来信'),
    _book(73, '另一位作者', author: '其他作者'),
  ];
  final authorCalls = <String>[];
  @override
  Future<NovelPage> authorPage(
    String author, {
    int page = 1,
    bool refresh = false,
  }) async {
    authorCalls.add(author);
    return NovelPage.fromItems(
      books.where((b) => sameNovelAuthor(b.author, author)).toList(),
      page,
    );
  }

  @override
  Future<Novel?> find(int id) async =>
      books.where((b) => b.id == id).firstOrNull;
  @override
  Future<List<NovelChapter>> chapters(int id) async =>
      (await find(id))?.chapters ?? [];
}

void main({
  bool native = false,
  Future<void> Function(WidgetTester, GlobalKey, String)? capture,
}) {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (!native) setUpAll(loadReviewFonts);
  setUp(() => SharedPreferences.setMockInitialValues({'reduceMotion': true}));

  test(
    'author requests are separate from title search, bounded and paginated',
    () async {
      final actions = <String>[];
      var active = 0, peak = 0, revision = 0;
      final source = LegacyWenkuRepository(
        request: (action) async {
          actions.add(action);
          final p = Uri.splitQueryString(action);
          if (p['action'] == 'search') {
            final start = p['searchtype'] == 'author'
                ? 1 + revision * 100
                : 501;
            return '<result>${List.generate(25, (i) => '<item aid="${start + i}"/>').join()}</result>';
          }
          active++;
          if (peak < active) peak = active;
          await Future<void>.delayed(const Duration(milliseconds: 1));
          active--;
          return '<metadata><data name="Title" value="作品 ${p['aid']}"/><data name="Author" value="名 &amp; 作者"/></metadata>';
        },
      );
      final first = await source.authorPage(' 名 & 作者 ');
      expect(first.totalItems, 25);
      expect(first.items.map((b) => b.id), List.generate(20, (i) => i + 1));
      expect(
        actions.where((a) => a.contains('searchtype=articlename')),
        isEmpty,
      );
      final second = await source.authorPage('名 & 作者', page: 2);
      expect(second.items.map((b) => b.id), [21, 22, 23, 24, 25]);
      expect(second.hasMore, isFalse);
      expect(actions.where((a) => a.startsWith('action=search')).length, 1);
      expect(peak, lessThanOrEqualTo(4));
      await source.searchPage('名 & 作者');
      expect(
        actions.where((a) => a.contains('searchtype=articlename')).length,
        1,
      );
      revision++;
      expect(
        (await source.authorPage('名 & 作者', refresh: true)).items.first.id,
        101,
      );
      final before = actions.length;
      expect((await source.authorPage('  ')).items, isEmpty);
      expect(actions.length, before);
    },
  );

  test(
    'local author works stay in the local library and offline works must be cached',
    () async {
      final root = await Directory.systemTemp.createTemp('wenku-author-');
      addTearDown(() => root.delete(recursive: true));
      final local = LocalBookStore(Directory('${root.path}/local'));
      final cache = OfflineCacheStore(Directory('${root.path}/cache'));
      final source = _AuthorSource();
      final network = NetworkStatus(initial: NetworkReachability.offline);
      final repository = OfflineNovelRepository(
        remote: source,
        cache: cache,
        local: local,
        network: network,
      );
      addTearDown(local.dispose);
      addTearDown(cache.dispose);
      addTearDown(network.dispose);
      addTearDown(repository.dispose);
      final imported = await local.import(
        LocalBookInput('手边的故事.txt', utf8.encode('第一章\n正文。')),
      );
      await local.updateMetadata(
        imported.id,
        title: imported.title,
        author: '水泽梦',
        summary: imported.summary,
      );
      final localOnly = await AuthorWorksRepository(
        repository,
        '水泽梦',
        localOnly: true,
      ).browse();
      expect(localOnly.items.map((b) => b.id), [imported.id]);
      expect(source.authorCalls, isEmpty);
      final cached = source.books.first;
      await cache.saveBook(cached, epoch: cache.epochFor(cached.id));
      await cache.saveChapter(
        cached.id,
        cached.chapters.first.id,
        '正文',
        epoch: cache.epochFor(cached.id),
      );
      await cache.saveBook(
        source.books[1],
        epoch: cache.epochFor(source.books[1].id),
      );
      final offline = await repository.authorPage('水泽梦');
      expect(offline.items.map((b) => b.id), [cached.id, imported.id]);
      expect(source.authorCalls, isEmpty);
    },
  );

  for (final width in [320.0, 390.0, 1280.0]) {
    testWidgets('author entry opens works and another book at width $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, width > 1000 ? 800 : 892);
      tester.view.devicePixelRatio = 1;
      tester.view.padding = const FakeViewPadding(top: 28, bottom: 24);
      tester.view.viewPadding = tester.view.padding;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.view.resetViewPadding);
      final state = await LibraryState.load();
      addTearDown(state.dispose);
      final source = _AuthorSource(), key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: novelTheme(
              width == 320 ? Brightness.dark : Brightness.light,
            ),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(width == 320 ? 1.3 : 1)),
              child: child!,
            ),
            home: DetailPage(
              novel: source.books.first,
              state: state,
              repository: source,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('detail-author-works')),
          matching: find.text('水泽梦'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AuthorWorksPage), findsOneWidget);
      expect(find.text('作者作品'), findsOneWidget);
      expect(find.text('2 部作品'), findsOneWidget);
      expect(find.text('另一位作者'), findsNothing);
      expect(source.authorCalls, ['水泽梦']);
      if (capture != null) {
        await capture(tester, key, 'author-works-${width.toInt()}');
      } else {
        await captureReview(tester, key, 'author-works-${width.toInt()}');
      }
      await tester.tap(
        find
            .descendant(
              of: find.byWidgetPredicate(
                (w) => w is NovelRow && w.novel.id == 72,
              ),
              matching: find.text('晨光来信'),
            )
            .last,
      );
      await tester.pumpAndSettle();
      expect(
        find.byWidgetPredicate((w) => w is DetailPage && w.novel.id == 72),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
