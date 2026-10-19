import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:html/parser.dart' as html;
import 'package:xml/xml.dart';
import 'catalog.dart';
import 'legacy_transport.dart';
import 'publication_catalog.dart';

class PublicationConnectionRequired implements Exception {
  const PublicationConnectionRequired();
}

class WebPublicationPage {
  const WebPublicationPage(this.ids, this.totalPages);
  final List<int> ids;
  final int totalPages;
}

/// The native session owner supplies an API id list or the official website's
/// `class` listing, reusing the signed-in identity for either representation.
WebPublicationPage parseWebPublicationPage(String source) {
  if (source.isEmpty) throw const FormatException('官网分类返回空内容');
  if (RegExp(
    r'^(?:<\?xml[^>]*>\s*)?<result(?:\s|/|>)',
  ).hasMatch(source.trim())) {
    final root = XmlDocument.parse(source).rootElement;
    final ids = <int>{};
    for (final item in root.findElements('item')) {
      final id = int.tryParse(item.getAttribute('aid') ?? '');
      if (id != null && id > 0 && id < 0x60000000) ids.add(id);
    }
    final pages =
        int.tryParse(root.getElement('page')?.getAttribute('num') ?? '') ?? 1;
    if (pages < 0 ||
        pages > 100000 ||
        root.findElements('item').isNotEmpty && ids.isEmpty) {
      throw const FormatException('出版分类书目格式有误');
    }
    return WebPublicationPage(List.unmodifiable(ids), pages);
  }
  final document = html.parse(source),
      content = document.querySelector('#content');
  final ids = <int>{};
  if (content != null) {
    for (final anchor in content.querySelectorAll('a[href]')) {
      final uri = Uri.tryParse(anchor.attributes['href'] ?? '');
      if (uri == null ||
          uri.hasAuthority &&
              !{'www.wenku8.net', 'wenku8.net'}.contains(uri.host)) {
        continue;
      }
      final match = RegExp(r'(?:^|/)book/(\d+)\.htm$').firstMatch(uri.path);
      final id = match != null
          ? int.tryParse(match[1]!)
          : uri.path.endsWith('/modules/article/articleinfo.php')
          ? int.tryParse(uri.queryParameters['id'] ?? '')
          : null;
      if (id != null && id > 0 && id < 0x60000000) ids.add(id);
    }
  }
  if (ids.isEmpty) {
    final text = document.body?.text ?? '';
    if (document.querySelector('input[name="password"]') != null ||
        RegExp(r'(请先|必须|需要|尚未|还未|没有).{0,8}(登录|登陆)|(登录|登陆)后').hasMatch(text)) {
      throw const PublicationConnectionRequired();
    }
    if (content != null &&
        RegExp(
          r'没有.{0,10}(书籍|作品|记录)|暂无.{0,10}(书籍|作品)',
        ).hasMatch(content.text)) {
      return const WebPublicationPage([], 0);
    }
    throw const FormatException('官网分类页面格式发生变化，请稍后重试');
  }
  var pages = 1;
  for (final anchor in (content ?? document.body!).querySelectorAll(
    'a[href]',
  )) {
    final uri = Uri.tryParse(anchor.attributes['href'] ?? '');
    if (uri == null || !uri.path.endsWith('articlelist.php')) continue;
    final page = int.tryParse(uri.queryParameters['page'] ?? '');
    if (page != null && page > pages && page <= 100000) pages = page;
  }
  return WebPublicationPage(List.unmodifiable(ids), pages);
}

class WebPublicationCatalog implements PublicationCatalog {
  WebPublicationCatalog({
    required this.categories,
    required this.books,
    Future<String> Function(int library, int page)? read,
    Object Function()? sessionKey,
  }) : _read = read ?? LegacyTransport.publicationPage,
       _sessionKey = sessionKey ?? (() => 0);
  final PublicationCatalog categories;
  final NovelRepository books;
  final Future<String> Function(int library, int page) _read;
  final Object Function() _sessionKey;
  final _pages = <(Object, int, int, int), Future<NovelPage>>{};
  final _versions = <int, int>{};

  @override
  Future<List<PublicationLibrary>> publicationLibraries({
    bool refresh = false,
  }) => categories.publicationLibraries(refresh: refresh);

  @override
  Future<NovelPage> browsePublication(
    int libraryId, {
    int page = 1,
    bool refresh = false,
  }) {
    if (libraryId <= 0 || page <= 0) {
      throw ArgumentError('Invalid publication page');
    }
    final session = _sessionKey();
    // Discard cached pages belonging to a previous account/website connection.
    _pages.removeWhere((key, _) => key.$1 != session);
    if (refresh) {
      if (page == 1) _versions[libraryId] = (_versions[libraryId] ?? 0) + 1;
      _pages.removeWhere(
        (key, _) => key.$2 == libraryId && (page == 1 || key.$3 == page),
      );
    }
    final key = (session, libraryId, page, _versions[libraryId] ?? 0);
    return _pages.putIfAbsent(key, () async {
      try {
        final source = await _read(libraryId, page);
        final parsed = source.length > 64 * 1024
            ? await compute(parseWebPublicationPage, source)
            : parseWebPublicationPage(source);
        final found = <int, Novel>{};
        var cursor = 0;
        Future<void> resolve() async {
          while (cursor < parsed.ids.length) {
            final id = parsed.ids[cursor++];
            final book = await books.find(id);
            if (book != null) found[id] = book;
          }
        }

        await Future.wait(
          List.generate(parsed.ids.length.clamp(0, 4), (_) => resolve()),
        );
        return NovelPage(
          items: [
            for (final id in parsed.ids)
              if (found[id] != null) found[id]!,
          ],
          page: page,
          totalPages: parsed.totalPages,
        );
      } on PlatformException catch (failure) {
        _pages.remove(key);
        if (failure.code == 'WEB_LOGIN_REQUIRED') {
          throw const PublicationConnectionRequired();
        }
        if (failure.code.startsWith('WEB_')) {
          throw FormatException(failure.message ?? '官网分类暂时不可用');
        }
        rethrow;
      } catch (_) {
        _pages.remove(key);
        rethrow;
      }
    });
  }
}
