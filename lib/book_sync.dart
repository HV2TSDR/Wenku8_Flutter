import 'dart:convert';
import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'book_documents.dart';
import 'book_import_limits.dart';
import 'catalog.dart' show Novel;
import 'library_backup.dart';
import 'library_state.dart';
import 'local_books.dart';
import 'local_book_series.dart';
import 'local_series_actions.dart';
import 'local_library_preferences.dart';

class BookSyncBundle {
  const BookSyncBundle(
    this.backup,
    this.books, {
    this.organization,
    this.bookMetadata,
    this.series,
  });
  final String backup;
  final List<LocalBookInput> books;
  final Map<String, dynamic>? organization;
  final Map<String, dynamic>? bookMetadata;
  final Map<String, dynamic>? series;
}

Uint8List encodeBookSync(BookSyncBundle bundle) {
  final zip = Archive();
  final books = <Map<String, Object>>[];
  for (final (i, book) in bundle.books.indexed) {
    final path = 'books/$i/original';
    zip.addFile(ArchiveFile(path, book.bytes.length, book.bytes));
    books.add({
      'name': book.name,
      'path': path,
      if (book.text != null) 'text': 'books/$i/decoded.txt',
    });
    if (book.text case final text?) {
      final bytes = utf8.encode(text);
      zip.addFile(ArchiveFile('books/$i/decoded.txt', bytes.length, bytes));
    }
  }
  final metadata = utf8.encode(
    jsonEncode({
      'format': 'wenku8-book-sync',
      'version': 1,
      'books': books,
      if (bundle.organization != null)
        'organization': LocalLibraryPreferences.validateOrganization(
          bundle.organization,
        ),
      if (bundle.series != null)
        'series': encodeLocalSeries(decodeLocalSeries(bundle.series)),
    }),
  );
  final backup = utf8.encode(bundle.backup);
  if (metadata.length > LibraryBackup.maxBytes) {
    throw const FormatException('同步书目超过 4 MiB，请减少单次同步的书目与分卷');
  }
  zip.addFile(ArchiveFile('manifest.json', metadata.length, metadata));
  if (bundle.bookMetadata != null) {
    final edits = utf8.encode(
      jsonEncode(LocalBookStore.validateMetadata(bundle.bookMetadata)),
    );
    if (edits.length > LibraryBackup.maxBytes) {
      throw const FormatException('书籍信息超过同步大小限制');
    }
    zip.addFile(ArchiveFile('book-info.json', edits.length, edits));
  }
  zip.addFile(ArchiveFile('library.json', backup.length, backup));
  final bytes = ZipEncoder().encode(zip);
  if (bytes.length > 256 * 1024 * 1024) {
    throw const FormatException('同步文件超过 256 MB，请减少本地书籍后重试');
  }
  return Uint8List.fromList(bytes);
}

BookSyncBundle decodeBookSync(Uint8List bytes) {
  if (bytes.length > 256 * 1024 * 1024) throw const FormatException('同步文件过大');
  final zip = boundedZip(
    bytes,
    maxSize: 512 * 1024 * 1024,
    maxEntrySize: maxLocalEpubBytes,
  );
  final files = {
    for (final f in zip)
      if (f.isFile) f.name: f,
  };
  String text(String name, int max) {
    final file = files[name];
    if (file == null || file.size > max) throw const FormatException('同步文件不完整');
    return utf8.decode(file.readBytes()!);
  }

  final manifest = jsonDecode(text('manifest.json', LibraryBackup.maxBytes));
  if (manifest is! Map ||
      manifest['format'] != 'wenku8-book-sync' ||
      manifest['version'] != 1 ||
      manifest['books'] is! List ||
      manifest['books'].length > 200) {
    throw const FormatException('请选择文库生成的 .wenku8sync 同步文件');
  }
  final books = <LocalBookInput>[];
  final paths = <String>{};
  for (final value in manifest['books']) {
    if (value is! Map ||
        value['name'] is! String ||
        value['path'] is! String ||
        (value['name'] as String).length > 2048 ||
        !paths.add(value['path'])) {
      throw const FormatException('同步书籍信息有误');
    }
    final file = files[value['path']];
    if (file == null || file.size > localBookByteLimit(value['name'])) {
      throw const FormatException('同步原书不存在或过大');
    }
    books.add(
      LocalBookInput(
        value['name'],
        file.readBytes()!,
        text: value['text'] is String
            ? text(value['text'], maxLocalTextBytes)
            : null,
      ),
    );
  }
  return BookSyncBundle(
    text('library.json', LibraryBackup.maxBytes),
    books,
    organization: manifest['organization'] == null
        ? null
        : LocalLibraryPreferences.validateOrganization(
            manifest['organization'],
          ),
    bookMetadata: files.containsKey('book-info.json')
        ? LocalBookStore.validateMetadata(
            jsonDecode(text('book-info.json', LibraryBackup.maxBytes)),
          )
        : null,
    series: manifest['series'] == null
        ? null
        : encodeLocalSeries(decodeLocalSeries(manifest['series'])),
  );
}

