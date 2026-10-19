import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/legacy_import.dart';
import 'package:wenku8_flutter/legacy_wenku_repository.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/publication_catalog.dart';
import 'package:wenku8_flutter/reader_content.dart';
import 'package:wenku8_flutter/reader_find.dart';
import 'package:wenku8_flutter/reader_illustrations.dart';
import 'package:wenku8_flutter/wenku_account.dart';
import 'package:wenku8_flutter/wenku_reviews.dart';

import 'support/offline_fixture.dart';

const profileXml =
    '<metadata><item name="uname">reader</item><item name="nickname">读者</item><item name="uid">81</item><item name="score">12</item><item name="experience">32</item><item name="rank">新手</item></metadata>';
String cloudXml(Iterable<int> ids) =>
    '<metadata>${ids.map((id) => '<book aid="$id" date="2026-10-05"><name>作品 $id</name><chapter cid="${id * 1000}">最新章节</chapter></book>').join()}</metadata>';
String publicationXml(int id, {String date = '2026-10-05'}) =>
    '<result><page num="3"/><item aid="$id"><data name="Title" value="作品 $id"/><data name="LastUpdate" value="$date"/></item></result>';
String reviewXml(int id, {int pages = 2}) =>
    '<result><page num="$pages"/><item rid="$id" replies="3" posttime="20261005103000"><user uid="81">读者</user><content>书评 $id</content></item></result>';

class AccountFixture {
  bool session = false;
  bool disconnected = false;
  String? shelfResponse;
  int loginCode = 1;
  final ids = <int>{71};
  final calls = <String>[];
  final addCodes = <int, int>{};
  late final account = WenkuAccount(
    request: request,
    loginRequest: (action) async {
      calls.add(action);
      if (loginCode == 1) session = true;
      return '$loginCode';
    },
    hasSession: () async => session,
    clearSession: () async {
      session = false;
      calls.add('clear');
    },
  );
  Future<String> request(String action) async {
    calls.add(action);
    if (disconnected) throw StateError('offline');
    if (!session) return '4';
    if (action == 'action=userinfo') return profileXml;
    if (action == 'action=bookcase&t=0') return shelfResponse ?? cloudXml(ids);
    if (action.startsWith('action=bookcase&do=add&aid=')) {
      final id = int.parse(action.split('=').last);
      final code = addCodes[id] ?? 1;
      if ({1, 5}.contains(code)) ids.add(id);
      return '$code';
    }
    if (action.startsWith('action=bookcase&do=del&aid=')) {
      ids.remove(int.parse(action.split('=').last));
      return '1';
    }
    return '1';
  }

