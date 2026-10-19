import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:xml/xml.dart';
import 'package:wenku8_flutter/legacy_transport.dart';
import 'package:wenku8_flutter/legacy_wenku_repository.dart';
import 'package:wenku8_flutter/book_search.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'public tag result pagination contract',
    (tester) async {
      for (final page in [1, 2]) {
        final source = await LegacyTransport.request(
          'action=search&searchtype=tags&searchkey=${Uri.encodeQueryComponent('奇幻')}${page == 1 ? '' : '&page=$page'}&t=0',
        );
        final xml = XmlDocument.parse(source);
        final ids = xml
            .findAllElements('item')
            .map((e) => e.getAttribute('aid'))
            .toList();
        // Public catalogue metadata only; never an account/session operation.
        // ignore: avoid_print
        print(
          'TAG_CONTRACT ${jsonEncode({'requestedPage': page, 'count': ids.length, 'page': xml.findAllElements('page').map((e) => e.attributes.map((a) => '${a.name}=${a.value}').toList()).toList(), 'first': ids.firstOrNull, 'last': ids.lastOrNull})}',
        );
      }
      final repository = LegacyWenkuRepository();
      final first = await repository.searchFilteredPage(
        '奇幻',
        field: BookSearchField.tags,
      );
      final second = await repository.searchFilteredPage(
        '奇幻',
        field: BookSearchField.tags,
        page: 2,
      );
      expect(first.items.length, 20);
      expect(second.items.length, 20);
      expect(
        {
          ...first.items.map((b) => b.id),
          ...second.items.map((b) => b.id),
        }.length,
        40,
      );
      // ignore: avoid_print
      print(
        'TAG_COMPLETE_PAGE_OK unique=40 secondPage=${second.items.length} more=${second.hasMore}',
      );
      final list = XmlDocument.parse(
        await LegacyTransport.request(
          'action=novellist&sort=lastupdate&page=1&t=0',
        ),
      );
      final items = list.findAllElements('item').toList();
      // ignore: avoid_print
      print(
        'TAG_CATALOGUE ${jsonEncode({'items': items.length, 'tagged': items.where((e) => e.findAllElements('data').any((d) => d.getAttribute('name') == 'Tags' && (d.getAttribute('value') ?? '').isNotEmpty)).length, 'pages': list.findAllElements('page').map((e) => e.getAttribute('num')).toList()})}',
      );
    },
    skip: !const bool.fromEnvironment('LIVE_TAG_PROBE'),
  );
}
