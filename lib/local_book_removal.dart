import 'package:flutter/cupertino.dart';

import 'app_interactions.dart';
import 'app_ui.dart';
import 'catalog.dart';
import 'feature_pages.dart';
import 'library_state.dart';
import 'listening/widgets.dart';
import 'local_books.dart';
import 'local_series_actions.dart';

enum LocalBookRemoval { shelfOnly, files }

Future<LocalBookRemoval?> _chooseRemoval(
  BuildContext context, {
  required String title,
  required LibraryState library,
}) => showJellySheet<LocalBookRemoval>(
  context: context,
  reduceMotion: library.reduceMotion,
  builder: (sheet) => SingleChildScrollView(
    padding: const EdgeInsets.fromLTRB(24, 8, 24, 28),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        ArchiveSection(title: title, code: 'LOCAL / LIBRARY'),
        const SizedBox(height: 20),
        FeatureEntry(
          key: const ValueKey('local-remove-shelf-only'),
          title: '仅移出书架',
          subtitle: '保留本机文件、进度与书签，可在数据与存储中恢复',
          icon: CupertinoIcons.book,
          onTap: () => Navigator.pop(sheet, LocalBookRemoval.shelfOnly),
        ),
        const SizedBox(height: 14),
        FeatureEntry(
          key: const ValueKey('local-remove-files'),
          title: '同时删除本机文件',
          subtitle: '删除 App 内的书籍副本；下载目录与网盘原文件保留',
          icon: CupertinoIcons.trash,
          onTap: () => Navigator.pop(sheet, LocalBookRemoval.files),
        ),
      ],
    ),
  ),
);

Future<LocalBookRemoval?> chooseLocalBookRemoval(
  BuildContext context, {
  required Novel book,
  required LocalBookStore books,
  required LibraryState library,
}) async {
  final choice = await _chooseRemoval(
    context,
    title: '移除《${book.title}》',
    library: library,
  );
  if (!context.mounted || choice == null) return null;
  if (choice == LocalBookRemoval.shelfOnly) {
    await library.setLocalBookHidden(book.id, true);
    return choice;
  }
  final series = books.seriesFor(book.id);
  if (!await confirmNovelAction(
    context,
    title: series?.id == book.id ? '删除整部书的本机文件？' : '删除本机文件？',
    message:
        '《${book.title}》${series?.id == book.id ? '的 ${series!.volumes.length} 卷' : ''}将移出书架，并删除 App 内的原书、正文与插图。阅读进度和书签保留。',
    confirmLabel: '删除本机文件',
    reduceMotion: library.reduceMotion,
  )) {
    return null;
  }
  if (!context.mounted) return null;
  final listening = ListeningScope.maybeOf(context);
  final activeId = listening?.snapshot.value.novel?.id;
  if (activeId == book.id ||
      series?.volumes.any((v) => v.bookId == activeId) == true) {
    await listening!.stop();
  }
  await removeLocalBook(books: books, library: library, id: book.id);
  return choice;
}

typedef LocalBooksRemovalResult = ({
  LocalBookRemoval choice,
  Set<int> removed,
  Set<int> failed,
});

/// One preference commit for shelf-only removal; bounded sequential file I/O
/// for deletion. A failed book remains selected and does not block the others.
Future<LocalBooksRemovalResult> removeLocalBooks({
  required Iterable<int> ids,
  required LocalBookRemoval choice,
  required LocalBookStore books,
  required LibraryState library,
  void Function(int completed, int total)? onProgress,
}) async {
  final selected = ids.where(isLocalBook).where(books.contains).toSet();
  final targets = selected
      .where((id) {
        final owner = books.seriesFor(id);
        return owner == null || owner.id == id || !selected.contains(owner.id);
      })
      .toList(growable: false);
  final removed = <int>{}, failed = <int>{};
  if (choice == LocalBookRemoval.shelfOnly) {
    try {
      await library.setLocalBooksHidden(targets, true);
      removed.addAll(targets);
    } catch (_) {
      failed.addAll(targets);
    }
    onProgress?.call(targets.length, targets.length);
  } else {
    for (final (index, id) in targets.indexed) {
      try {
        await removeLocalBook(books: books, library: library, id: id);
        removed.add(id);
      } catch (_) {
        failed.add(id);
      }
      onProgress?.call(index + 1, targets.length);
    }
  }
  return (choice: choice, removed: removed, failed: failed);
}

