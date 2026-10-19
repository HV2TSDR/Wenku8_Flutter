import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenku8_flutter/local_books.dart';
import 'package:wenku8_flutter/local_book_media.dart';
import 'package:wenku8_flutter/offline_cache.dart';
import 'package:wenku8_flutter/offline_repository.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/reader_content.dart';
import 'package:wenku8_flutter/legacy_wenku_repository.dart';

Uint8List epubFixture({Map<String, String> overrides = const {}}) {
  final entries = <String, List<int>>{
    'mimetype': utf8.encode('application/epub+zip'),
    'META-INF/container.xml': utf8.encode(
      '<container><rootfiles><rootfile full-path="OPS/book.opf"/></rootfiles></container>',
    ),
    'OPS/book.opf': utf8.encode(
      '''<package><metadata><title>测试原书</title><creator>本地作者</creator><meta name="cover" content="cover"/></metadata>
      <manifest><item id="a" href="a.xhtml" media-type="application/xhtml+xml"/><item id="b" href="b.xhtml" media-type="application/xhtml+xml"/>
      <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/><item id="cover" href="images/cover.png" media-type="image/png"/></manifest>
      <spine><itemref idref="a"/><itemref idref="b"/></spine></package>''',
    ),
    'OPS/toc.ncx': utf8.encode(
      '''<ncx><navMap><navPoint><navLabel><text>第一卷</text></navLabel><content src="a.xhtml"/>
      <navPoint><navLabel><text>卷内第一章</text></navLabel><content src="a.xhtml"/></navPoint>
      <navPoint><navLabel><text>卷内第二章</text></navLabel><content src="b.xhtml"/></navPoint></navPoint></navMap></ncx>''',
    ),
    'OPS/a.xhtml': utf8.encode(
      '<html><body><h1>第一章</h1><p>第一段 &amp; 第二句。</p><img src="images/cover.png"/><script>不应朗读</script></body></html>',
    ),
    'OPS/b.xhtml': utf8.encode('<html><body><p>第二章正文。</p></body></html>'),
    'OPS/images/cover.png': base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    ),
  };
  for (final entry in overrides.entries) {
    entries[entry.key] = utf8.encode(entry.value);
  }
  final archive = Archive();
  for (final e in entries.entries) {
    // Byte identity is the import/deduplication contract. Wall-clock ZIP
    // metadata must not turn a recreated fixture into a different original.
    archive.addFile(
      ArchiveFile(e.key, e.value.length, e.value)..lastModTime = 1704067200,
    );
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'remote XML retains direct volume CDATA and unchanged global order',
    () async {
      final repo = LegacyWenkuRepository(
        request: (_) async =>
            '<package><volume vid="10"><![CDATA[第一卷]]><chapter cid="1">序章</chapter><chapter cid="2">终章</chapter></volume><volume vid="20"><![CDATA[第二卷]]><chapter cid="3">序章</chapter><chapter cid="3">重复</chapter></volume></package>',
      );
      final chapters = await repo.chapters(1305);
      expect(chapters.map((c) => c.id), [1, 2, 3]);
      expect(chapters.map((c) => c.volumeTitle), ['第一卷', '第一卷', '第二卷']);
      expect(NovelVolume.of(chapters).map((v) => (v.start, v.end)), [
        (0, 2),
        (2, 3),
      ]);
    },
  );
  test(
    'TXT recognizes volumes, headings, and bounds unstructured paragraphs',
    () {
      final text =
          '前言正文。\n第一卷 雨\n第一章 相遇\n这是第一段。\n\n第二段。\n第二章 回声\n正文。\n第二卷 风\n序章\n最后一段。';
      final input = LocalBookInput(
        '一本书.txt',
        Uint8List.fromList(utf8.encode(text)),
        text: text,
      );
      final book = parseLocalBook(input);
      expect(book.novel.id, inInclusiveRange(localBookIdStart, 0x7fffffff));
      expect(book.novel.chapters.map((c) => c.title), [
        '一本书',
        '第一章 相遇',
        '第二章 回声',
        '序章',
      ]);
      expect(book.novel.chapters.last.volumeTitle, '第二卷 风');
      expect(book.bodies[1], '这是第一段。\n\n第二段。');
      expect(parseLocalBook(input).novel.id, book.novel.id);
      final long = '文' * 250000;
      final parsed = parseLocalBook(
        LocalBookInput(
          'long.txt',
          Uint8List.fromList(utf8.encode(long)),
          text: long,
        ),
      );
      expect(parsed.bodies.length, greaterThan(1));
      expect(parsed.bodies.every((c) => c.length < 110000), isTrue);
    },
  );
  test('EPUB follows spine, keeps volume labels and portable local images', () {
    final book = parseLocalBook(LocalBookInput('book.epub', epubFixture()));
    expect(book.novel.title, '测试原书');
    expect(book.novel.author, '本地作者');
    expect(book.novel.chapters.map((c) => c.title), ['卷内第一章', '卷内第二章']);
    expect(book.novel.chapters.every((c) => c.volumeTitle == '第一卷'), isTrue);
    expect(book.bodies.first, contains('第一段 & 第二句。'));
    expect(book.bodies.first, isNot(contains('不应朗读')));
    expect(book.images, isNotEmpty);
    final url = ReaderContent(
      book.bodies.first.split('\n\n'),
    ).illustrations.single;
    expect(LocalBookMedia.valid(Uri.parse(url)), isTrue);
    expect(book.novel.coverUrl, startsWith('wenku-local://'));
    expect(
      readerIllustrationUrl('<!--image-->file:///etc/passwd<!--image-->'),
      isNull,
    );
    expect(
      LocalBookMedia.valid(
        Uri.parse('wenku-local://1610612736/../../secret.png'),
      ),
      isFalse,
    );
  });
  test(
    'EPUB2 cover XHTML is resolved through its guide instead of becoming a missing cover',
    () {
      final book = parseLocalBook(
        LocalBookInput(
          'guide.epub',
          epubFixture(
            overrides: {
              'OPS/book.opf':
                  '<package><metadata><title>导读封面</title><meta name="cover" content="coverpage"/></metadata><manifest><item id="coverpage" href="a.xhtml" media-type="application/xhtml+xml"/><item id="body" href="b.xhtml" media-type="application/xhtml+xml"/></manifest><guide><reference type="cover" href="a.xhtml"/></guide><spine><itemref idref="body"/></spine></package>',
              'OPS/a.xhtml':
                  '<html><body><img src="images/cover.png"/></body></html>',
            },
          ),
        ),
      );
      expect(book.novel.coverUrl, endsWith('/cover.png'));
      expect(book.images.containsKey('cover.png'), true);
    },
  );
  test('missing optional cover XHTML does not reject the EPUB body', () {
    final book = parseLocalBook(
      LocalBookInput(
        'missing-cover.epub',
        epubFixture(
          overrides: {
            'OPS/book.opf':
                '<package><metadata><title>正文仍可阅读</title></metadata><manifest><item id="body" href="b.xhtml" media-type="application/xhtml+xml"/></manifest><guide><reference type="cover" href="missing.xhtml"/></guide><spine><itemref idref="body"/></spine></package>',
          },
        ),
      ),
    );
    expect(book.bodies.join(), contains('第二章正文'));
    expect(book.novel.coverUrl, isNull);
  });
  test('long TXT preserves surrogate pairs at a paragraph boundary', () {
    final text = '${'字' * 3999}😀尾';
    final book = parseLocalBook(
      LocalBookInput(
        'Unicode.txt',
        Uint8List.fromList(utf8.encode(text)),
        text: text,
      ),
    );
    expect(book.bodies.join().replaceAll('\n\n', ''), text);
    expect(utf8.decode(utf8.encode(book.bodies.single)), contains('😀尾'));
  });
  test(
    'EPUB splits anchored NCX chapters in one spine file and reads SVG-wrapped images',
    () {
      final book = parseLocalBook(
        LocalBookInput(
          'anchors.epub',
          epubFixture(
            overrides: {
              'OPS/book.opf':
                  '<package><metadata><title>合订本</title></metadata><manifest><item id="a" href="a.xhtml" media-type="application/xhtml+xml"/><item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/></manifest><spine><itemref idref="a"/></spine></package>',
              'OPS/toc.ncx':
                  '<n:ncx xmlns:n="http://www.daisy.org/z3986/2005/ncx/"><n:navMap><n:navPoint><n:navLabel><n:text>第一卷</n:text></n:navLabel><n:content src="a.xhtml#start"/><n:navPoint><n:navLabel><n:text>序章</n:text></n:navLabel><n:content src="a.xhtml#start"/></n:navPoint><n:navPoint><n:navLabel><n:text>第二章</n:text></n:navLabel><n:content src="a.xhtml#next"/></n:navPoint></n:navPoint></n:navMap></n:ncx>',
              'OPS/a.xhtml':
                  '<html><body><h2 id="start">序章</h2><p>只有序章的正文。</p><h2 id="next">第二章</h2><p>只有第二章的正文。</p><svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"><image xlink:href="images/cover.png"/></svg></body></html>',
            },
          ),
        ),
      );
      expect(book.novel.chapters.map((c) => c.title), ['序章', '第二章']);
      expect(book.novel.chapters.map((c) => c.volumeTitle), ['第一卷', '第一卷']);
      expect(book.bodies.first, '只有序章的正文。');
      expect(book.bodies.last, contains('只有第二章的正文。'));
      expect(
        ReaderContent(book.bodies.last.split('\n\n')).illustrations,
        hasLength(1),
      );
    },
  );
  test('EPUB 3 nav keeps span-only volumes and fragment targets', () {
    final book = parseLocalBook(
      LocalBookInput(
        'epub3.epub',
        epubFixture(
          overrides: {
            'OPS/book.opf':
                '<package><metadata><title>EPUB 3</title></metadata><manifest><item id="a" href="a.xhtml" media-type="application/xhtml+xml"/><item id="nav" href="nav.xhtml" properties="nav" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="a"/></spine></package>',
            'OPS/nav.xhtml':
                '<html><body><nav epub:type="toc"><ol><li><span>第二卷</span><ol><li><a href="a.xhtml#one">第一章</a></li><li><a href="a.xhtml#two">第二章</a></li></ol></li></ol></nav></body></html>',
            'OPS/a.xhtml':
                '<html><body><h1 id="one">第一章</h1><p>甲。</p><h1 id="two">第二章</h1><p>乙。</p></body></html>',
          },
        ),
      ),
    );
    expect(book.novel.chapters.map((c) => c.title), ['第一章', '第二章']);
    expect(book.novel.chapters.every((c) => c.volumeTitle == '第二卷'), isTrue);
    expect(book.bodies, ['甲。', '乙。']);
  });
  test(
    'unsupported and traversing archives are rejected before any import',
    () {
      expect(
        () =>
            parseLocalBook(LocalBookInput('bad.pdf', Uint8List.fromList([1]))),
        throwsFormatException,
      );
      final archive = Archive()
        ..addFile(ArchiveFile('../escape', 3, [1, 2, 3]));
      expect(
        () => boundedZip(Uint8List.fromList(ZipEncoder().encode(archive))),
        throwsFormatException,
      );
    },
  );
  test(
    'local books are durable across restart, duplicates and cache cleaning',
    () async {
      final root = await Directory.systemTemp.createTemp('wenku-import-test-');
      addTearDown(() => root.delete(recursive: true));
      final store = LocalBookStore(Directory('${root.path}/books'));
      await store.load();
      addTearDown(store.dispose);
      final bytes = epubFixture();
      final book = await store.import(LocalBookInput('book.epub', bytes));
      final again = await store.import(LocalBookInput('renamed.epub', bytes));
      expect(again.id, book.id);
      expect(store.books.length, 1);
      final cache = OfflineCacheStore(Directory('${root.path}/network'));
      addTearDown(cache.dispose);
      final repo = OfflineNovelRepository(
        remote: const DemoNovelRepository(),
        cache: cache,
        local: store,
      );
      addTearDown(repo.dispose);
      await repo.clearCache();
      expect((await repo.find(book.id))!.title, book.title);
      expect(
        await repo.chapterContent(book.id, book.chapters.first),
        contains('第一段'),
      );
      final restored = LocalBookStore(store.directory);
      await restored.load();
      addTearDown(restored.dispose);
      expect(restored.book(book.id)!.chapters.first.volumeTitle, '第一卷');
      expect((await restored.original(book.id)).bytes, bytes);
      final saved = book.withChapters(book.chapters);
      final epoch = cache.epochFor(book.id);
      await cache.saveBook(saved, epoch: epoch);
      expect(
        (await cache.readBook(book.id))!.chapters.first.volumeTitle,
        '第一卷',
      );
    },
  );
}
