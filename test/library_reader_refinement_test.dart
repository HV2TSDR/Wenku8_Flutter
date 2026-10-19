import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/automatic_illustrations.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/archive_carousel.dart';
import 'package:wenku8_flutter/book_collection_layout.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/local_book_media.dart';
import 'package:wenku8_flutter/local_books.dart';
import 'package:wenku8_flutter/local_library_page.dart';
import 'package:wenku8_flutter/local_library_preferences.dart';
import 'package:wenku8_flutter/pages.dart' show NovelRow;
import 'package:wenku8_flutter/reader_content.dart';
import 'package:wenku8_flutter/reader_preferences.dart';
import 'package:wenku8_flutter/reader_selection.dart';
import 'package:wenku8_flutter/wenku_account.dart';
import 'package:wenku8_flutter/wenku_shelf_sync.dart';
import 'support/visual_review.dart';

class _InventoryBooks extends LocalBookStore {
  _InventoryBooks() : super(Directory.systemTemp);
  final inventory = List.generate(
    12,
    (index) => Novel(
      id: localBookIdStart + index,
      title: '本地藏书 ${index + 1}',
      author: '本地作者',
      genre: '本地导入',
      summary: '',
      colors: const [Colors.grey, Colors.black],
      chapters: const [NovelChapter('第一章', '正文。', id: 1)],
    ),
  );
  @override
  List<Novel> get books => inventory;
  @override
  Novel? book(int id) => inventory.where((b) => b.id == id).firstOrNull;
  @override
  int importedAt(int id) => id;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadReviewFonts);
  testWidgets(
    'local 3D plus list keeps every book in a complete index, with compact shared controls',
    (tester) async {
      SharedPreferences.setMockInitialValues({'reduceMotion': true});
      final library = await LibraryState.load();
      final books = _InventoryBooks();
      addTearDown(library.dispose);
      addTearDown(books.dispose);
      tester.view.physicalSize = const Size(390, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final boundary = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: MaterialApp(
            theme: novelTheme(Brightness.light),
            home: LocalLibraryPage(
              books: books,
              state: library,
              onOpen: (_, _) {},
            ),
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ArchiveFileCarousel>(find.byType(ArchiveFileCarousel))
            .books
            .length,
        10,
      );
      Set<int> listed() {
        final list = tester.widget<BookCollectionSliver>(
          find.byType(BookCollectionSliver),
        );
        expect(list.itemCount, 12);
        return {
          for (var i = 0; i < list.itemCount; i++)
            ((list.itemBuilder(
                              tester.element(find.byType(BookCollectionSliver)),
                              i,
                            )
                            as LoadedContentItem)
                        .child
                    as NovelRow)
                .novel
                .id,
        };
      }

      expect(listed(), books.books.map((b) => b.id).toSet());
      final category = tester.getRect(
        find.byKey(const ValueKey('local-category')),
      );
      final options = tester.getRect(
        find.byKey(const ValueKey('local-display')),
      );
      expect(category.center.dy, closeTo(options.center.dy, 1));
      await captureReview(tester, boundary, 'local-complete-index');
      await tester.runAsync(
        () => library.organization.setView(LocalLibraryView.list),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ArchiveFileCarousel), findsNothing);
      expect(listed(), books.books.map((b) => b.id).toSet());
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  test(
    'four margins migrate old records, round trip, and invalidate geometry independently',
    () {
      final old = ReaderPreferences.fromJson({'margin': 30});
      expect(
        [old.leftMargin, old.rightMargin, old.marginTop, old.marginBottom],
        [30, 30, 8, 8],
      );
      final custom = old.copyWith(
        marginLeft: 12,
        marginRight: 42,
        marginTop: 0,
        marginBottom: 70,
      );
      final restored = ReaderPreferences.fromJson(custom.toJson());
      expect(
        [
          restored.leftMargin,
          restored.rightMargin,
          restored.marginTop,
          restored.marginBottom,
        ],
        [12, 42, 0, 70],
      );
      expect(restored.layoutKey, isNot(old.layoutKey));
      expect(
        restored.copyWith(pageEffect: ReaderPageEffect.cover).layoutKey,
        restored.layoutKey,
      );
      final linked = restored.copyWith(margin: 80);
      expect(ReaderPreferences.fromJson(linked.toJson()).leftMargin, 80);
    },
  );
  test(
    'sentence selection includes closing quotes and cannot cross tategaki source paragraphs',
    () {
      const text = '「第一句结束。」第二句比较长，也要完整选中！最后一句。';
      final range = readerSentenceRange(text, text.indexOf('比较'));
      expect(text.substring(range.start, range.end), '第二句比较长，也要完整选中！');
      final quoted = readerSentenceRange(text, 3);
      expect(text.substring(quoted.start, quoted.end), '「第一句结束。」');
      const vertical = 'First paragraphNo punctuation hereAnother paragraph';
      final paragraph = readerSentenceRange(
        vertical,
        25,
        paragraphEnds: [15, 34, vertical.length],
      );
      expect(paragraph, const TextRange(start: 15, end: 34));
    },
  );
  test(
    'matching EPUB context restores only unique adjacent illustration anchors without changing paragraph IDs',
    () {
      const a = '这一段是图前的正文，描述窗边微风与树影，所有字符都必须来自同一版本。';
      const b = '这一段是图后的正文，书页上的故事继续向前，这里有足够的相邻原文用于核验。';
      const image =
          '<!--image-->wenku-local://1610612751/img-2.jpg<!--image-->';
      final source = ReaderContent([a, b, '最后一段']);
      final placed = autoIllustrationsFromReference(
        source,
        ReaderContent([a, image, b]),
      );
      expect(placed.readingOrder, [0, 3, 1, 2]);
      expect(placed.inlineOwners, {3: 0});
      expect(placed.paragraphs.take(3), source.paragraphs);
      expect(
        autoIllustrationsFromReference(
          source,
          ReaderContent([a, image, '不同翻译版本。']),
        ),
        same(source),
      );
      final repeated = ReaderContent([a, b, a, b]);
      expect(
        autoIllustrationsFromReference(repeated, ReaderContent([a, image, b])),
        same(repeated),
      );
      expect(
        autoIllustrationsFromReference(
          source,
          ReaderContent([a, '$image<!--epub-image:w=1em-->', b]),
        ),
        same(source),
      );
    },
  );
  test(
    'legacy img-N cover keeps stable bytes and future after reader media loads; explicit eviction reloads',
    () async {
      final root = await Directory.systemTemp.createTemp('wenku-cover-role-');
      final oldRoot = LocalBookMedia.root;
      const id = 1610612751, url = 'wenku-local://$id/img-2.jpg';
      final folder = Directory('${root.path}/$id');
      await folder.create();
      final cover = File('${folder.path}/img-2.jpg');
      await cover.writeAsBytes([1, 2, 3]);
      await File('${folder.path}/img-3.jpg').writeAsBytes([7, 8]);
      LocalBookMedia.root = root;
      addTearDown(() async {
        LocalBookMedia.evict(id);
        LocalBookMedia.root = oldRoot;
        await root.delete(recursive: true);
      });
      final first = LocalBookMedia.loadCover(url);
      expect(await first, [1, 2, 3]);
      await LocalBookMedia.load('wenku-local://$id/img-3.jpg');
      expect(LocalBookMedia.loadCover(url), same(first));
      expect(LocalBookMedia.peek(url), [1, 2, 3]);
      LocalBookMedia.evict(id);
      await cover.writeAsBytes([4, 5, 6]);
      expect(await LocalBookMedia.loadCover(url), [4, 5, 6]);
    },
  );
  test(
    'cloud shelf merges once, then respects local and remote deletions while keeping imports private',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final library = await LibraryState.load();
      final remote = <int>{72};
      final mutations = <String>[];
      final account = WenkuAccount(
        hasSession: () async => true,
        avatarRequest: () async => Uint8List(0),
        request: (action) async {
          if (action == 'action=userinfo') {
            return '<metadata><item name="uid">321</item><item name="uname">reader</item></metadata>';
          }
          final query = Uri.splitQueryString(action);
          if (query['do'] == null) {
            return '<metadata>${remote.map((id) => '<book aid="$id"><name>Book $id</name></book>').join()}</metadata>';
          }
          mutations.add(action);
          final id = int.parse(query['aid']!);
          query['do'] == 'add' ? remote.add(id) : remote.remove(id);
          return '1';
        },
      );
      await account.initialize();
      await library.addShelfIds([71, 1610612751]);
      // A previously removed ID still has a revision. A later remote add must
      // compare against that revision, not assume every non-member is new.
      await library.setShelfMembership(72, true);
      await library.setShelfMembership(72, false);
      final sync = WenkuShelfSync(
        account: account,
        library: library,
        preferences: prefs,
      );
      addTearDown(() {
        sync.dispose();
        account.dispose();
        library.dispose();
      });
      await sync.synchronize();
      expect(sync.error, isNull);
      expect(library.shelf, {71, 72});
      expect(remote, {71, 72});
      expect(mutations.length, 1);
      await library.setShelfMembership(71, false);
      await library.addShelfIds([74]);
      remote
        ..remove(72)
        ..add(73);
      await sync.synchronize();
      expect(library.shelf, {73, 74});
      expect(remote, {73, 74});
      expect(
        jsonDecode(prefs.getString('wenkuShelfSync.v1.321')!)['local'].toSet(),
        {73, 74},
      );
    },
  );
  test(
    'cloud results never overwrite membership changed during a request',
    () async {
      SharedPreferences.setMockInitialValues({});
      final library = await LibraryState.load();
      addTearDown(library.dispose);
      await library.addShelfIds([71]);
      final before = library.shelfRevisions;
      await library.setShelfMembership(71, false);
      await library.setShelfMembership(72, true);
      await library.applyCloudShelf(
        add: {71},
        remove: {72},
        expectedRevisions: before,
      );
      expect(library.shelf, {72});
    },
  );
}