  Future<void> login() async {
    await account.initialize();
    await account.login('reader', 'password');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  group('account and cloud contracts', () {
    test('valid profile is distinct from malformed or captive-portal XML', () {
      expect(WenkuProfile.parse(profileXml).displayName, '读者');
      expect(() => WenkuProfile.parse('<html/>'), throwsFormatException);
      expect(
        () => WenkuProfile.parse(
          '<metadata><item name="uid">0</item></metadata>',
        ),
        throwsFormatException,
      );
      expect(() => WenkuProfile.parse('4'), throwsA(isA<WenkuApiError>()));
    });
    test(
      'empty cloud shelf is valid; userinfo/HTML/error are not empty shelves',
      () {
        expect(CloudBook.parse('<metadata/>'), isEmpty);
        expect(() => CloudBook.parse(profileXml), throwsFormatException);
        expect(() => CloudBook.parse('<html/>'), throwsFormatException);
        expect(
          () => CloudBook.parse('<metadata><book aid="broken"/></metadata>'),
          throwsFormatException,
        );
        expect(
          () =>
              CloudBook.parse('<metadata><book aid="2147483648"/></metadata>'),
          throwsFormatException,
        );
        expect(() => CloudBook.parse('4'), throwsA(isA<WenkuApiError>()));
        expect(
          CloudBook.parse(
            '<metadata><book aid="71"/><book aid="71"/><book aid="broken"/></metadata>',
          ).length,
          1,
        );
      },
    );
    test('guest initialization never uploads or reads a cloud shelf', () async {
      final fixture = AccountFixture();
      await fixture.account.initialize();
      expect(fixture.calls, isEmpty);
      expect(fixture.account.authenticated, isFalse);
      fixture.account.dispose();
    });
    test(
      'username/email/password are percent-encoded in original login actions',
      () async {
        final fixture = AccountFixture();
        await fixture.account.initialize();
        await fixture.account.login('a+b@example.net', 'p&=中');
        expect(
          fixture.calls.first,
          'action=loginemail&username=a%2Bb%40example.net&password=p%26%3D%E4%B8%AD',
        );
        expect(fixture.account.profile!.id, 81);
        expect(fixture.account.authenticated, isTrue);
        final backup = await (await LibraryState.load()).createBackup();
        expect((await backup.encode()), isNot(contains('password')));
        fixture.account.dispose();
      },
    );
    test(
      'rejected credentials never become a local authenticated state',
      () async {
        final fixture = AccountFixture()..loginCode = 3;
        await fixture.account.initialize();
        await expectLater(
          fixture.account.login('reader', 'wrong'),
          throwsA(isA<WenkuApiError>()),
        );
        expect(fixture.account.authenticated, isFalse);
        expect(fixture.account.error, '密码不正确');
        expect(fixture.calls.length, 1);
        fixture.account.dispose();
      },
    );
    test(
      'restore only uses persisted session, never a saved password',
      () async {
        final fixture = AccountFixture()..session = true;
        await fixture.account.initialize();
        expect(fixture.account.profile!.id, 81);
        expect(fixture.calls, ['action=userinfo']);
        fixture.account.dispose();
      },
    );
    test('cloud read failure preserves the last valid shelf', () async {
      final fixture = AccountFixture();
      await fixture.login();
      await fixture.account.refreshCloud();
      fixture.shelfResponse = '<html/>';
      await expectLater(fixture.account.refreshCloud(), throwsFormatException);
      expect(fixture.account.cloudBooks!.single.id, 71);
      fixture.account.dispose();
    });
    test('expiry clears session/cloud, not local reading records', () async {
      final fixture = AccountFixture();
      await fixture.login();
      await fixture.account.refreshCloud();
      final state = await LibraryState.load();
      await state.addShelfIds([71]);
      await state.setChapter(71, 2);
      fixture.session = false;
      await expectLater(
        fixture.account.refreshCloud(),
        throwsA(isA<WenkuApiError>()),
      );
      expect(fixture.calls.last, 'clear');
      expect(fixture.account.cloudBooks, isNull);
      expect(state.contains(71), isTrue);
      expect(state.chapterFor(71), 2);
      state.dispose();
      fixture.account.dispose();
    });
    test(
      'upload re-reads cloud and adds only missing IDs idempotently',
      () async {
        final fixture = AccountFixture();
        await fixture.login();
        fixture.addCodes[72] = 5;
        final result = await fixture.account.uploadMissing({71, 72, 73});
        expect(result.uploaded, [72, 73]);
        expect(result.remaining, isEmpty);
        expect(
          fixture.calls.where((action) => action.contains('do=del')),
          isEmpty,
        );
        expect(
          fixture.calls.where((action) => action.contains('do=add&aid=71')),
          isEmpty,
        );
        fixture.account.dispose();
      },
    );
    test(
      'full cloud shelf stops at first failure and a retry skips committed IDs',
      () async {
        final fixture = AccountFixture();
        await fixture.login();
        fixture.addCodes[73] = 6;
        final first = await fixture.account.uploadMissing({71, 72, 73, 74});
        expect(first.uploaded, [72]);
        expect(first.remaining, [73, 74]);
        expect(fixture.ids.contains(74), isFalse);
        fixture.addCodes.remove(73);
        final second = await fixture.account.uploadMissing({71, 72, 73, 74});
        expect(second.uploaded, [73, 74]);
        expect(
          fixture.calls
              .where((action) => action.contains('do=add&aid=72'))
              .length,
          1,
        );
        fixture.account.dispose();
      },
    );
    test('bad cloud response never schedules an upload', () async {
      final fixture = AccountFixture();
      await fixture.login();
      fixture.shelfResponse = '<html/>';
      await expectLater(
        fixture.account.uploadMissing({71, 72}),
        throwsFormatException,
      );
      expect(
        fixture.calls.where((action) => action.contains('do=add')),
        isEmpty,
      );
      fixture.account.dispose();
    });
    test(
      'offline logout still clears session without altering library',
      () async {
        final fixture = AccountFixture();
        await fixture.login();
        final state = await LibraryState.load();
        await state.addShelfIds([71]);
        await state.setChapter(71, 3);
        fixture.disconnected = true;
        await fixture.account.logout();
        expect(fixture.account.authenticated, isFalse);
        expect(fixture.session, isFalse);
        expect(state.contains(71), isTrue);
        expect(state.chapterFor(71), 3);
        fixture.account.dispose();
        state.dispose();
      },
    );
    test(
      'cloud import is one transaction/notification and preserves positions',
      () async {
        final fixture = AccountFixture();
        await fixture.login();
        fixture.ids.addAll([72, 73]);
        final state = await LibraryState.load();
        final book = offlineFixtureBook(71);
        await state.setShelfMembership(71, true, novel: book);
        await state.savePosition(
          novel: book,
          chapter: 1,
          offset: 300,
          maximum: 1000,
          width: 400,
        );
        final position = state.positionFor(71);
        var changes = 0;
        state.addListener(() => changes++);
        expect(await fixture.account.mergeCloudToLocal(state), 2);
        expect(changes, 1);
        expect(state.shelf, {71, 72, 73});
        expect(state.positionFor(71), same(position));
        final restored = await LibraryState.load();
        expect(restored.shelf, state.shelf);
        fixture.account.dispose();
        state.dispose();
        restored.dispose();
      },
    );
    test('double mutation is gated while one request is in flight', () async {
      final held = Completer<String>();
      var calls = 0;
      final account = WenkuAccount(
        hasSession: () async => true,
        clearSession: () async {},
        request: (action) async {
          if (action == 'action=userinfo') return profileXml;
          calls++;
          return held.future;
        },
      );
      await account.initialize();
      final first = account.addCloud(71);
      await expectLater(account.addCloud(71), throwsStateError);
      expect(calls, 1);
      held.complete('1');
      await first;
      expect(account.busy, isFalse);
      account.dispose();
    });
  });
  group('publication catalogue', () {
    test(
      'uses server category IDs/names, deduplicates and rejects error XML',
      () {
        expect(
          PublicationLibrary.parse(
            '<metadata><item sort="8">一迅社</item><item sort="8">重复</item></metadata>',
          ).single.id,
          8,
        );
        expect(
          () => PublicationLibrary.parse('<result/>'),
          throwsFormatException,
        );
        expect(
          () => PublicationLibrary.parse('<metadata/>'),
          throwsFormatException,
        );
      },
    );
    test(
      'category browse reuses original numeric sort and normal cursor',
      () async {
        final calls = <String>[];
        final repository = LegacyWenkuRepository(
          request: (action) async {
            calls.add(action);
            return publicationXml(71);
          },
        );
        expect((await repository.browsePublication(8, page: 2)).page, 2);
        await repository.browsePublication(8, page: 2);
        expect(calls, ['action=novellist&sort=8&page=2&t=0']);
        await repository.browsePublication(8, refresh: true);
        expect(calls.last, 'action=novellist&sort=8&page=1&t=0');
      },
    );
    test('stale publication refresh cannot replace newer metadata', () async {
      final old = Completer<String>(), fresh = Completer<String>();
      var calls = 0;
      final repository = LegacyWenkuRepository(
        request: (action) {
          calls++;
          return calls == 1 ? old.future : fresh.future;
        },
      );
      final a = repository.browsePublication(8);
      final b = repository.browsePublication(8, refresh: true);
      fresh.complete(publicationXml(71, date: '2026-10-05'));
      await b;
      old.complete(publicationXml(71, date: '2010-01-01'));
      await a;
      expect((await repository.find(71))!.lastUpdate, '2026-10-05');
    });
    test(
      'failed publication request is retriable rather than cached forever',
      () async {
        var calls = 0;
        final repository = LegacyWenkuRepository(
          request: (action) async {
            calls++;
            return calls == 1 ? '<html/>' : publicationXml(71);
          },
        );
        await expectLater(
          repository.browsePublication(8),
          throwsFormatException,
        );
        expect((await repository.browsePublication(8)).items.single.id, 71);
        expect(calls, 2);
      },
    );
  });
  group('illustrations', () {
    test(
      'original paired image markers survive text normalization and keep order',
      () async {
        final repository = LegacyWenkuRepository(
          request: (_) async =>
              '前文\r\n<!--image-->http://img.wenku8.com/a.jpg<!--image--><!--image-->https://img.wenku8.com/b.jpg<!--image-->\r\n后文',
        );
        final body = await repository.chapterContent(
          71,
          offlineFixtureBook(71).chapters.first,
        );
        final content = await ReaderContent.parse(body);
        expect(content.paragraphs.length, 4);
        expect(content.paragraphs.first, '前文');
        expect(content.illustrations, [
          'https://img.wenku8.com/a.jpg',
          'https://img.wenku8.com/b.jpg',
        ]);
      },
    );
    test(
      'image URLs are not in-chapter search hits or arbitrary remote fetches',
      () async {
        final content = await ReaderContent.parse(
          'img文字\n\n<!--image-->https://img.wenku8.com/a.jpg<!--image-->',
        );
        expect((await findInReader(content, 'img')).matches.length, 1);
        expect(
          readerIllustrationUrl(
            '<!--image-->https://example.org/a.jpg<!--image-->',
          ),
          isNull,
        );
        expect(
          readerIllustrationUrl(
            '<!--image-->https://img.wenku8.com.evil.test/a.jpg<!--image-->',
          ),
          isNull,
        );
        expect(
          readerIllustrationUrl('<!--image-->file:///tmp/a.jpg<!--image-->'),
          isNull,
        );
      },
    );
    test(
      'encoded memory cache is bounded and evicted futures fetch again',
      () async {
        final calls = <String>[];
        final cache = ReaderIllustrationCache(
          maxBytes: 8,
          request: (url) async {
            calls.add(url);
            return Uint8List(4);
          },
        );
        await cache.load('a');
        await cache.load('b');
        await cache.load('a');
        await cache.load('c');
        expect(cache.encodedBytes, 8);
        expect(cache.peek('b'), isNull);
        await cache.load('b');
        expect(calls, ['a', 'b', 'c', 'b']);
      },
    );
    test(
      'pending images deduplicate; failure and clear release requests',
      () async {
        final held = Completer<Uint8List>();
        var calls = 0;
        final cache = ReaderIllustrationCache(
          request: (_) {
            calls++;
            return held.future;
          },
        );
        final first = cache.load('a');
        final second = cache.load('a');
        expect(calls, 1);
        cache.clearMemory();
        held.complete(Uint8List(4));
        await first;
        await second;
        expect(cache.peek('a'), isNull);
        expect(cache.encodedBytes, 0);
        var attempts = 0;
        final retry = ReaderIllustrationCache(
          request: (_) async {
            if (++attempts == 1) throw StateError('offline');
            return Uint8List(4);
          },
        );
        await expectLater(retry.load('a'), throwsStateError);
        await retry.load('a');
        expect(attempts, 2);
      },
    );
  });
  group('legacy record import', () {
    Map<Object?, Object?> bundle(Map<String, String> docs) => {
      'documents': {
        for (final entry in docs.entries)
          entry.key: {'text': entry.value, 'modifiedAt': 1000},
      },
      'skippedFiles': 0,
    };
    test(
      'imports shelf, exact chapter IDs and search; drops individual damage',
      () async {
        final preview = await LegacyImportPreview.parse(
          bundle({
            'bookshelf_local.wk8': '71||72||71||broken',
            'read_saves_v1.wk8': '71:1:71002:20:3||bad',
            'search_history.wk8': '[0魔法][1作者][0魔法]',
          }),
        );
        expect(preview.backup.shelfCount, 2);
        expect(preview.backup.positionCount, 1);
        expect(preview.damagedRecords, 2);
        final position = jsonDecode(
          preview.backup.records['reading_position_71']! as String,
        );
        expect(position['chapterId'], 71002);
        expect(position['offset'], 0);
        expect(preview.backup.records['recentSearches'], ['魔法', '作者']);
      },
    );
    test(
      'vertical progress maps chapter to book using original cached volume index',
      () async {
        final preview = await LegacyImportPreview.parse(
          bundle({
            'bookshelf_local.wk8': '71',
            '71-volume.xml':
                '<metadata><volume><chapter cid="71001">一</chapter><chapter cid="71002">二</chapter></volume></metadata>',
            'read_saves.wk8': '71002,,250,,1000||991,,100,,200',
          }),
        );
        expect(preview.unmappedChapters, 1);
        final state = await LibraryState.load();
        await state.restoreBackup(preview.backup);
        expect(state.positionFor(71)!.chapter, 1);
        expect(state.positionFor(71)!.fraction, .25);
        state.dispose();
      },
    );
    test(
      'legacy merge preserves newer Flutter position and existing bookmarks',
      () async {
        final state = await LibraryState.load();
        final book = offlineFixtureBook(71);
        await state.setShelfMembership(71, true, novel: book);
        await state.savePosition(
          novel: book,
          chapter: 2,
          offset: 300,
          maximum: 1000,
          width: 400,
        );
        await state.addBookmark(novel: book, position: state.positionFor(71)!);
        final saved = state.positionFor(71);
        final preview = await LegacyImportPreview.parse(
          bundle({
            'bookshelf_local.wk8': '72',
            'read_saves_v1.wk8': '71:1:71001:2:3',
          }),
        );
        await state.restoreBackup(preview.backup);
        expect(state.positionFor(71), same(saved));
        expect(state.bookmarksFor(71).length, 1);
        expect(state.shelf, {71, 72});
        state.dispose();
      },
    );
    test(
      'account/cert data and oversized/unrecognized bundles are rejected',
      () async {
        await expectLater(
          LegacyImportPreview.parse(bundle({'cert.wk8': 'secret'})),
          throwsFormatException,
        );
        await expectLater(
          LegacyImportPreview.parse(bundle({'bookshelf_local.wk8': 'broken'})),
          throwsFormatException,
        );
        await expectLater(
          LegacyImportPreview.parse(
            bundle({'bookshelf_local.wk8': 'x' * (8 * 1024 * 1024 + 1)}),
          ),
          throwsFormatException,
        );
      },
    );
  });
  group('reviews', () {
    test('parses original content-as-title and reply body/time fields', () {
      final thread = WenkuReviewPage.parse(reviewXml(81)).items.single;
      expect(thread.title, '书评 81');
      expect(thread.content, '');
      expect(thread.date, '2026-10-05 10:30');
      final reply = WenkuReviewPage.parse(
        '<metadata><page num="1"/><item timestamp="20261005120000"><user uid="81">读者</user><content><![CDATA[评论正文]]></content></item></metadata>',
        replies: true,
      ).items.single;
      expect(reply.content, '评论正文');
      expect(reply.userId, 81);
    });
    test('empty/error/malformed lists stay distinct', () {
      expect(
        WenkuReviewPage.parse('<result><page num="0"/></result>').items,
        isEmpty,
      );
      expect(() => WenkuReviewPage.parse('<html/>'), throwsFormatException);
      expect(
        () => WenkuReviewPage.parse(
          '<result><page num="1"/><item rid="x"/></result>',
        ),
        throwsFormatException,
      );
      expect(() => WenkuReviewPage.parse('8'), throwsA(isA<WenkuApiError>()));
    });
    test(
      'failed pagination does not advance cursor; duplicate rows are removed',
      () async {
        final calls = <String>[];
        var fail = true;
        final feed = WenkuReviewFeed(
          id: 71,
          request: (action) async {
            calls.add(action);
            if (action.contains('page=2') && fail) {
              fail = false;
              throw StateError('offline');
            }
            return reviewXml(action.contains('page=2') ? 82 : 81);
          },
        );
        await feed.load();
        await feed.load();
        expect(feed.page, 1);
        expect(feed.items.length, 1);
        await feed.load();
        expect(feed.page, 2);
        expect(feed.items.length, 2);
        expect(calls[1], calls[2]);
        feed.dispose();
      },
    );
    test(
      'failed refresh retries page one while preserving visible old rows',
      () async {
        var calls = 0;
        final actions = <String>[];
        final feed = WenkuReviewFeed(
          id: 71,
          request: (action) async {
            actions.add(action);
            if (++calls == 2) throw StateError('offline');
            return reviewXml(calls == 1 ? 81 : 82);
          },
        );
        await feed.load();
        await feed.load(refresh: true);
        expect(feed.items.single.id, 81);
        await feed.load();
        expect(actions.last, contains('page=1'));
        expect(feed.items.single.id, 82);
        feed.dispose();
      },
    );
    test('stale review response is ignored after explicit refresh', () async {
      final a = Completer<String>(), b = Completer<String>();
      var calls = 0;
      final feed = WenkuReviewFeed(
        id: 71,
        request: (_) => ++calls == 1 ? a.future : b.future,
      );
      final old = feed.load();
      final newer = feed.load(refresh: true);
      b.complete(reviewXml(82));
      await newer;
      a.complete(reviewXml(81));
      await old;
      expect(feed.items.single.id, 82);
      feed.dispose();
    });
  });
}
