import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Color;
import 'package:xml/xml.dart';

import 'catalog.dart';
import 'book_search.dart';
import 'legacy_transport.dart';
import 'publication_catalog.dart';
import 'tag_catalogue.dart';
import 'reader_content.dart' show readerIllustrationUrl;
import 'wenku_account.dart' show WenkuApiError, wenkuResponseCode;

typedef LegacyRequest = Future<String> Function(String action);

class _TagCursor {
  _TagCursor({this.refresh = false});
  bool refresh;
  int next = 1;
  int? pages;
  bool done = false;
}

List<NovelChapter> _decodeChapters(String source) {
  final document = XmlDocument.parse(source);
  if (document.rootElement.name.local == 'error') {
    throw const FormatException('目录接口返回错误');
  }
  final ids = <int>{};
  return List.unmodifiable([
    for (final element in document.findAllElements('chapter'))
      if (int.tryParse(element.getAttribute('cid') ?? '') case final int id)
        if (id > 0 && ids.add(id))
          NovelChapter(
            element.innerText.trim(),
            '',
            id: id,
            volumeId: element.parentElement?.name.local == 'volume'
                ? int.tryParse(
                        element.parentElement!.getAttribute('vid') ?? '',
                      ) ??
                      0
                : 0,
            volumeTitle: element.parentElement?.name.local == 'volume'
                ? element.parentElement!.children
                      .where((node) => node is XmlText || node is XmlCDATA)
                      .map((node) => node.value ?? '')
                      .join()
                      .trim()
                : '',
          ),
  ]);
}

List<({int id, Map<String, String> fields})> _decodeSearchResults(
  String source,
) {
  final code = wenkuResponseCode(source);
  if (code == 19) return const [];
  if (code != null) throw WenkuApiError(code);
  final document = XmlDocument.parse(source);
  if (document.rootElement.name.local != 'result') {
    throw const FormatException('搜索接口返回了非列表内容');
  }
  return [
    for (final item in document.findAllElements('item'))
      if (int.tryParse(item.getAttribute('aid') ?? '') case final int id)
        if (id > 0) (id: id, fields: LegacyWenkuRepository._fields(item)),
  ];
}

String _normalizeBody(String source) => source
    .replaceAllMapped(RegExp(r'<!--image-->(.*?)<!--image-->', dotAll: true), (
      match,
    ) {
      final url = readerIllustrationUrl(
        '<!--image-->${match[1]!.trim()}<!--image-->',
      );
      return '\n\n${url == null ? '[插图]' : '<!--image-->$url<!--image-->'}\n\n';
    })
    .replaceAll(RegExp(r'\r\n?'), '\n')
    .split('\n')
    .map((line) => line.trim())
    .where((line) => line.isNotEmpty)
    .join('\n\n');

