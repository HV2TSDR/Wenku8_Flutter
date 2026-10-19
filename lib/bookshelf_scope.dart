import 'library_state.dart';
import 'offline_repository.dart';
import 'local_library_preferences.dart';

/// Membership is a view, never a write to cloud favorites or local originals.
Set<int> bookshelfIds(
  LibraryState state,
  OfflineNovelRepository? offline, {
  bool readableOnly = false,
  bool filterSource = true,
  bool filterCategory = true,
}) =>
    {
          for (final id in state.shelf)
            if (!readableOnly || offline?.availableOffline(id) == true) id,
          if (state.combinedShelf && offline != null) ...[
            for (final book in offline.cache.books)
              if (book.cachedCount > 0) book.novel.id,
            ...?offline.local?.books.map((book) => book.id),
          ],
        }
        .where(
          (id) =>
              state.localBookVisible(id) &&
              (!filterSource || bookshelfMatchesSource(id, state, offline)) &&
              (!filterCategory || bookshelfMatchesCategory(id, state)),
        )
        .toSet();

bool bookshelfMatchesCategory(int id, LibraryState state) =>
    state.organization.shelfSelected == LocalLibraryPreferences.all ||
    state.organization.groupOf(id) == state.organization.shelfSelected;

bool bookshelfMatchesSource(
  int id,
  LibraryState state,
  OfflineNovelRepository? offline,
) {
  if (!state.combinedShelf) return true;
  final local = offline?.local?.book(id) != null;
  return switch (state.shelfSourceFilter) {
    'local' => local,
    'cached' => !local && offline?.availableOffline(id) == true,
    'online' => !local && state.contains(id),
    _ => true,
  };
}

String bookshelfSourceLabel(String source) => switch (source) {
  'local' => '本地导入',
  'cached' => '已缓存',
  'online' => '在线收藏',
  _ => '全部来源',
};

String bookshelfSource(int id, OfflineNovelRepository? offline) {
  if (offline?.local?.book(id) != null) return '本地';
  return offline?.availableOffline(id) == true ? '缓存' : '在线';
}
