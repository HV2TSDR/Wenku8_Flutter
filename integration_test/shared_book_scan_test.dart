import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:wenku8_flutter/book_documents.dart';

// Opt in only on a dedicated QA emulator, with its own fixture in Download and
// explicit shared-storage permission. Never auto-run this on a user's phone.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'shared storage discovers, stages and incrementally acknowledges a book',
    (tester) async {
      final documents = BookDocuments();
      final range = await documents.selectAllScan();
      expect(range?.allStorage, true);
      expect(range?.readable, true);
      final first = await documents.scanBooks();
      final entry = first.books.singleWhere(
        (book) => book.name == 'novel-scan-qa-20261018.txt',
      );
      final source = await documents.stageScanBook(entry.token);
      try {
        expect(await File(source.path!).readAsString(), startsWith('第一章'));
        await documents.markScanBook(entry.token);
        await documents.finishBookScan();
      } finally {
        await documents.releaseBooks([source]);
      }
      final second = await documents.scanBooks();
      expect(second.books.where((book) => book.name == entry.name), isEmpty);
      expect(second.unchanged, greaterThanOrEqualTo(1));
      expect((await documents.scanFolderInfo())?.allStorage, true);
      expect(tester.takeException(), isNull);
    },
    skip: !const bool.fromEnvironment('WENKU_QA_SHARED_SCAN'),
  );
}
