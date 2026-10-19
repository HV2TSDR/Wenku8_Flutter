import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/book_documents.dart';
import 'package:wenku8_flutter/book_search.dart';
import 'package:wenku8_flutter/bookshelf_scope.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/legacy_wenku_repository.dart';
import 'package:wenku8_flutter/library_search_repository.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/local_books.dart';
import 'package:wenku8_flutter/network_status.dart';
import 'package:wenku8_flutter/novel_feed_controller.dart';
import 'package:wenku8_flutter/offline_cache.dart';
import 'package:wenku8_flutter/offline_repository.dart';
import 'package:wenku8_flutter/web_publication_catalog.dart';
import 'package:wenku8_flutter/wenku_account.dart';
import 'feature_completion_state_test.dart' show profileXml;

const _book = Novel(
  id: 71,
  title: '作者的奇幻物语',
  author: '另一位作者',
  genre: '奇幻 女性视角',
  summary: '',
  colors: [Colors.grey, Colors.black],
);
String _results(int id) =>
    '<result><item aid="$id"><data name="Title" value="小说$id"/><data name="Author" value="作者"/><data name="Tags" value="奇幻 女性视角"/></item></result>';

class _DelayedSearch extends DemoNovelRepository {
  final calls = <BookSearchField>[];
  final old = Completer<NovelPage>();
  @override
  Future<NovelPage> searchFilteredPage(
    String query, {
    BookSearchField field = BookSearchField.all,
    int page = 1,
    bool refresh = false,
  }) {
    calls.add(field);
    return field == BookSearchField.title
        ? old.future
        : Future.value(NovelPage.fromItems([_book], page));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('field filters are partial within the selected metadata only', () {
    bool matches(String query, BookSearchField field) =>
        BookSearch(query, field: field).matches(
          title: _book.title,
          author: _book.author,
          tags: _book.genre,
          id: '71',
        );
    expect(matches('奇幻', BookSearchField.tags), true);
    expect(matches('女性', BookSearchField.tags), true);
    expect(matches('另一', BookSearchField.title), false);
    expect(matches('另一', BookSearchField.author), true);
    expect(matches('作者的', BookSearchField.author), false);
    expect(matches('7', BookSearchField.id), false);
    expect(matches('７１', BookSearchField.id), true);
  });
  test('online tag search uses plural tags and reuses rich metadata', () async {
    final calls = <String>[];
    final repo = LegacyWenkuRepository(
      request: (action) async {
        calls.add(action);
        return _results(71);
      },
    );
    final page = await repo.searchFilteredPage(
      '女性视角',
      field: BookSearchField.tags,
    );
    expect(page.items.single.title, '小说71');
    expect(page.items.single.tags, ['奇幻', '女性视角']);
    expect(calls, [
      'action=search&searchtype=tags&searchkey=${Uri.encodeQueryComponent('女性视角')}&t=0',
    ]);
    expect(
      (await repo.searchFilteredPage(
        '女性视角',
        field: BookSearchField.tags,
      )).items.single.id,
      71,
    );
    expect(calls.length, 1);
  });
  test(
    'all search unions three independent fields; specific searches never broaden',
    () async {
      final calls = <String>[];
      final repo = LegacyWenkuRepository(
        request: (action) async {
          calls.add(action);
          return _results(
            action.contains('searchtype=tags')
                ? 73
                : action.contains('searchtype=author')
                ? 72
                : 71,
          );
        },
      );
      expect((await repo.searchPage('奇幻')).items.map((book) => book.id), [
        71,
        72,
        73,
      ]);
      calls.clear();
      expect(
        (await repo.searchFilteredPage(
          '奇幻',
          field: BookSearchField.author,
        )).items.single.id,
        72,
      );
      expect(calls.single, contains('searchtype=author'));
      calls.clear();
      expect((await repo.searchFilteredPage('#奇幻')).items.single.id, 73);
      expect(calls.single, contains('searchtype=tags'));
    },
  );
  test('no-result code 19 is empty, not a network or XML error', () async {
    final repo = LegacyWenkuRepository(request: (_) async => '19');
    final result = await repo.searchFilteredPage(
      '不存在',
      field: BookSearchField.tags,
    );
    expect(result.items, isEmpty);
    expect(result.hasMore, false);
    expect(result.totalItems, 0);
  });
  test(
    'capped tag results continue through catalogue pages beyond 20 without per-book requests',
    () async {
      final calls = <String>[];
      final repository = LegacyWenkuRepository(
        request: (action) async {
          calls.add(action);
          if (action.startsWith('action=search')) {
            return '<result>${List.generate(20, (i) => _results(i + 1).replaceAll(RegExp(r'</?result>'), '')).join()}</result>';
          }
          expect(action, startsWith('action=novellist'));
          final page = int.parse(Uri.splitQueryString(action)['page']!);
          return '<result><page num="6"/>${List.generate(10, (i) => _results((page - 1) * 10 + i + 1).replaceAll(RegExp(r'</?result>'), '')).join()}</result>';
        },
      );
      final first = await repository.searchFilteredPage(
        '奇幻',
        field: BookSearchField.tags,
      );
      expect(first.items.length, 20);
      expect(first.hasMore, true);
      expect(first.totalItems, isNull);
      final second = await repository.searchFilteredPage(
        '奇幻',
        field: BookSearchField.tags,
        page: 2,
      );
      final third = await repository.searchFilteredPage(
        '奇幻',
        field: BookSearchField.tags,
        page: 3,
      );
      expect(second.items.map((b) => b.id), List.generate(20, (i) => i + 21));
      expect(third.items.map((b) => b.id), List.generate(20, (i) => i + 41));
      expect(third.hasMore, false);
      expect(third.totalItems, 60);
      expect(calls.where((c) => c.startsWith('action=search')).length, 1);
      expect(calls.where((c) => c.startsWith('action=novellist')).length, 6);
    },
  );
  test(
    'closing a tag feed stops catalogue continuation and keeps its cache resumable',
    () async {
      final pending = Completer<String>();
      var catalogueCalls = 0;
      final repository = LegacyWenkuRepository(
        request: (action) async {
          if (action.startsWith('action=search')) {
            return '<result>${List.generate(20, (i) => _results(i + 1).replaceAll(RegExp(r'</?result>'), '')).join()}</result>';
          }
          catalogueCalls++;
          final page = int.parse(Uri.splitQueryString(action)['page']!);
          if (page == 1) return pending.future;
          return '<result><page num="6"/>${List.generate(10, (i) => _results((page - 1) * 10 + i + 1).replaceAll(RegExp(r'</?result>'), '')).join()}</result>';
        },
      );
      final feed = NovelFeedController(repository, search: true)
        ..searchField = BookSearchField.tags;
      await feed.searchFor('奇幻');
      final work = feed.loadMore();
      await Future<void>.delayed(Duration.zero);
      expect(catalogueCalls, 1);
      feed.dispose();
      pending.complete(
        '<result><page num="6"/>${List.generate(10, (i) => _results(i + 1).replaceAll(RegExp(r'</?result>'), '')).join()}</result>',
      );
      await work;
      expect(catalogueCalls, 1);
      final resumed = await repository.tagPage(
        '奇幻',
        page: 2,
        current: () => true,
      );
      expect(resumed.items.map((b) => b.id), List.generate(20, (i) => i + 21));
      expect(
        catalogueCalls,
        5,
        reason: 'The first public catalogue page is reused, not fetched again.',
      );
    },
  );
  test(
    'field change cancels a late response even when query is unchanged',
    () async {
      final repo = _DelayedSearch();
      final feed = NovelFeedController(repo, search: true);
      addTearDown(feed.dispose);
      feed.query = '奇幻';
      final previous = feed.selectSearchField(BookSearchField.title);
      await feed.selectSearchField(BookSearchField.tags);
      repo.old.complete(NovelPage.fromItems(demoNovels, 1));
      await previous;
      expect(feed.items.single.id, 71);
      expect(feed.query, '奇幻');
      expect(repo.calls, [BookSearchField.title, BookSearchField.tags]);
    },
  );
  test(
    'website page excludes sidebar and foreign links and preserves pagination',
    () {
      final result = parseWebPublicationPage(
        '''<html><body><aside><a href="/book/99.htm">推荐</a></aside><div id="content">
      <a href="/book/71.htm"><img src="a.jpg"></a><a href="/book/71.htm">作品</a>
      <a href="https://www.wenku8.net/book/72.htm">作品二</a><a href="https://unrelated.invalid/book/88.htm">外部</a>
      <div class="pages"><a href="articlelist.php?class=1&amp;sort=lastupdate&amp;page=7">末页</a></div></div></body></html>''',
      );
      expect(result.ids, [71, 72]);
      expect(result.totalPages, 7);
    },
  );
  test(
    'website login notice is distinct from malformed or empty categories',
    () {
      expect(
        () => parseWebPublicationPage('<div id="content">请先登录</div>'),
        throwsA(isA<PublicationConnectionRequired>()),
      );
      expect(
        () => parseWebPublicationPage('<form><input name="password"></form>'),
        throwsA(isA<PublicationConnectionRequired>()),
      );
      expect(
        () => parseWebPublicationPage('<html>Access denied</html>'),
        throwsFormatException,
      );
      expect(
        parseWebPublicationPage('<div id="content">暂无书籍</div>').ids,
        isEmpty,
      );
    },
  );
  test(
    'same-account API category lists resolve their original ids and page counts',
    () {
      final page = parseWebPublicationPage(
        '''<?xml version="1.0"?><result><page num="8"/>
      <item aid="1305"/><item aid="1305"/><item aid="0"/><item aid="bad"/><item aid="1234"/></result>''',
      );
      expect(page.ids, [1305, 1234]);
      expect(page.totalPages, 8);
      expect(
        () => parseWebPublicationPage('<result><item aid="bad"/></result>'),
        throwsFormatException,
      );
      expect(
        parseWebPublicationPage('<result><page num="0"/></result>').ids,
        isEmpty,
      );
    },
  );
  test('website connection never invalidates working API account', () async {
    var cleared = 0;
    final submitted = <(String, String)>[];
    final account = WenkuAccount(
      hasSession: () async => true,
      request: (_) async => profileXml,
      clearSession: () async {
        cleared++;
      },
      publicationLogin: (user, password) async {
        submitted.add((user, password));
        throw const FormatException('官网暂时不可用');
      },
    );
    addTearDown(account.dispose);
    await account.initialize();
    await expectLater(
      account.connectPublications('transient'),
      throwsFormatException,
    );
    expect(submitted.single.$1, account.profile!.username);
    expect(account.authenticated, true);
    expect(account.profile!.score, 12);
    expect(cleared, 0);
    expect(account.error, '官网暂时不可用');
  });
  test(
    'native preparation is opt-in only for archive formats and keeps partial results',
    () async {
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(BookDocuments.channel, (call) async {
            calls.add(call.method);
            if (call.method == 'prepareBook') {
              return [
                {'name': '第一卷.txt', 'path': '/staged/one'},
                {'name': '第二卷.mobi', 'error': 'DRM'},
              ];
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(BookDocuments.channel, null),
      );
      final docs = BookDocuments();
      final epub = const BookDocumentSelection(
        name: '原书.epub',
        path: '/original',
      );
      expect((await docs.prepareBook(epub)).single, same(epub));
      expect(calls, isEmpty);
      final prepared = await docs.prepareBook(
        const BookDocumentSelection(name: '分卷.zip', path: '/staged/archive'),
      );
      expect(prepared.map((book) => book.name), ['第一卷.txt', '第二卷.mobi']);
      expect(prepared.last.error, 'DRM');
      expect(calls, ['prepareBook']);
    },
  );
  test(
    'combined source filters persist, combine scopes and do not mutate shelf membership',
    () async {
      SharedPreferences.setMockInitialValues({});
      final state = await LibraryState.load();
      final root = await Directory.systemTemp.createTemp(
        'wenku-source-filter-',
      );
      final local = LocalBookStore(Directory('${root.path}/local'));
      await local.load();
      final imported = await local.import(
        LocalBookInput('本地.txt', utf8.encode('第一章\n本地正文。'), text: '第一章\n本地正文。'),
      );
      final cache = OfflineCacheStore(Directory('${root.path}/cache'));
      final cached = _book.withChapters(const [NovelChapter('第一章', '', id: 1)]);
      await cache.saveBook(cached, epoch: cache.epochFor(cached.id));
      await cache.saveChapter(
        cached.id,
        1,
        '正文',
        epoch: cache.epochFor(cached.id),
      );
      final network = NetworkStatus(initial: NetworkReachability.online);
      final offline = OfflineNovelRepository(
        remote: const DemoNovelRepository(),
        cache: cache,
        local: local,
        network: network,
      );
      addTearDown(() async {
        offline.dispose();
        network.dispose();
        local.dispose();
        cache.dispose();
        state.dispose();
        await root.delete(recursive: true);
      });
      await state.setShelfMembership(2, true, novel: demoNovels[1]);
      await state.setNavigationMode(combinedShelf: true);
      await state.setShelfView(source: 'local', filter: 'reading');
      expect(bookshelfIds(state, offline), {imported.id});
      expect(state.shelfFilter, 'reading');
      final search = LibrarySearchRepository(
        source: offline,
        state: state,
        local: local,
      );
      expect((await search.search('')).map((book) => book.id), [imported.id]);
      await state.setShelfView(source: 'cached');
      expect(bookshelfIds(state, offline), {71});
      await state.setShelfView(source: 'online');
      expect(bookshelfIds(state, offline), {2});
      expect(bookshelfIds(state, offline, readableOnly: true), isEmpty);
      await state.setShelfView(source: 'all');
      expect(bookshelfIds(state, offline, readableOnly: true), {
        71,
        imported.id,
      });
      await state.setShelfView(source: 'cached');
      final backup = await state.createBackup();
      await state.setShelfView(source: 'local');
      await state.restoreBackup(backup, importPreferences: true);
      expect(state.shelfSourceFilter, 'cached');
      final restarted = await LibraryState.load();
      expect(restarted.shelfSourceFilter, 'cached');
      restarted.dispose();
      await state.setNavigationMode(combinedShelf: false);
      expect(bookshelfIds(state, offline), {2});
      expect(state.shelf, {2});
      network.value = NetworkReachability.offline;
      expect(
        (await offline.searchFilteredPage(
          '女性',
          field: BookSearchField.tags,
        )).items.single.id,
        71,
      );
    },
  );
}
