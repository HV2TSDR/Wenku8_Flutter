import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenku8_flutter/local_books.dart';
import 'package:wenku8_flutter/reader_content.dart';
import 'local_books_test.dart' show epubFixture;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    '65+ MiB unbroken TXT imports on a worker, stays bounded and reopens completely',
    () async {
      final root = await Directory.systemTemp.createTemp('wenku-large-import-');
      addTearDown(() => root.delete(recursive: true));
      final source = File('${root.path}/large.txt');
      final sink = source.openWrite();
      final block = utf8.encode('中文正文😀，继续阅读。' * 2048);
      final count = (66 * 1024 * 1024 / block.length).ceil();
      const start = '大书开头。', end = '大书结尾。';
      sink.add(utf8.encode(start));
      for (var i = 0; i < count; i++) {
        sink.add(block);
        if (i % 16 == 0) await sink.flush();
      }
      sink.add(utf8.encode(end));
      await sink.close();
      expect(await source.length(), greaterThan(65 * 1024 * 1024));
      final books = LocalBookStore(Directory('${root.path}/books'));
      await books.load();
      addTearDown(books.dispose);
      var beats = 0;
      final heartbeat = Timer.periodic(
        const Duration(milliseconds: 10),
        (_) => beats++,
      );
      final clock = Stopwatch()..start();
      final book = await books.importFile('大书.txt', source.path);
      heartbeat.cancel();
      clock.stop();
      expect(beats, greaterThan(0));
      expect(book.chapters.length, greaterThan(100));
      var characters = 0;
      for (final chapter in book.chapters) {
        final body = await books.chapterContent(book.id, chapter);
        expect(body.length, lessThan(110000));
        expect(body, isNot(contains('\uFFFD')));
        characters += body.replaceAll('\n', '').length;
      }
      expect(
        characters,
        start.length + end.length + count * utf8.decode(block).length,
      );
      expect(
        await books.chapterContent(book.id, book.chapters.first),
        startsWith(start),
      );
      expect(
        await books.chapterContent(book.id, book.chapters.last),
        endsWith(end),
      );
      final reopened = LocalBookStore(books.directory);
      await reopened.load();
      addTearDown(reopened.dispose);
      expect(reopened.book(book.id)!.chapters.length, book.chapters.length);
      expect((await books.importFile('大书.txt', source.path)).id, book.id);
      // Checkable measurement, not a claim about Android frame times.
      debugPrint(
        'LARGE_TXT bytes=${await source.length()} chapters=${book.chapters.length} workerMs=${clock.elapsedMilliseconds} uiHeartbeats=$beats',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
  test(
    '68+ MiB EPUB remains file backed and preserves chapters and image links',
    () async {
      final root = await Directory.systemTemp.createTemp('wenku-large-epub-');
      addTearDown(() => root.delete(recursive: true));
      final padding = File('${root.path}/resource.bin');
      final handle = await padding.open(mode: FileMode.write);
      await handle.truncate(4 * 1024 * 1024);
      await handle.close();
      final source = File('${root.path}/large.epub');
      final zip = ZipFileEncoder()
        ..create(source.path, level: ZipFileEncoder.store);
      for (final file in ZipDecoder().decodeBytes(epubFixture())) {
        zip.addArchiveFile(file);
      }
      for (var i = 0; i < 17; i++) {
        await zip.addFile(
          padding,
          'OPS/resources/$i.bin',
          ZipFileEncoder.store,
        );
      }
      zip.closeSync();
      expect(await source.length(), greaterThan(68 * 1024 * 1024));
      final books = LocalBookStore(Directory('${root.path}/books'));
      await books.load();
      addTearDown(books.dispose);
      final book = await books.importFile('大插图书.epub', source.path);
      expect(book.chapters.length, 2);
      final body = await books.chapterContent(book.id, book.chapters.first);
      expect(body, contains('第一段 & 第二句。'));
      expect(
        ReaderContent(body.split('\n\n')).illustrations.single,
        startsWith('wenku-local://'),
      );
      expect(
        await File('${books.directory.path}/${book.id}/cover.png').exists(),
        true,
      );
      debugPrint(
        'LARGE_EPUB bytes=${await source.length()} chapters=${book.chapters.length}',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
