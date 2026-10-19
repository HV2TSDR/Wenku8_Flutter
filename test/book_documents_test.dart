import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenku8_flutter/book_documents.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <MethodCall>[];
  Object? result;
  setUp(() {
    calls.clear();
    result = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(BookDocuments.channel, (call) async {
          calls.add(call);
          return result;
        });
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(BookDocuments.channel, null),
  );
  test(
    'multi picker preserves individual errors and releases only copied sources',
    () async {
      result = [
        {'name': '一.epub', 'path': '/cache/import-1.source'},
        {'name': '二.epub', 'error': '云盘文件暂不可用'},
        {'name': '三.txt', 'path': '/cache/import-3.source'},
      ];
      final documents = BookDocuments();
      final books = await documents.pickBooks();
      expect(books.map((b) => b.name), ['一.epub', '二.epub', '三.txt']);
      expect(books[1].error, '云盘文件暂不可用');
      result = null;
      await documents.releaseBooks(books);
      expect(calls.map((c) => c.method), ['pickBooks', 'releaseBooks']);
      expect(calls.last.arguments, {
        'paths': ['/cache/import-1.source', '/cache/import-3.source'],
      });
    },
  );
  test(
    'cancelled multi picker returns empty; legacy picker keeps its map contract',
    () async {
      final documents = BookDocuments();
      expect(await documents.pickBooks(), isEmpty);
      result = {'name': '原书.epub', 'path': '/cache/import-source'};
      expect(await documents.pickBook(), (
        name: '原书.epub',
        path: '/cache/import-source',
      ));
      expect(calls.map((c) => c.method), ['pickBooks', 'pickBook']);
    },
  );
}
