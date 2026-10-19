import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenku8_flutter/book_import_limits.dart';
import 'package:wenku8_flutter/cloud_sources.dart';
import 'package:wenku8_flutter/local_books.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'document failures retain their actionable message and format limits differ',
    () {
      expect(localBookByteLimit('illustrated.EPUB'), 512 * 1024 * 1024);
      expect(localBookByteLimit('text.TXT'), 128 * 1024 * 1024);
      expect(localBookByteLimit('book.mobi'), 256 * 1024 * 1024);
      expect(
        cloudFailureMessage(
          PlatformException(code: 'document', message: '文件超过 256 MiB 大小限制'),
        ),
        '文件超过 256 MiB 大小限制',
      );
      expect(
        cloudFailureMessage(
          const FileSystemException('disk', '', OSError('no space', 28)),
        ),
        contains('存储空间不足'),
      );
    },
  );
  test(
    'oversized file is rejected before loading it and failed imports leave no staged book',
    () async {
      final root = await Directory.systemTemp.createTemp('book-import-limit-');
      addTearDown(() => root.delete(recursive: true));
      final books = LocalBookStore(Directory('${root.path}/books'));
      addTearDown(books.dispose);
      await books.load();
      final file = File('${root.path}/too-large.epub');
      final handle = await file.open(mode: FileMode.write);
      await handle.truncate(maxLocalEpubBytes + 1);
      await handle.close();
      await expectLater(
        books.importFile('too-large.epub', file.path),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('512 MiB'),
          ),
        ),
      );
      await file.writeAsBytes([1, 2, 3]);
      await expectLater(
        books.importFile('broken.epub', file.path),
        throwsFormatException,
      );
      expect(books.books, isEmpty);
      expect(await books.directory.list().isEmpty, isTrue);
    },
  );
}
