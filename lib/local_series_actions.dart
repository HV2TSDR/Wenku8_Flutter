import 'catalog.dart';
import 'library_state.dart';
import 'local_books.dart';
import 'local_book_series.dart';

Future<void> reconcileLocalSeries(
  LocalBookStore books,
  LibraryState library,
) async {
  for (final series in books.seriesDefinitions.where((s) => s.deleted)) {
    if (books.seriesSnapshot(series.id) != null &&
        (library.contains(series.id) ||
            library.hasRead(series.id) ||
            library.bookmarksFor(series.id).isNotEmpty)) {
      await _restoreVolumeRecords(books, library, series, reveal: false);
    }
  }
  for (final series in books.series) {
    final target = books.book(series.id)!;
    await library.combineBookRecords(
      target: target,
      sources: {
        for (final volume in series.volumes)
          books.book(volume.bookId)!: {
            for (final (i, chapter)
                in books.book(volume.bookId)!.chapters.indexed)
              chapter.id: volume.chapterIds[i],
          },
      },
      onShelf: false,
    );
  }
}

Future<Novel> saveLocalSeries({
  required LocalBookStore books,
  required LibraryState library,
  int? id,
  required String title,
  required List<({int bookId, String title})> volumes,
}) async {
  final book = await books.saveSeries(id: id, title: title, volumes: volumes);
  await reconcileLocalSeries(books, library);
  return book;
}

Future<void> dissolveLocalSeries({
  required LocalBookStore books,
  required LibraryState library,
  required LocalBookSeries series,
}) async {
  await _restoreVolumeRecords(books, library, series, reveal: true);
  await books.dissolveSeries(series.id);
}

Future<void> removeLocalBook({
  required LocalBookStore books,
  required LibraryState library,
  required int id,
}) async {
  final series = books.seriesFor(id);
  if (series != null && series.id == id) {
    // Keep a per-original resume record as well. Re-importing just one EPUB
    // must not require all other volumes before its latest position returns.
    await _restoreVolumeRecords(books, library, series, reveal: false);
  }
  await books.remove(id);
  for (final removed in [id, ...?series?.volumes.map((v) => v.bookId)]) {
    await library.setShelfMembership(removed, false);
    await library.setLocalBookHidden(removed, false);
  }
}

Future<void> _restoreVolumeRecords(
  LocalBookStore books,
  LibraryState library,
  LocalBookSeries series, {
  required bool reveal,
}) async {
  final combined = books.seriesSnapshot(series.id);
  if (combined == null) throw const FormatException('合订本已不存在');
  // Copy newer records back before exposing the independent originals. If a
  // preference write fails, the intact series remains available for retry.
  for (final volume in series.volumes) {
    final original = books.book(volume.bookId)!;
    await library.combineBookRecords(
      target: original,
      sources: {
        combined: {
          for (final (i, chapter) in original.chapters.indexed)
            volume.chapterIds[i]: chapter.id,
        },
      },
      onShelf: false,
      revealTarget: reveal,
    );
  }
}