/// One active transaction per sync document. Progress uses the existing
/// timestamp merge; device settings and TTS credentials stay on this device.
class BookSync extends ChangeNotifier {
  BookSync({
    required this.books,
    required this.state,
    required this.preferences,
    BookDocuments? documents,
    LocalLibraryPreferences? organization,
  }) : documents = documents ?? BookDocuments(),
       organization = organization ?? state.organization;
  final LocalBookStore books;
  final LibraryState state;
  final SharedPreferences preferences;
  final BookDocuments documents;
  final LocalLibraryPreferences organization;
  bool get syncOriginals => preferences.getBool('bookSyncOriginals') ?? true;
  bool get syncReading => preferences.getBool('bookSyncReading') ?? true;
  bool get syncCategories => preferences.getBool('bookSyncCategories') ?? true;
  String get preferredProvider =>
      preferences.getString('bookSyncProvider') ?? 'OneDrive';
  String get providerLabel {
    final authority = '${connection?['authority'] ?? ''}'.toLowerCase();
    if (authority.contains('microsoft') ||
        authority.contains('skydrive') ||
        authority.contains('onedrive')) {
      return 'OneDrive';
    }
    if (authority.contains('com.google.android')) return 'Google Drive';
    return connection?['provider'] as String? ?? '系统文档';
  }

  Future<void> configure({
    bool? originals,
    bool? reading,
    bool? categories,
    String? provider,
  }) async {
    if (busy) return;
    for (final entry in {
      'bookSyncOriginals': originals,
      'bookSyncReading': reading,
      'bookSyncCategories': categories,
    }.entries) {
      if (entry.value != null &&
          !await preferences.setBool(entry.key, entry.value!)) {
        throw const FormatException('同步设置保存失败');
      }
    }
    if (provider != null &&
        !await preferences.setString('bookSyncProvider', provider)) {
      throw const FormatException('同步设置保存失败');
    }
    _notify();
  }

  // The native document bridge has one selected URI and shared before/next
  // files. A page can be reopened while its previous transaction is finishing.
  static BookSync? _activeOperation;
  Map<String, dynamic>? connection;
  bool busy = false;
  String? error, status;
  bool _disposed = false;
  int? get lastSync => preferences.getInt('bookSyncAt');
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  bool _begin() {
    if (_disposed || busy) return false;
    if (_activeOperation != null) {
      error = null;
      status = '正在完成上一次云文档操作，请稍后重试';
      _notify();
      return false;
    }
    _activeOperation = this;
    busy = true;
    error = null;
    status = null;
    return true;
  }

  void _end() {
    if (identical(_activeOperation, this)) _activeOperation = null;
    busy = false;
    _notify();
  }

  Future<void> load() async {
    try {
      connection = await documents.info();
    } catch (failure) {
      error = _describe(failure);
    }
    _notify();
  }

  Future<void> connect({required bool create}) async {
    if (!_begin()) return;
    _notify();
    try {
      final value = await documents.connect(create: create);
      if (value != null) {
        connection = value;
        status = '已连接，点按立即同步开始合并';
      }
    } catch (failure) {
      error = _describe(failure);
    } finally {
      _end();
    }
  }

  Future<void> disconnect() async {
    if (!_begin()) return;
    _notify();
    try {
      await documents.disconnect();
      connection = null;
      status = null;
      error = null;
    } catch (failure) {
      error = _describe(failure);
    } finally {
      _end();
    }
  }

