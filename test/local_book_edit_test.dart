import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenku8_flutter/local_books.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'metadata edits retain identity, original bytes, chapters and survive reload/reimport',
    () async {
      final root = await Directory.systemTemp.createTemp('local-book-edit-');
      addTearDown(() => root.delete(recursive: true));
      final books = LocalBookStore(root);
      await books.load();
      addTearDown(books.dispose);
      const text = '第一章\n原书内容保持不变。';
      final input = LocalBookInput(
        '原书.txt',
        Uint8List.fromList(utf8.encode(text)),
        text: text,
      );
      final original = await books.import(input);
      final changed = await books.updateMetadata(
        original.id,
        title: '新的书名',
        author: '新的作者',
        summary: '自己的简介',
      );
      expect(changed.id, original.id);
      expect(changed.chapters, original.chapters);
      expect(
        await books.chapterContent(changed.id, changed.chapters.single),
        contains('原书内容保持不变'),
      );
      expect((await books.original(original.id)).bytes, input.bytes);
      expect((await books.import(input)).title, '新的书名');
      final next = LocalBookStore(root);
      addTearDown(next.dispose);
      await next.load();
      expect(next.book(original.id)!.title, '新的书名');
      expect(next.book(original.id)!.author, '新的作者');
      final stale = books.exportMetadata();
      await books.updateMetadata(
        original.id,
        title: '较新的书名',
        author: '',
        summary: '',
      );
      await books.mergeMetadata(stale);
      expect(books.book(original.id)!.title, '较新的书名');
      await expectLater(
        books.updateMetadata(original.id, title: ' ', author: '', summary: ''),
        throwsFormatException,
      );
      expect(books.book(original.id)!.title, '较新的书名');
    },
  );
}
