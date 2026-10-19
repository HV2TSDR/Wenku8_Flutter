import 'package:flutter_test/flutter_test.dart';
import 'package:wenku8_flutter/wenku_reviews.dart';

String _page(String text, {int pages = 3}) =>
    '<result><page num="$pages"/>'
    '<item timestamp="20261005103000"><user uid="81">读者</user>'
    '<content>$text</content></item></result>';

void main() {
  test(
    'duplicate reply page does not hide subsequent discussion pages',
    () async {
      final requests = <String>[];
      final feed = WenkuReviewFeed(
        id: 81,
        replies: true,
        request: (action) async {
          requests.add(action);
          return _page(requests.length <= 2 ? '第一条' : '最后一页的回复');
        },
      );
      await feed.load();
      await feed.load();
      expect(feed.items.length, 1);
      expect(feed.page, 2);
      expect(feed.totalPages, 3);
      expect(feed.hasMore, isTrue);
      await feed.load();
      expect(feed.items.map((item) => item.content), ['第一条', '最后一页的回复']);
      expect(feed.hasMore, isFalse);
      expect(requests.last, contains('page=3'));
      feed.dispose();
    },
  );

  test(
    'large reply XML decodes outside the UI isolate without truncating text',
    () async {
      final content = List.generate(
        2000,
        (index) => '段落 $index，书评完整内容。',
      ).join('\n');
      final result = await WenkuReviewPage.parseAsync(
        _page(content),
        replies: true,
      );
      expect(result.items.single.content, content);
      expect(result.items.single.user, '读者');
      expect(result.totalPages, 3);
    },
  );

  test(
    'successful refresh replaces dedup identities and can append fresh replies',
    () async {
      var text = '旧回复';
      final feed = WenkuReviewFeed(
        id: 81,
        replies: true,
        request: (_) async => _page(text),
      );
      await feed.load();
      text = '新回复';
      await feed.load(refresh: true);
      text = '旧回复';
      await feed.load();
      expect(feed.items.map((item) => item.content), ['新回复', '旧回复']);
      expect(feed.firstIndex, 1);
      feed.dispose();
    },
  );
}