  Future<void> _merge(BookSyncBundle bundle) async {
    final backup = await LibraryBackup.parse(bundle.backup);
    // Each original commits atomically; no incoming positions become visible
    // until all referenced local books have been imported successfully.
    for (final input
        in syncOriginals ? bundle.books : const <LocalBookInput>[]) {
      await books.import(input);
    }
    if (syncOriginals && bundle.bookMetadata != null) {
      await books.mergeMetadata(bundle.bookMetadata);
      for (final id in bundle.bookMetadata!.keys.map(int.parse)) {
        if (books.book(id) case final book?) {
          await state.setShelfMembership(id, state.contains(id), novel: book);
        }
      }
    }
    if (syncOriginals && bundle.series != null) {
      for (final incoming in decodeLocalSeries(bundle.series)) {
        final current = books.seriesFor(incoming.id);
        if (incoming.deleted &&
            current != null &&
            incoming.updatedAt >= current.updatedAt) {
          await dissolveLocalSeries(
            books: books,
            library: state,
            series: current,
          );
        }
      }
      await books.mergeSeries(bundle.series);
    }
    if (syncReading) await state.restoreBackup(backup);
    if (syncOriginals) await reconcileLocalSeries(books, state);
    if (syncCategories && bundle.organization != null) {
      await organization.mergeOrganization(bundle.organization);
    }
  }

  Future<void> sync() async {
    if (connection == null || !_begin()) return;
    status = '正在读取云端';
    _notify();
    try {
      final files = await documents.read();
      final size = await files.before.length();
      BookSyncBundle? remote;
      if (size > 0) {
        final incoming = await compute<Uint8List, BookSyncBundle>(
          decodeBookSync,
          await files.before.readAsBytes(),
        );
        remote = incoming;
        await _merge(incoming);
      } else if (connection!['created'] != true) {
        throw const FormatException('所选文件为空，请新建文库同步文件');
      }
      status = '正在合并书籍与阅读记录';
      _notify();
      final backup = syncReading
          ? await state.createBackup()
          : remote != null
          ? await LibraryBackup.parse(remote.backup)
          : await LibraryBackup.fromRecords(const {});
      final originals = <LocalBookInput>[];
      var total = 0;
      if (!syncOriginals) originals.addAll(remote?.books ?? const []);
      for (final book in syncOriginals ? books.originals : const <Novel>[]) {
        final input = await books.original(book.id);
        total += input.bytes.length + (input.text?.length ?? 0) * 3;
        if (originals.length >= 200 || total > 512 * 1024 * 1024) {
          throw const FormatException('一次最多同步 200 本、512 MB 原书，请整理本地书库');
        }
        originals.add(input);
      }
      final bytes = await compute(
        encodeBookSync,
        BookSyncBundle(
          await backup.encode(),
          originals,
          organization: syncCategories
              ? organization.exportOrganization()
              : remote?.organization,
          bookMetadata: syncOriginals
              ? books.exportMetadata()
              : remote?.bookMetadata,
          series: syncOriginals ? books.exportSeries() : remote?.series,
        ),
      );
      await files.output.writeAsBytes(bytes, flush: true);
      status = '正在写入并确认云端';
      _notify();
      await documents.write(files.before, files.output);
      await preferences.setInt(
        'bookSyncAt',
        DateTime.now().millisecondsSinceEpoch,
      );
      connection = {...connection!, 'created': false};
      status = '同步完成 · ${books.books.length} 本本地书籍';
    } catch (failure) {
      error = _describe(failure);
      status = null;
    } finally {
      _end();
    }
  }

  Future<void> recover(String which) async {
    if (!_begin()) return;
    status = '正在恢复同步副本';
    _notify();
    try {
      final file = await documents.recovery(which);
      if (file == null || await file.length() == 0) {
        throw const FormatException('暂无可恢复的同步副本');
      }
      await _merge(await compute(decodeBookSync, await file.readAsBytes()));
      status = '已合并恢复副本到本机，可新建同步文件后重新上传';
    } catch (failure) {
      error = _describe(failure);
      status = null;
    } finally {
      _end();
    }
  }

  static String _describe(Object error) => error is FormatException
      ? error.message
      : error is PlatformException
      ? error.message ?? '云文档操作失败，请重新选择文件'
      : '同步未完成，本地书籍与阅读记录已保留，请重试';
  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