/// Android v1.30 protocol adapter. The bridge keeps the original POST envelope;
/// this class only maps its existing XML responses into Flutter view models.
class LegacyWenkuRepository extends NovelRepository
    implements PublicationCatalog, ProgressiveTagCatalogue {
  LegacyWenkuRepository({
    LegacyRequest? request,
    LegacyRequest? publicationRequest,
    Object Function()? publicationSessionKey,
  }) : _request = request ?? LegacyTransport.request,
       _publicationRequest =
           publicationRequest ?? request ?? LegacyTransport.sessionRead,
       _publicationSessionKey = publicationSessionKey;

  final LegacyRequest _request;
  final LegacyRequest _publicationRequest;
  final Object Function()? _publicationSessionKey;
  final Map<(NovelSort, int), NovelPage> _pages = {};
  final Map<NovelSort, int> _listVersions = {};
  final Map<(NovelSort, int, int), Future<NovelPage>> _pageRequests = {};
  final Map<String, List<int>> _searchIds = {};
  final Map<String, int> _searchVersions = {};
  final Map<(String, int), Future<List<int>>> _searchRequests = {};
  final Map<(String, int), _TagCursor> _tagCursors = {};
  final _cappedTags = <(String, int)>{};
  final Map<(String, int), Future<void>> _tagRequests = {};
  final Map<int, Novel> _meta = {};
  final Map<int, Future<Novel?>> _metaRequests = {};
  final Map<int, List<NovelChapter>> _indexes = {};
  final Map<int, int> _indexVersions = {};
  final Map<(int, int), Future<List<NovelChapter>>> _indexRequests = {};
  final Map<int, Future<Novel>> _detailRequests = {};
  Future<List<PublicationLibrary>>? _libraries;
  int _libraryVersion = 0;
  final Map<int, int> _publicationVersions = {};
  final Map<(Object?, int, int, int), Future<NovelPage>> _publicationPages = {};

  @override
  Future<List<PublicationLibrary>> publicationLibraries({
    bool refresh = false,
  }) {
    if (refresh) {
      _libraryVersion++;
      _libraries = null;
    }
    final version = _libraryVersion;
    return _libraries ??= () async {
      try {
        return PublicationLibrary.parse(
          await _request('action=xml&item=sort&t=0'),
        );
      } catch (_) {
        if (version == _libraryVersion) _libraries = null;
        rethrow;
      }
    }();
  }

  @override
  Future<NovelPage> browsePublication(
    int libraryId, {
    int page = 1,
    bool refresh = false,
  }) {
    if (libraryId <= 0 || page <= 0) {
      throw ArgumentError('Invalid publication page');
    }
    final session = _publicationSessionKey?.call();
    _publicationPages.removeWhere((key, _) => key.$1 != session);
    if (refresh) {
      if (page == 1) {
        _publicationVersions[libraryId] =
            (_publicationVersions[libraryId] ?? 0) + 1;
        _publicationPages.removeWhere((key, _) => key.$2 == libraryId);
      } else {
        _publicationPages.removeWhere(
          (key, _) => key.$2 == libraryId && key.$3 == page,
        );
      }
    }
    final version = _publicationVersions[libraryId] ?? 0;
    final key = (session, libraryId, page, version);
    return _publicationPages.putIfAbsent(key, () async {
      try {
        final source = await _publicationRequest(
          'action=novellist&sort=$libraryId&page=$page&t=0',
        );
        final code = wenkuResponseCode(source);
        if (code != null) throw WenkuApiError(code);
        final result = _parsePage(source, page);
        if (_publicationSessionKey?.call() == session &&
            (_publicationVersions[libraryId] ?? 0) == version) {
          for (final novel in result.items) {
            if (_meta[novel.id]?.lastUpdate != novel.lastUpdate) {
              _indexes.remove(novel.id);
              _indexVersions[novel.id] = (_indexVersions[novel.id] ?? 0) + 1;
            }
            _meta[novel.id] = novel;
          }
        }
        return result;
      } catch (_) {
        _publicationPages.remove(key);
        rethrow;
      }
    });
  }

  NovelPage _parsePage(String source, int page) {
    final document = XmlDocument.parse(source);
    if (document.rootElement.name.local != 'result') {
      throw const FormatException('书目接口返回了非列表内容');
    }
    final items = <Novel>[];
    final seen = <int>{};
    for (final item in document.findAllElements('item')) {
      final id = int.tryParse(item.getAttribute('aid') ?? '');
      if (id != null && id > 0 && seen.add(id)) {
        items.add(_makeNovel(id, _fields(item)));
      }
    }
    final pages = document.findAllElements('page');
    final total = pages.isEmpty
        ? null
        : int.tryParse(pages.first.getAttribute('num') ?? '');
    if ((pages.isNotEmpty && (total == null || total < 0)) ||
        (items.isEmpty && total == null)) {
      throw const FormatException('书目接口页数无效');
    }
    return NovelPage(
      items: List.unmodifiable(items),
      page: page,
      totalPages: total,
    );
  }

  @override
  Future<List<Novel>> list() async => (await browse()).items;

  @override
  Future<NovelPage> browse({
    NovelSort sort = NovelSort.lastUpdate,
    int page = 1,
    bool refresh = false,
  }) async {
    if (page < 1) throw ArgumentError.value(page, 'page');
    if (refresh && page == 1) {
      _listVersions[sort] = (_listVersions[sort] ?? 0) + 1;
      _pages.removeWhere((key, _) => key.$1 == sort);
    } else if (refresh) {
      _pages.remove((sort, page));
    }
    final cached = _pages[(sort, page)];
    if (cached != null) return cached;
    final version = _listVersions[sort] ?? 0;
    final key = (sort, page, version);
    final pending = _pageRequests[key];
    if (pending != null) return pending;
    final request = _loadPage(sort, page, version);
    _pageRequests[key] = request;
    try {
      return await request;
    } finally {
      _pageRequests.remove(key);
    }
  }

  Future<NovelPage> _loadPage(NovelSort sort, int page, int version) async {
    final source = await _request(
      'action=novellist&sort=${sort.apiKey}&page=$page&t=0',
    );
    final document = XmlDocument.parse(source);
    if (document.rootElement.name.local != 'result') {
      throw const FormatException('书目接口返回了非列表内容');
    }
    final novels = <Novel>[];
    for (final item in document.findAllElements('item')) {
      final id = int.tryParse(item.getAttribute('aid') ?? '');
      if (id == null || id <= 0) continue;
      final values = _fields(item);
      var novel = _makeNovel(id, values);
      if (novel.tags.isEmpty && _meta[id]?.tags.isNotEmpty == true) {
        novel = novel.withGenre(_meta[id]!.genre);
      }
      novels.add(novel);
      if ((_listVersions[sort] ?? 0) == version) {
        final previous = _meta[id];
        if (previous?.lastUpdate != novel.lastUpdate) {
          _indexes.remove(id);
          _indexVersions[id] = (_indexVersions[id] ?? 0) + 1;
        }
        _meta[id] = novel;
      }
    }
    final pageElements = document.findAllElements('page');
    final total = pageElements.isEmpty
        ? null
        : int.tryParse(pageElements.first.getAttribute('num') ?? '');
    if (pageElements.isNotEmpty && (total == null || total < 0)) {
      throw const FormatException('书目接口页数无效');
    }
    if (novels.isEmpty && total == null) {
      throw const FormatException('书目列表缺少书籍或页数');
    }
    final result = NovelPage(
      items: List.unmodifiable(novels),
      page: page,
      totalPages: total,
    );
    if ((_listVersions[sort] ?? 0) == version) _pages[(sort, page)] = result;
    return result;
  }

  @override
  Future<Novel?> find(int id) async {
    if (_meta.containsKey(id)) return _meta[id];
    if (id <= 0) return null;
    final pending = _metaRequests[id];
    if (pending != null) return pending;
    final request = _loadMeta(id);
    _metaRequests[id] = request;
    try {
      return await request;
    } finally {
      _metaRequests.remove(id);
    }
  }

  Future<Novel?> _loadMeta(int id) async {
    final source = await _request('action=book&do=meta&aid=$id&t=0');
    final document = XmlDocument.parse(source);
    final values = _fields(document.rootElement);
    if ((values['Title'] ?? '').isEmpty) return null;
    final novel = _makeNovel(id, values);
    _meta[id] = novel;
    return novel;
  }

  @override
  Future<List<Novel>> search(String query) async =>
      (await searchPage(query)).items;

  @override
  Future<NovelPage> searchPage(
    String query, {
    int page = 1,
    bool refresh = false,
  }) => _searchPage(query, page: page, refresh: refresh);

  @override
  Future<NovelPage> authorPage(
    String author, {
    int page = 1,
    bool refresh = false,
  }) => _searchPage(
    author,
    page: page,
    refresh: refresh,
    field: BookSearchField.author,
  );

  @override
  Future<NovelPage> searchFilteredPage(
    String query, {
    BookSearchField field = BookSearchField.all,
    int page = 1,
    bool refresh = false,
  }) => _searchPage(query, field: field, page: page, refresh: refresh);

  @override
  Future<NovelPage> tagPage(
    String tag, {
    int page = 1,
    bool refresh = false,
    bool Function()? current,
  }) {
    final term = tag.trim();
    return _searchPage(
      term.startsWith('#') ? term.substring(1) : term,
      field: BookSearchField.tags,
      page: page,
      refresh: refresh,
      current: current,
    );
  }

  Future<NovelPage> _searchPage(
    String query, {
    int page = 1,
    bool refresh = false,
    BookSearchField field = BookSearchField.all,
    bool Function()? current,
  }) async {
    if (page < 1) throw ArgumentError.value(page, 'page');
    var term = query.trim();
    if (term.startsWith('#') && field == BookSearchField.all) {
      field = BookSearchField.tags;
      term = term.substring(1).trim();
    }
    if (term.isEmpty) {
      return field != BookSearchField.all
          ? NovelPage.fromItems(const [], page)
          : browse(page: page, refresh: refresh);
    }
    if (field == BookSearchField.id) {
      final id = int.tryParse(term);
      final book = id == null || id <= 0 ? null : await find(id);
      return NovelPage.fromItems(book == null ? const [] : [book], page);
    }
    final cacheKey = '${field.name}:$term';
    if (refresh && page == 1) {
      _searchIds.remove(cacheKey);
      _tagCursors.removeWhere((key, _) => key.$1 == cacheKey);
      _cappedTags.removeWhere((key) => key.$1 == cacheKey);
      _searchVersions[cacheKey] = (_searchVersions[cacheKey] ?? 0) + 1;
    }
    final version = _searchVersions[cacheKey] ?? 0;
    var ids =
        _searchIds[cacheKey] ??
        await _matchingIds(term, version, cacheKey, field);
    // The public tags search is capped at 20 and ignores page=. Continue
    // against the paginated, tag-bearing catalogue instead of declaring its
    // first 20 matches to be the complete collection. Existing browse cache is
    // shared by discovery and every tag; no detail request per catalogue book.
    _TagCursor? tagCursor;
    if (field == BookSearchField.tags &&
        (_cappedTags.contains((cacheKey, version)) ||
            _tagCursors.containsKey((cacheKey, version)))) {
      tagCursor = _tagCursors.putIfAbsent((
        cacheKey,
        version,
      ), () => _TagCursor(refresh: refresh));
      if ((page > 1 || ids.length < 20) && !tagCursor.done) {
        await _extendTagIndex(term, cacheKey, version, page * 20 + 1, current);
        ids = _searchIds[cacheKey] ?? ids;
      }
    }
    final matches = ids.skip((page - 1) * 20).take(20).toList();
    final found = <Novel>[];
    for (var start = 0; start < matches.length; start += 4) {
      if (current?.call() == false) break;
      final batch = matches.skip(start).take(4);
      final novels = await Future.wait(batch.map(find));
      found.addAll(novels.whereType<Novel>());
    }
    return NovelPage(
      items: List.unmodifiable(found),
      page: page,
      totalItems: tagCursor != null && !tagCursor.done ? null : ids.length,
      totalPages: tagCursor != null && !tagCursor.done
          ? null
          : (ids.length / 20).ceil(),
    );
  }

  Future<void> _extendTagIndex(
    String term,
    String key,
    int version,
    int needed,
    bool Function()? current,
  ) async {
    final ticket = (key, version);
    if (current?.call() == false) return;
    final pending = _tagRequests[ticket];
    if (pending != null) await pending;
    if ((_searchVersions[key] ?? 0) != version || current?.call() == false) {
      return;
    }
    final cursor = _tagCursors[ticket]!;
    if (cursor.done || (_searchIds[key]?.length ?? 0) >= needed) return;
    final request = () async {
      final ids = <int>{...?_searchIds[key]};
      final pattern = BookSearch(term, field: BookSearchField.tags);
      while (current?.call() != false &&
          !cursor.done &&
          ids.length < needed &&
          (_searchVersions[key] ?? 0) == version) {
        final count = cursor.pages == null
            ? 1
            : (cursor.pages! - cursor.next + 1).clamp(0, 4);
        if (count == 0) {
          cursor.done = true;
          break;
        }
        final pages = await Future.wait(
          List.generate(
            count,
            (i) => browse(
              page: cursor.next + i,
              refresh: cursor.refresh && cursor.next + i == 1,
            ),
          ),
        );
        if ((_searchVersions[key] ?? 0) != version ||
            current?.call() == false) {
          return;
        }
        for (final result in pages) {
          if (result.items.isNotEmpty &&
              result.items.every((b) => b.tags.isEmpty)) {
            throw const FormatException('书目接口没有返回标签，请稍后重试');
          }
          for (final book in result.items) {
            if (pattern.matches(
              title: book.title,
              author: book.author,
              tags: book.genre,
            )) {
              ids.add(book.id);
            }
          }
          cursor.refresh = false;
          cursor.pages = result.totalPages;
          cursor.next = result.page + 1;
          if (!result.hasMore || result.items.isEmpty) cursor.done = true;
        }
        _searchIds[key] = List<int>.unmodifiable(ids);
      }
    }();
    _tagRequests[ticket] = request;
    try {
      await request;
    } finally {
      if (identical(_tagRequests[ticket], request)) _tagRequests.remove(ticket);
    }
  }

  Future<List<int>> _matchingIds(
    String term,
    int version,
    String cacheKey,
    BookSearchField field,
  ) async {
    final key = (cacheKey, version);
    final pending = _searchRequests[key];
    if (pending != null) return pending;
    final request = _loadMatchingIds(term, version, cacheKey, field);
    _searchRequests[key] = request;
    try {
      return await request;
    } finally {
      _searchRequests.remove(key);
    }
  }

  Future<List<int>> _loadMatchingIds(
    String term,
    int version,
    String cacheKey,
    BookSearchField field,
  ) async {
    final pattern = BookSearch(term, field: field);
    final multipleTags =
        field == BookSearchField.tags && pattern.terms.length > 1;
    // A complete (<20) single-tag response is the cheapest complete seed for
    // an intersection. Only capped seeds need the shared paginated catalogue.
    final encoded = Uri.encodeQueryComponent(term);
    final responses = await Future.wait([
      if (field == BookSearchField.all || field == BookSearchField.title)
        _request('action=search&searchtype=articlename&searchkey=$encoded&t=0'),
      if (field == BookSearchField.all || field == BookSearchField.author)
        _request('action=search&searchtype=author&searchkey=$encoded&t=0'),
      if (multipleTags)
        for (final tag in pattern.terms)
          _request(
            'action=search&searchtype=tags&searchkey=${Uri.encodeQueryComponent(tag.text)}&t=0',
          )
      else if (field == BookSearchField.all || field == BookSearchField.tags)
        _request('action=search&searchtype=tags&searchkey=$encoded&t=0'),
    ]);
    final ids = <int>{};
    List<int>? bestSeed;
    var allCapped = true;
    for (final response in responses) {
      final matches = response.length > 64 * 1024
          ? await compute(_decodeSearchResults, response)
          : _decodeSearchResults(response);
      if (matches.length < 20) allCapped = false;
      if (multipleTags &&
          (bestSeed == null || matches.length < bestSeed.length)) {
        bestSeed = matches.map((m) => m.id).toList();
      }
      for (final match in matches) {
        ids.add(match.id);
        if ((_searchVersions[cacheKey] ?? 0) == version &&
            match.fields['Title']?.isNotEmpty == true) {
          final novel = _makeNovel(match.id, match.fields),
              old = _meta[match.id];
          if (old == null) {
            _meta[match.id] = novel;
          } else if (old.tags.isEmpty && novel.tags.isNotEmpty) {
            _meta[match.id] = old.withGenre(novel.genre);
          }
        }
      }
    }
    if (field == BookSearchField.tags &&
        allCapped &&
        (_searchVersions[cacheKey] ?? 0) == version) {
      _cappedTags.add((cacheKey, version));
    }
    final filtered = <int>[];
    if (multipleTags) {
      final candidates = bestSeed ?? const <int>[];
      for (var start = 0; start < candidates.length; start += 4) {
        final books = await Future.wait(
          candidates.skip(start).take(4).map(find),
        );
        filtered.addAll(
          books
              .whereType<Novel>()
              .where(
                (book) => pattern.matches(
                  title: book.title,
                  author: book.author,
                  tags: book.genre,
                ),
              )
              .map((book) => book.id),
        );
      }
    }
    final result = List<int>.unmodifiable(multipleTags ? filtered : ids);
    if ((_searchVersions[cacheKey] ?? 0) == version) {
      _searchIds[cacheKey] = result;
    }
    return result;
  }

  @override
  Future<Novel> detail(Novel novel) async {
    final pending = _detailRequests[novel.id];
    if (pending != null) return pending;
    // Opening a book is also the directory refresh boundary. Saved books must
    // discover newly published chapters without depending on the current list.
    _indexes.remove(novel.id);
    _indexVersions[novel.id] = (_indexVersions[novel.id] ?? 0) + 1;
    final request = _loadDetail(novel);
    _detailRequests[novel.id] = request;
    try {
      return await request;
    } finally {
      _detailRequests.remove(novel.id);
    }
  }

  Future<Novel> _loadDetail(Novel novel) async {
    var meta = await find(novel.id) ?? novel;
    // The full-meta endpoint can omit Tags even when novellist supplied them.
    // Sparse responses must not erase the server's already known labels.
    if (meta.tags.isEmpty && novel.tags.isNotEmpty) {
      meta = meta.withGenre(novel.genre);
      _meta[novel.id] = meta;
    }
    try {
      final source = await _request('action=book&do=intro&aid=${novel.id}&t=0');
      String intro;
      try {
        intro = XmlDocument.parse(source).rootElement.innerText.trim();
      } on XmlException {
        intro = source.trim();
      }
      if (intro.isEmpty) return meta;
      return Novel(
        id: meta.id,
        title: meta.title,
        author: meta.author,
        genre: meta.genre,
        summary: intro,
        colors: meta.colors,
        isComplete: meta.isComplete,
        coverUrl: meta.coverUrl,
        lastUpdate: meta.lastUpdate,
        chapterCount: meta.chapterCount,
      );
    } catch (_) {
      return meta;
    }
  }

  @override
  Future<List<NovelChapter>> chapters(int id) async {
    if (_indexes.containsKey(id)) return _indexes[id]!;
    final version = _indexVersions[id] ?? 0;
    final key = (id, version);
    final pending = _indexRequests[key];
    if (pending != null) return pending;
    final request = _loadChapters(id, version);
    _indexRequests[key] = request;
    try {
      return await request;
    } finally {
      _indexRequests.remove(key);
    }
  }

  Future<List<NovelChapter>> _loadChapters(int id, int version) async {
    final source = await _request('action=book&do=list&aid=$id&t=0');
    final result = source.length > 64 * 1024
        ? await compute(_decodeChapters, source)
        : _decodeChapters(source);
    if ((_indexVersions[id] ?? 0) == version) _indexes[id] = result;
    return result;
  }

  @override
  Future<String> chapterContent(int novelId, NovelChapter chapter) async {
    if (chapter.id == 0) return chapter.content;
    final source = await _request(
      'action=book&do=text&aid=$novelId&cid=${chapter.id}&t=0',
    );
    return source.length > 64 * 1024
        ? compute(_normalizeBody, source)
        : _normalizeBody(source);
  }

  static Map<String, String> _fields(XmlElement element) {
    final result = <String, String>{};
    for (final data in element.findAllElements('data')) {
      final name = data.getAttribute('name');
      if (name == null) continue;
      result[name] = (data.getAttribute('value') ?? data.innerText).trim();
    }
    return result;
  }

  static Novel _makeNovel(int id, Map<String, String> values) {
    const palettes = <List<Color>>[
      [Color(0xFF5E87B8), Color(0xFF222C5B)],
      [Color(0xFF66C9BC), Color(0xFF276A8F)],
      [Color(0xFFE6A5B7), Color(0xFF8F658E)],
      [Color(0xFFE9B277), Color(0xFFB76E6E)],
    ];
    final status = values['BookStatus'] ?? '';
    final intro = (values['IntroPreview'] ?? '').replaceAll(
      RegExp(r'[\s\u3000]+'),
      ' ',
    );
    return Novel(
      id: id,
      title: values['Title']?.isNotEmpty == true ? values['Title']! : '书籍 $id',
      author: values['Author'] ?? '佚名',
      genre: values['Tags']?.isNotEmpty == true ? values['Tags']! : '轻小说',
      summary: intro.isEmpty ? '点击查看作品介绍与目录。' : intro,
      colors: palettes[id % palettes.length],
      isComplete:
          status == '1' ||
          (!status.contains('未') &&
              !status.contains('连载') &&
              (status.contains('完结') || status.contains('已完成'))),
      coverUrl: 'https://img.wenku8.com/image/${id ~/ 1000}/$id/${id}s.jpg',
      lastUpdate: values['LastUpdate'],
    );
  }
}
