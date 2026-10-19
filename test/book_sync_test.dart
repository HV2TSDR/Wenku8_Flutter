import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/book_documents.dart';
import 'package:wenku8_flutter/book_sync.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/local_books.dart';
import 'package:wenku8_flutter/local_series_actions.dart';
import 'support/local_series_fixture.dart';

class _Document extends BookDocuments {
  _Document(this.cloud, this.folder);
  final File cloud;
  final Directory folder;
  bool fail = false;
  int writes = 0;
  int reads = 0;
  Completer<void>? readGate;
  @override
  Future<Map<String, dynamic>?> info() async => {
    'name': '文库.wenku8sync',
    'created': await cloud.length() == 0,
  };
  @override
  Future<({File before, File output})> read() async {
    reads++;
    await readGate?.future;
    return (
      before: await cloud.copy('${folder.path}/before'),
      output: File('${folder.path}/next'),
    );
  }

  @override
  Future<void> write(File before, File next) async {
    if (fail) throw const FileSystemException('write failure');
    expect(await before.readAsBytes(), await cloud.readAsBytes());
    await next.copy(cloud.path);
    writes++;
  }

  @override
  Future<File?> recovery(String which) async => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'two devices merge originals, latest positions and bookmarks without local shelf membership or secrets',
    () async {
      final root = await Directory.systemTemp.createTemp('wenku-sync-test-');
      addTearDown(() => root.delete(recursive: true));
      final cloud = File('${root.path}/cloud')..writeAsBytesSync([]);
      SharedPreferences.setMockInitialValues({
        'privateApiKey': 'not-for-export',
      });
      final prefsA = await SharedPreferences.getInstance();
      final a = LibraryState(prefsA);
      addTearDown(a.dispose);
      final booksA = LocalBookStore(Directory('${root.path}/a'));
      await booksA.load();
      addTearDown(booksA.dispose);
      final text = '第一卷\n第一章\n从设备 A 导入的正文。';
      final book = await booksA.import(
        LocalBookInput(
          '我的书.txt',
          Uint8List.fromList(utf8.encode(text)),
          text: text,
        ),
      );
      await a.setShelfMembership(book.id, true, novel: book);
      await a.savePosition(
        novel: book,
        chapter: 0,
        offset: 100,
        maximum: 1000,
        width: 400,
        paragraphIndex: 0,
      );
      await a.addBookmark(novel: book, position: a.positionFor(book.id)!);
      final docA = _Document(cloud, booksA.directory);
      final syncA = BookSync(
        books: booksA,
        state: a,
        preferences: prefsA,
        documents: docA,
      );
      addTearDown(syncA.dispose);
      final category = await syncA.organization.addGroup('跨设备分类');
      await syncA.organization.assign(book.id, category);
      await booksA.updateMetadata(
        book.id,
        title: '云端自定义书名',
        author: '自定义作者',
        summary: '编辑过的简介',
      );
      await syncA.load();
      await syncA.sync();
      expect(syncA.error, isNull);
      expect(docA.writes, 1);
      final bundle = decodeBookSync(await cloud.readAsBytes());
      expect(bundle.books.single.name, '我的书.txt');
      expect(bundle.backup, isNot(contains('privateApiKey')));
      SharedPreferences.setMockInitialValues({});
      final prefsB = await SharedPreferences.getInstance();
      final b = LibraryState(prefsB);
      addTearDown(b.dispose);
      final booksB = LocalBookStore(Directory('${root.path}/b'));
      await booksB.load();
      addTearDown(booksB.dispose);
      final docB = _Document(cloud, booksB.directory);
      final syncB = BookSync(
        books: booksB,
        state: b,
        preferences: prefsB,
        documents: docB,
      );
      addTearDown(syncB.dispose);
      await syncB.load();
      await syncB.sync();
      expect(syncB.error, isNull);
      expect(booksB.book(book.id)!.chapters.single.title, '第一章');
      expect(b.shelf, isEmpty);
      expect(b.positionFor(book.id)!.offset, 100);
      expect(b.bookmarksFor(book.id), hasLength(1));
      expect(syncB.organization.groupOf(book.id), category);
      expect(syncB.organization.nameOf(category), '跨设备分类');
      expect(booksB.book(book.id)!.title, '云端自定义书名');
      expect(b.cachedNovel(book.id)!.author, '自定义作者');
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await b.savePosition(
        novel: booksB.book(book.id)!,
        chapter: 0,
        offset: 500,
        maximum: 1000,
        width: 380,
        paragraphIndex: 0,
      );
      await syncB.sync();
      await syncA.sync();
      expect(a.positionFor(book.id)!.offset, 500);
      expect(booksA.books, hasLength(1));
      expect(a.bookmarksFor(book.id), hasLength(1));
    },
  );
  test(
    'disabled sync domains preserve remote originals and categories without uploading local values',
    () async {
      final root = await Directory.systemTemp.createTemp('wenku-sync-options-');
      addTearDown(() => root.delete(recursive: true));
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final state = LibraryState(prefs);
      addTearDown(state.dispose);
      final books = LocalBookStore(Directory('${root.path}/books'));
      await books.load();
      addTearDown(books.dispose);
      const remoteText = '第一章\n云端原书正文。', localText = '第一章\n本机独立原书正文。';
      final remoteBook = LocalBookInput(
        '云端.txt',
        Uint8List.fromList(utf8.encode(remoteText)),
        text: remoteText,
      );
      await books.import(
        LocalBookInput(
          '本机.txt',
          Uint8List.fromList(utf8.encode(localText)),
          text: localText,
        ),
      );
      final cloud = File('${root.path}/cloud')
        ..writeAsBytesSync(
          encodeBookSync(
            BookSyncBundle(
              await (await state.createBackup()).encode(),
              [remoteBook],
              organization: {
                'version': 1,
                'groups': {
                  'remote': {'name': '云端分类', 'at': 1, 'deleted': false},
                },
                'assignments': {},
              },
            ),
          ),
        );
      final sync = BookSync(
        books: books,
        state: state,
        preferences: prefs,
        documents: _Document(cloud, root),
      );
      addTearDown(sync.dispose);
      await sync.organization.addGroup('不上传的本地分类');
      await sync.configure(originals: false, categories: false, reading: true);
      await sync.load();
      await sync.sync();
      expect(sync.error, isNull);
      final result = decodeBookSync(await cloud.readAsBytes());
      expect(result.books.single.name, '云端.txt');
      expect(result.organization!['groups'].keys, ['remote']);
      expect(books.books.single.title, '本机');
      expect(sync.organization.groups.values, ['不上传的本地分类']);
      expect(prefs.getBool('bookSyncOriginals'), false);
    },
  );
  test(
    'invalid cloud input is never overwritten; write failure retains local data',
    () async {
      final root = await Directory.systemTemp.createTemp('wenku-sync-failure-');
      addTearDown(() => root.delete(recursive: true));
      final cloud = File('${root.path}/cloud')
        ..writeAsStringSync('not a sync archive');
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final state = LibraryState(prefs);
      addTearDown(state.dispose);
      final books = LocalBookStore(Directory('${root.path}/books'));
      await books.load();
      addTearDown(books.dispose);
      final doc = _Document(cloud, books.directory);
      final sync = BookSync(
        books: books,
        state: state,
        preferences: prefs,
        documents: doc,
      );
      addTearDown(sync.dispose);
      await sync.load();
      await sync.sync();
      expect(sync.error, isNotNull);
      expect(doc.writes, 0);
      expect(await cloud.readAsString(), 'not a sync archive');
      await cloud.writeAsBytes([]);
      await sync.load();
      doc.fail = true;
      await sync.sync();
      expect(sync.error, isNotNull);
      expect(await cloud.length(), 0);
      expect(await File('${books.directory.path}/next').exists(), isTrue);
      await sync.recover('next');
      expect(sync.error, contains('暂无可恢复'));
      expect(sync.status, isNull);
      doc.fail = false;
      await sync.sync();
      expect(sync.error, isNull);
      expect(doc.writes, 1);
    },
  );
  test(
    'reopening a sync page cannot overlap its still-running document transaction',
    () async {
      final root = await Directory.systemTemp.createTemp('wenku-sync-reopen-');
      addTearDown(() => root.delete(recursive: true));
      final cloud = File('${root.path}/cloud')..writeAsBytesSync([]);
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final state = LibraryState(prefs);
      addTearDown(state.dispose);
      final books = LocalBookStore(Directory('${root.path}/books'));
      await books.load();
      addTearDown(books.dispose);
      final firstDocument = _Document(cloud, books.directory)
        ..readGate = Completer<void>();
      final first = BookSync(
        books: books,
        state: state,
        preferences: prefs,
        documents: firstDocument,
      );
      await first.load();
      final pending = first.sync();
      expect(firstDocument.reads, 1);
      first.dispose();

      final nextDocument = _Document(cloud, books.directory);
      final reopened = BookSync(
        books: books,
        state: state,
        preferences: prefs,
        documents: nextDocument,
      );
      addTearDown(reopened.dispose);
      await reopened.load();
      await reopened.sync();
      await reopened.connect(create: false);
      await reopened.disconnect();
      await reopened.recover('before');
      expect(reopened.status, contains('上一次云文档操作'));
      expect(reopened.error, isNull);
      expect(reopened.connection, isNotNull);
      expect(nextDocument.reads, 0);
      expect(nextDocument.writes, 0);

      firstDocument.readGate!.complete();
      await pending;
      expect(first.error, isNull);
      expect(firstDocument.writes, 1);
      await reopened.sync();
      expect(reopened.error, isNull);
      expect(nextDocument.reads, 1);
      expect(nextDocument.writes, 1);
    },
  );
  test(
    'series sync carries each original once, stable chapters, edits and dissolution',
    () async {
      final root = await Directory.systemTemp.createTemp('wenku-series-sync-');
      addTearDown(() => root.delete(recursive: true));
      final cloud = File('${root.path}/cloud')..writeAsBytesSync([]);
      SharedPreferences.setMockInitialValues({});
      final pa = await SharedPreferences.getInstance();
      final a = LibraryState(pa);
      addTearDown(a.dispose);
      final ba = LocalBookStore(Directory('${root.path}/a'));
      await ba.load();
      addTearDown(ba.dispose);
      final one = await ba.import(
        LocalBookInput('one.epub', seriesEpubFixture(1)),
      );
      final two = await ba.import(
        LocalBookInput('two.epub', seriesEpubFixture(2)),
      );
      await a.savePosition(
        novel: two,
        chapter: 1,
        offset: 230,
        maximum: 1000,
        width: 390,
        paragraphIndex: 2,
        textOffset: 7,
      );
      await a.addBookmark(novel: two, position: a.positionFor(two.id)!);
      final series = await saveLocalSeries(
        books: ba,
        library: a,
        title: '星海图书馆',
        volumes: [
          (bookId: one.id, title: '第一卷'),
          (bookId: two.id, title: '第二卷'),
        ],
      );
      final sa = BookSync(
        books: ba,
        state: a,
        preferences: pa,
        documents: _Document(cloud, ba.directory),
      );
      addTearDown(sa.dispose);
      final group = await sa.organization.addGroup('系列收藏');
      await sa.organization.assign(series.id, group);
      await sa.load();
      await sa.sync();
      expect(sa.error, isNull);
      final packed = decodeBookSync(await cloud.readAsBytes());
      expect(
        packed.books.length,
        2,
        reason: 'the virtual series is not an extra EPUB',
      );
      expect(packed.series!['series'].length, 1);
      SharedPreferences.setMockInitialValues({});
      final pb = await SharedPreferences.getInstance();
      final b = LibraryState(pb);
      addTearDown(b.dispose);
      final bb = LocalBookStore(Directory('${root.path}/b'));
      await bb.load();
      addTearDown(bb.dispose);
      final sb = BookSync(
        books: bb,
        state: b,
        preferences: pb,
        documents: _Document(cloud, bb.directory),
      );
      addTearDown(sb.dispose);
      await sb.load();
      await sb.sync();
      expect(sb.error, isNull);
      expect(bb.books.single.id, series.id);
      expect(bb.originals.length, 2);
      expect(b.shelf, isEmpty);
      expect(b.positionFor(series.id)!.textOffset, 7);
      expect(b.bookmarksFor(series.id).length, 1);
      expect(sb.organization.groupOf(series.id), group);
      await bb.updateMetadata(
        series.id,
        title: '星海合订本',
        author: '青木',
        summary: '同步合订本',
      );
      await sb.sync();
      await sa.sync();
      expect(sa.error, isNull);
      expect(ba.book(series.id)!.title, '星海合订本');
      expect(a.bookmarksFor(series.id).length, 1);
      await dissolveLocalSeries(
        books: ba,
        library: a,
        series: ba.series.single,
      );
      await sa.sync();
      await sb.sync();
      expect(sa.error, isNull);
      expect(sb.error, isNull);
      expect(bb.series, isEmpty);
      expect(bb.books.length, 2);
      expect(b.shelf, isEmpty);
      expect(b.positionFor(two.id)!.textOffset, 7);
      expect(b.bookmarksFor(two.id).length, 1);
    },
  );
}
