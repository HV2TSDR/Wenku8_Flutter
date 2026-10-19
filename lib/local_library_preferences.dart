import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'catalog.dart';
import 'book_search.dart';

enum LocalLibraryView { shelf, list }

enum LocalLibrarySort { recentAdded, recentRead, title }

/// Device layout stays local; named groups and timestamped assignments can be
/// merged with the original books. Deletion tombstones prevent resurrection.
class LocalLibraryPreferences extends ChangeNotifier {
  LocalLibraryPreferences(this.preferences);
  static const key = 'localLibraryView.v1';
  static const all = '_all', unfiled = '_unfiled';
  final SharedPreferences preferences;
  LocalLibraryView view = LocalLibraryView.shelf;
  LocalLibrarySort sort = LocalLibrarySort.recentAdded;
  String selected = all;
  String readingFilter = 'all';
  String shelfSelected = all;
  final Map<String, Map<String, dynamic>> _groups = {};
  final Map<int, Map<String, dynamic>> _assignments = {};
  int _clock = 0;
  Future<void> _writes = Future.value();
  bool _disposed = false;

  Map<String, String> get groups => {
    for (final entry in _groups.entries)
      if (entry.value['deleted'] != true)
        entry.key: entry.value['name'] as String,
  };
  String groupOf(int id) {
    final value = _assignments[id]?['group'];
    return value is String && groups.containsKey(value) ? value : unfiled;
  }

  String nameOf(String id) => id == all
      ? '全部书籍'
      : id == unfiled
      ? '未分类'
      : groups[id] ?? '全部书籍';
  bool showsShelf(int count) => view == LocalLibraryView.shelf && count >= 10;
  void refresh() {
    load();
    if (!_disposed) notifyListeners();
  }

  Future<void> setEncoding(String value) async {
    if (!await preferences.setString('localTxtEncoding', value)) {
      throw const FormatException('编码设置保存失败');
    }
    if (!_disposed) notifyListeners();
  }

  void load() {
    final text = preferences.getString(key);
    if (text == null) return;
    final raw = jsonDecode(text);
    if (raw is! Map || raw['version'] != 1) {
      throw const FormatException('本地分类记录格式有误');
    }
    view = LocalLibraryView.values.firstWhere(
      (v) => v.name == raw['view'],
      orElse: () => LocalLibraryView.shelf,
    );
    sort = LocalLibrarySort.values.firstWhere(
      (v) => v.name == raw['sort'],
      orElse: () => LocalLibrarySort.recentAdded,
    );
    readingFilter =
        ['unread', 'reading', 'finished'].contains(raw['readingFilter'])
        ? raw['readingFilter'] as String
        : 'all';
    _accept(raw['organization']);
    selected = raw['selected'] is String ? raw['selected'] : all;
    if (selected != all &&
        selected != unfiled &&
        !groups.containsKey(selected)) {
      selected = all;
    }
    shelfSelected = raw['shelfSelected'] is String ? raw['shelfSelected'] : all;
    if (shelfSelected != all &&
        shelfSelected != unfiled &&
        !groups.containsKey(shelfSelected)) {
      shelfSelected = all;
    }
  }

  int _stamp() {
    final now = DateTime.now().millisecondsSinceEpoch;
    return _clock = now > _clock ? now : _clock + 1;
  }

  Map<String, Object> exportOrganization() => {
    'version': 1,
    'groups': {
      for (final e in _groups.entries)
        e.key: Map<String, dynamic>.from(e.value),
    },
    'assignments': {
      for (final e in _assignments.entries)
        '${e.key}': Map<String, dynamic>.from(e.value),
    },
  };

  static Map<String, dynamic> validateOrganization(Object? input) {
    if (input is! Map ||
        input['version'] != 1 ||
        input['groups'] is! Map ||
        input['assignments'] is! Map ||
        input['groups'].length > 1000 ||
        input['assignments'].length > 10000) {
      throw const FormatException('同步分类数据格式有误');
    }
    final result = <String, dynamic>{
      'version': 1,
      'groups': <String, dynamic>{},
      'assignments': <String, dynamic>{},
    };
    for (final e in (input['groups'] as Map).entries) {
      final v = e.value;
      if (e.key is! String ||
          e.key.length > 80 ||
          e.key.startsWith('_') ||
          v is! Map ||
          v['name'] is! String ||
          (v['name'] as String).trim().isEmpty ||
          v['name'].length > 30 ||
          v['at'] is! int ||
          v['at'] < 0 ||
          (v['deleted'] != null && v['deleted'] is! bool)) {
        throw const FormatException('同步分类数据格式有误');
      }
      result['groups'][e.key] = {
        'name': v['name'].trim(),
        'at': v['at'],
        'deleted': v['deleted'] == true,
      };
    }
    for (final e in (input['assignments'] as Map).entries) {
      final id = e.key is String ? int.tryParse(e.key) : null, v = e.value;
      if (id == null ||
          id > 0x7fffffff ||
          id <= 0 ||
          v is! Map ||
          v['group'] is! String ||
          v['group'].length > 80 ||
          v['at'] is! int ||
          v['at'] < 0) {
        throw const FormatException('同步书籍分类格式有误');
      }
      result['assignments']['$id'] = {'group': v['group'], 'at': v['at']};
    }
    return result;
  }

