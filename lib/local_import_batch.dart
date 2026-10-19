import 'book_documents.dart';
import 'catalog.dart';
import 'cloud_sources.dart' show cloudFailureMessage;
import 'local_books.dart';
import 'local_book_series.dart';

typedef LocalImportFailure = ({String name, String message});

class LocalImportReport {
  const LocalImportReport({
    required this.bookIds,
    required this.added,
    required this.existing,
    this.failures = const [],
  });
  final List<int> bookIds;
  final int added, existing;
  final List<LocalImportFailure> failures;
  String get summary => [
    if (added > 0) '已导入 $added 本',
    if (existing > 0) '$existing 本已在书库',
    if (failures.isNotEmpty) '${failures.length} 本未导入',
  ].join(' · ');
}

/// Read/parse one source at a time. A bad document must not discard the rest
/// of a user-selected batch, and no merge prompt interrupts this operation.
Future<LocalImportReport> importLocalBatch({
  required List<BookDocumentSelection> selections,
  required LocalBookStore books,
  required Future<Novel> Function(String name, String path) importFile,
  void Function(int completed, int total)? onProgress,
}) async {
  final ids = <int>{};
  final failures = <LocalImportFailure>[];
  var added = 0, existing = 0;
  for (final (index, selected) in selections.indexed) {
    try {
      if (selected.error case final error?) throw FormatException(error);
      final before = books.originals.length;
      final book = await importFile(selected.name, selected.path!);
      ids.add(book.id);
      if (books.originals.length > before) {
        added++;
      } else {
        existing++;
      }
    } catch (error) {
      failures.add((name: selected.name, message: cloudFailureMessage(error)));
    }
    onProgress?.call(index + 1, selections.length);
  }
  return LocalImportReport(
    bookIds: ids.toList(),
    added: added,
    existing: existing,
    failures: failures,
  );
}

class LocalImportGroup {
  const LocalImportGroup({
    required this.seed,
    required this.title,
    required this.volumes,
    this.targetId,
    this.needsTarget = false,
  });
  final int seed;
  final String title;
  final int? targetId;
  final bool needsTarget;
  final List<({int bookId, String title})> volumes;
}

/// Suggestions only. The caller presents all groups after the batch finishes;
/// durable originals and reading records are changed only on confirmation.
List<LocalImportGroup> localImportGroups(
  LocalBookStore books,
  Iterable<int> ids,
) {
  final groups = <LocalImportGroup>[];
  final claimed = <int>{};
  for (final id in ids) {
    if (claimed.contains(id) || books.seriesFor(id) != null) continue;
    final related = books.relatedVolumes(id);
    if (related.isEmpty) continue;
    final targets = related
        .map((b) => books.seriesFor(b.id))
        .whereType<LocalBookSeries>()
        .toList();
    final target = targets.firstOrNull;
    final order = <({int bookId, String title})>[
      ...?target?.volumes.map((v) => (bookId: v.bookId, title: v.title)),
    ];
    final originals =
        [
          books.book(id)!,
          ...related,
        ].where((b) => books.seriesFor(b.id) == null).toList()..sort(
          (a, b) => (books.seriesHint(a.id)?.number ?? double.infinity)
              .compareTo(books.seriesHint(b.id)?.number ?? double.infinity),
        );
    for (final book in originals) {
      claimed.add(book.id);
      final hint = books.seriesHint(book.id);
      final before = hint == null
          ? -1
          : order.indexWhere((v) {
              final other = books.seriesHint(v.bookId);
              return other?.key == hint.key && other!.number > hint.number;
            });
      final entry = (bookId: book.id, title: hint?.volumeTitle ?? book.title);
      if (before < 0) {
        order.add(entry);
      } else {
        order.insert(before, entry);
      }
    }
    groups.add(
      LocalImportGroup(
        seed: id,
        title: target?.title ?? books.seriesHint(id)!.title,
        volumes: order,
        targetId: target?.id,
        needsTarget: targets.length > 1,
      ),
    );
  }
  return groups;
}