Future<LocalBooksRemovalResult?> chooseLocalBooksRemoval(
  BuildContext context, {
  required Iterable<int> ids,
  required LocalBookStore books,
  required LibraryState library,
  void Function(int completed, int total)? onProgress,
}) async {
  final targets = ids.where(isLocalBook).where(books.contains).toSet();
  if (targets.isEmpty) return null;
  final choice = await _chooseRemoval(
    context,
    title: '移除 ${targets.length} 本本地书',
    library: library,
  );
  if (!context.mounted || choice == null) return null;
  if (choice == LocalBookRemoval.files) {
    if (!await confirmNovelAction(
      context,
      title: '删除 ${targets.length} 本书的本机文件？',
      message: '合订本包含的所有分卷也会删除。仅删除 App 内的原书、正文与插图；下载目录和网盘原文件、阅读进度与书签保留。',
      confirmLabel: '删除本机文件',
      reduceMotion: library.reduceMotion,
    )) {
      return null;
    }
    if (!context.mounted) return null;
    final listening = ListeningScope.maybeOf(context);
    final activeId = listening?.snapshot.value.novel?.id;
    if (activeId != null &&
        targets.any(
          (id) =>
              id == activeId ||
              books.seriesFor(id)?.volumes.any((v) => v.bookId == activeId) ==
                  true,
        )) {
      await listening!.stop();
    }
  }
  return removeLocalBooks(
    ids: targets,
    choice: choice,
    books: books,
    library: library,
    onProgress: onProgress,
  );
}

class RemovedLocalBooksPage extends StatelessWidget {
  const RemovedLocalBooksPage({
    super.key,
    required this.books,
    required this.library,
  });
  final LocalBookStore books;
  final LibraryState library;
  @override
  Widget build(BuildContext context) => ArchiveFeaturePage(
    title: '已移出的本地书',
    code: 'LOCAL / RECOVERY',
    child: AnimatedBuilder(
      animation: Listenable.merge([books, library.shelfViewChanges]),
      builder: (context, _) {
        final hidden = books.books
            .where((book) => !library.localBookVisible(book.id))
            .toList();
        return Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ListView.builder(
              padding: featurePadding(context),
              itemCount: hidden.isEmpty ? 1 : hidden.length,
              itemBuilder: (context, index) {
                if (hidden.isEmpty) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 32),
                    child: AppText('没有已移出的本地书。'),
                  );
                }
                final book = hidden[index];
                return Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: ContentPanel(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        AppText(
                          book.title,
                          style: const TextStyle(fontSize: 18, height: 1.65),
                        ),
                        if (book.author.isNotEmpty) AppText(book.author),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 10,
                          runSpacing: 6,
                          children: [
                            GlassTextButton(
                              key: ValueKey('local-restore-${book.id}'),
                              onPressed: () async {
                                try {
                                  await library.setLocalBookHidden(
                                    book.id,
                                    false,
                                  );
                                } catch (_) {
                                  if (context.mounted) {
                                    showNovelFeedback(context, '恢复失败，请重试');
                                  }
                                }
                              },
                              child: const AppText('恢复到书架'),
                            ),
                            GlassTextButton(
                              onPressed: () async {
                                try {
                                  await chooseLocalBookRemoval(
                                    context,
                                    book: book,
                                    books: books,
                                    library: library,
                                  );
                                } catch (_) {
                                  if (context.mounted) {
                                    showNovelFeedback(context, '移除未完成，请重试');
                                  }
                                }
                              },
                              child: const AppText('移除选项'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        );
      },
    ),
  );
}