  void _accept(Object? raw) {
    final valid = validateOrganization(raw);
    void accept<K>(
      Map<K, Map<String, dynamic>> target,
      K key,
      Map<String, dynamic> incoming,
    ) {
      final previous = target[key];
      if (previous == null ||
          (incoming['at'] as int) > (previous['at'] as int) ||
          (incoming['at'] == previous['at'] &&
              jsonEncode(incoming).compareTo(jsonEncode(previous)) > 0)) {
        target[key] = incoming;
      }
      if (incoming['at'] > _clock) _clock = incoming['at'];
    }

    for (final e in (valid['groups'] as Map<String, dynamic>).entries) {
      accept(_groups, e.key, Map<String, dynamic>.from(e.value));
    }
    for (final e in (valid['assignments'] as Map<String, dynamic>).entries) {
      accept(
        _assignments,
        int.parse(e.key),
        Map<String, dynamic>.from(e.value),
      );
    }
  }

  Future<void> mergeOrganization(Object? raw) async {
    _accept(raw);
    if (selected != all &&
        selected != unfiled &&
        !groups.containsKey(selected)) {
      selected = all;
    }
    if (shelfSelected != all &&
        shelfSelected != unfiled &&
        !groups.containsKey(shelfSelected)) {
      shelfSelected = all;
    }
    await _save();
  }

  Future<void> _save() {
    final text = jsonEncode({
      'version': 1,
      'view': view.name,
      'sort': sort.name,
      'readingFilter': readingFilter,
      'selected': selected,
      'shelfSelected': shelfSelected,
      'organization': exportOrganization(),
    });
    final work = _writes.catchError((Object _) {}).then((_) async {
      if (!await preferences.setString(key, text)) {
        throw const FormatException('本地分类保存失败');
      }
    });
    _writes = work;
    if (!_disposed) notifyListeners();
    return work;
  }

  Future<void> setView(LocalLibraryView value) {
    view = value;
    return _save();
  }

  Future<void> setSort(LocalLibrarySort value) {
    sort = value;
    return _save();
  }

  Future<void> setReadingFilter(String value) {
    if (!['all', 'unread', 'reading', 'finished'].contains(value)) {
      throw const FormatException('阅读状态无效');
    }
    readingFilter = value;
    return _save();
  }

  Future<void> select(String value, {bool shelf = false}) {
    if (value != all && value != unfiled && !groups.containsKey(value)) {
      throw const FormatException('分类不存在');
    }
    if (shelf) {
      shelfSelected = value;
    } else {
      selected = value;
    }
    return _save();
  }

  Future<String> addGroup(String name) async {
    name = name.trim();
    if (name.isEmpty || name.length > 30) {
      throw const FormatException('分类名称需要 1～30 个字');
    }
    if (groups.values.contains(name)) throw const FormatException('已有同名分类');
    if (groups.length >= 100 || _groups.length >= 1000) {
      throw const FormatException('分类记录已满，请合并现有分类');
    }
    final random = Random.secure();
    final at = _stamp(),
        id =
            'g${_clock.toRadixString(36)}-${random.nextInt(0x100000000).toRadixString(36)}${random.nextInt(0x100000000).toRadixString(36)}';
    _groups[id] = {'name': name, 'at': at, 'deleted': false};
    await _save();
    return id;
  }

  Future<void> renameGroup(String id, String name) {
    name = name.trim();
    if (!groups.containsKey(id) || name.isEmpty || name.length > 30) {
      throw const FormatException('分类名称需要 1～30 个字');
    }
    if (groups.entries.any((e) => e.key != id && e.value == name)) {
      throw const FormatException('已有同名分类');
    }
    _groups[id] = {'name': name, 'at': _stamp(), 'deleted': false};
    return _save();
  }

  Future<void> removeGroup(String id) {
    if (!groups.containsKey(id)) return Future.value();
    _groups[id] = {..._groups[id]!, 'at': _stamp(), 'deleted': true};
    if (selected == id) selected = all;
    if (shelfSelected == id) shelfSelected = all;
    return _save();
  }

  Future<void> assign(int book, String group) {
    if (book <= 0 ||
        book > 0x7fffffff ||
        (group != unfiled && !groups.containsKey(group))) {
      throw const FormatException('请选择有效分类');
    }
    _assignments[book] = {'group': group, 'at': _stamp()};
    return _save();
  }

  List<Novel> filter(
    Iterable<Novel> books, {
    String query = '',
    int Function(int)? readAt,
    int Function(int)? addedAt,
  }) {
    final pattern = BookSearch(query);
    final result = books
        .where(
          (book) =>
              (selected == all || groupOf(book.id) == selected) &&
              pattern.matches(
                title: book.title,
                author: book.author,
                tags: book.genre,
                id: '${book.id}',
                classification: nameOf(groupOf(book.id)),
              ),
        )
        .toList();
    result.sort((a, b) {
      final order = switch (sort) {
        LocalLibrarySort.title => a.title.compareTo(b.title),
        LocalLibrarySort.recentRead => (readAt?.call(b.id) ?? 0).compareTo(
          readAt?.call(a.id) ?? 0,
        ),
        LocalLibrarySort.recentAdded => (addedAt?.call(b.id) ?? 0).compareTo(
          addedAt?.call(a.id) ?? 0,
        ),
      };
      return order != 0 ? order : a.title.compareTo(b.title);
    });
    return result;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
