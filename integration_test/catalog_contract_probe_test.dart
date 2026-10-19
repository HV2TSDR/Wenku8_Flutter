import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:wenku8_flutter/legacy_transport.dart';
import 'package:wenku8_flutter/publication_catalog.dart';
import 'package:wenku8_flutter/wenku_account.dart';
import 'package:xml/xml.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('public publication and author protocol evidence', (
    tester,
  ) async {
    final libraries = PublicationLibrary.parse(
      await LegacyTransport.request('action=xml&item=sort&t=0'),
    );
    expect(libraries, isNotEmpty);
    for (final action in [
      'action=novellist&sort=${libraries.first.id}&page=1&t=0',
      'action=articlelist&sort=${libraries.first.id}&page=1',
      'action=search&searchtype=author&searchkey=${Uri.encodeQueryComponent('水泽梦')}&t=0',
    ]) {
      final text = await LegacyTransport.request(action);
      final code = wenkuResponseCode(text);
      if (code != null) {
        // A diagnostic refusal is evidence, not a successful category load.
        // No session is read, changed or printed by this public probe.
        // ignore: avoid_print
        print('CATALOG_PROTOCOL $action code=$code');
      } else {
        final document = XmlDocument.parse(text);
        // ignore: avoid_print
        print(
          'CATALOG_PROTOCOL $action root=${document.rootElement.name.local} '
          'items=${document.findAllElements('item').length} '
          'pages=${document.findAllElements('page').map((e) => e.getAttribute('num')).join(',')}',
        );
      }
    }
  });
}
