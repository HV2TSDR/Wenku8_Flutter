import 'package:flutter/foundation.dart';
import 'package:xml/xml.dart';

import 'legacy_transport.dart';
import 'wenku_account.dart';

class WenkuReview {
  const WenkuReview({
    required this.id,
    required this.user,
    required this.userId,
    required this.title,
    required this.content,
    required this.timestamp,
    required this.replies,
  });
  final int id, userId, replies;
  final String user, title, content, timestamp;
  String get identity => id > 0 ? '$id' : '$userId/$timestamp/$content';
  String get date => RegExp(r'^\d{14}$').hasMatch(timestamp)
      ? '${timestamp.substring(0, 4)}-${timestamp.substring(4, 6)}-${timestamp.substring(6, 8)} ${timestamp.substring(8, 10)}:${timestamp.substring(10, 12)}'
      : timestamp;
}

class WenkuReviewPage {
  const WenkuReviewPage(this.items, this.totalPages);
  final List<WenkuReview> items;
  final int totalPages;
  static Future<WenkuReviewPage> parseAsync(
    String source, {
    bool replies = false,
  }) async => source.length < 8192
      ? parse(source, replies: replies)
      : compute(_parseReviewPage, (source, replies));
  static WenkuReviewPage parse(String source, {bool replies = false}) {
    final code = wenkuResponseCode(source);
    if (code != null) throw WenkuApiError(code);
    final root = XmlDocument.parse(source).rootElement;
    if (!{'result', 'metadata'}.contains(root.name.local)) {
      throw const FormatException('书评列表格式有误');
    }
    final total = int.tryParse(
      root.getElement('page')?.getAttribute('num') ?? '',
    );
    if (total == null || total < 0) throw const FormatException('书评页数格式有误');
    final seen = <String>{};
    final items = <WenkuReview>[];
    for (final item in root.findElements('item')) {
      final id = int.tryParse(item.getAttribute('rid') ?? '') ?? 0;
      final user = item.getElement('user');
      final rawContent = item.getElement('content')?.innerText.trim() ?? '';
      final title = replies
          ? ''
          : item.getElement('title')?.innerText.trim() ?? rawContent;
      final content = replies ? rawContent : '';
      if ((!replies && (id <= 0 || title.isEmpty)) ||
          (replies && content.isEmpty)) {
        continue;
      }
      final review = WenkuReview(
        id: id,
        user: user?.innerText.trim() ?? '',
        userId: int.tryParse(user?.getAttribute('uid') ?? '') ?? 0,
        title: title,
        content: content,
        timestamp: item.getAttribute(replies ? 'timestamp' : 'posttime') ?? '',
        replies: int.tryParse(item.getAttribute('replies') ?? '') ?? 0,
      );
      if (seen.add(review.identity)) items.add(review);
    }
    if (root.findElements('item').isNotEmpty && items.isEmpty) {
      throw const FormatException('书评内容格式有误');
    }
    return WenkuReviewPage(List.unmodifiable(items), total);
  }
}

WenkuReviewPage _parseReviewPage((String, bool) source) =>
    WenkuReviewPage.parse(source.$1, replies: source.$2);

class WenkuReviewFeed extends ChangeNotifier {
  WenkuReviewFeed({
    required this.id,
    this.replies = false,
    AccountRequest? request,
  }) : _request = request ?? LegacyTransport.sessionRead;
  final int id;
  final bool replies;
  final AccountRequest _request;
  final _identities = <String>{};
  List<WenkuReview> items = const [];
  int page = 0, totalPages = 0, revision = 0, firstIndex = 0;
  bool loading = false, hasMore = true;
  String? error;
  bool requiresLogin = false;
  int _generation = 0;
  bool _disposed = false;
  bool _failedRefresh = false;
  Future<void> load({bool refresh = false}) async {
    refresh = refresh || _failedRefresh;
    if (_disposed || (loading && !refresh) || (!refresh && !hasMore)) return;
    final generation = ++_generation;
    final next = refresh ? 1 : page + 1;
    loading = true;
    error = null;
    requiresLogin = false;
    notifyListeners();
    try {
      final source = await _request(
        replies
            ? 'action=review&do=show&rid=$id&page=$next&t=0'
            : 'action=review&do=list&aid=$id&page=$next&t=0',
      );
      final result = await WenkuReviewPage.parseAsync(source, replies: replies);
      if (_disposed || generation != _generation) return;
      final old = refresh ? <WenkuReview>[] : items;
      if (refresh) _identities.clear();
      final newItems = result.items
          .where((item) => _identities.add(item.identity))
          .toList();
      firstIndex = old.length;
      items = List.unmodifiable([...old, ...newItems]);
      page = next;
      totalPages = result.totalPages;
      _failedRefresh = false;
      revision++;
      // Overlapping/duplicate pages do not mean the discussion has ended.
      // Advance through the service's finite page count to reach later replies.
      hasMore = next < result.totalPages;
    } catch (failure) {
      if (_disposed || generation != _generation) return;
      error = WenkuAccount.describeError(failure);
      requiresLogin = failure is WenkuApiError && failure.code == 4;
      _failedRefresh = refresh;
    } finally {
      if (!_disposed && generation == _generation) {
        loading = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    super.dispose();
  }
}
