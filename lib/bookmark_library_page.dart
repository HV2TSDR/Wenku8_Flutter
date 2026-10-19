import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'app_interactions.dart';
import 'app_ui.dart';
import 'app_search_field.dart';
import 'catalog.dart';
import 'feature_pages.dart';
import 'library_state.dart';
import 'local_books.dart';
import 'offline_repository.dart';
import 'pages.dart' show ReaderPage;
import 'quote_card.dart';

/// A merged volume keeps its original recovery records. Show the equivalent
/// bookmark in the active series once, without deleting those recovery copies.
List<({int novelId, ReaderBookmark bookmark})> libraryBookmarks(
  LibraryState state, {
  LocalBookStore? books,
}) => state.bookmarkEntries.where((entry) {
  final series = books?.seriesFor(entry.novelId);
  if (series == null || series.id == entry.novelId) return true;
  final original =
      books!.book(entry.novelId) ?? state.cachedNovel(entry.novelId);
  if (original == null) return true;
  final chapter = state.chapterForPosition(original, entry.bookmark.position);
  final volume = series.volumes
      .where((v) => v.bookId == entry.novelId)
      .firstOrNull;
  if (chapter == null ||
      volume == null ||
      chapter >= volume.chapterIds.length) {
    return true;
  }
  final source = entry.bookmark.position;
  return !state.bookmarksFor(series.id).any((mark) {
    final target = mark.position;
    return target.chapterId == volume.chapterIds[chapter] &&
        mark.quote == entry.bookmark.quote &&
        target.paragraphIndex == source.paragraphIndex &&
        target.textOffset == source.textOffset &&
        target.offset == source.offset &&
        target.width == source.width &&
        target.fontSize == source.fontSize &&
        target.lineHeight == source.lineHeight;
  });
}).toList();

class BookmarkLibraryPage extends StatefulWidget {
  const BookmarkLibraryPage({
    super.key,
    required this.state,
    required this.repository,
  });
  final LibraryState state;
  final NovelRepository repository;
  @override
  State<BookmarkLibraryPage> createState() => _BookmarkLibraryPageState();
}

class _BookmarkLibraryPageState extends State<BookmarkLibraryPage> {
  String _query = '';
  String? _opening;

  Novel? _known(int id) => widget.repository is OfflineNovelRepository
      ? (widget.repository as OfflineNovelRepository).local?.book(id) ??
            (widget.repository as OfflineNovelRepository).cache
                .book(id)
                ?.novel ??
            widget.state.cachedNovel(id)
      : widget.state.cachedNovel(id);

  Future<void> _open(int id, ReaderBookmark mark) async {
    if (_opening != null) return;
    setState(() => _opening = mark.id);
    try {
      final repository = widget.repository;
      if (isLocalBook(id) &&
          repository is OfflineNovelRepository &&
          repository.local?.book(id) == null) {
        throw const FormatException('本地原书已移除，摘录仍可查看和分享');
      }
      var novel = _known(id) ?? await repository.find(id);
      if (novel == null) throw const FormatException('暂时无法读取原书，请检查本机文件或网络');
      if (novel.chapters.isEmpty) {
        novel = novel.withChapters(await repository.chapters(novel.id));
      }
      final chapter = widget.state.chapterForPosition(novel, mark.position);
      if (chapter == null) throw const FormatException('原章节已变动，摘录仍保留');
      if (!mounted) return;
      await pushNovelPage<void>(
        context,
        ReaderPage(
          novel: novel,
          state: widget.state,
          repository: repository,
          initialChapter: chapter,
          initialBookmark: mark,
        ),
        reduceMotion: widget.state.reduceMotion,
      );
    } catch (error) {
      if (mounted) {
        showNovelFeedback(
          context,
          error is FormatException ? error.message : '暂时无法打开原文，请重试',
        );
      }
    } finally {
      if (mounted) setState(() => _opening = null);
    }
  }

  Future<void> _remove(int id, ReaderBookmark mark) async {
    if (!await confirmNovelAction(
      context,
      title: '删除这条书签？',
      message: '原书和阅读进度不会改变。',
      confirmLabel: '删除书签',
      reduceMotion: widget.state.reduceMotion,
    )) {
      return;
    }
    try {
      await widget.state.removeBookmark(id, mark.id);
    } catch (_) {
      if (mounted) showNovelFeedback(context, '书签删除失败，请重试');
    }
  }

  @override
  Widget build(BuildContext context) => ArchiveFeaturePage(
    title: '书签',
    code: 'PERSONAL / EXCERPTS',
    child: AnimatedBuilder(
      animation: widget.state.bookmarkChanges,
      builder: (context, _) {
        final query = _query.trim().toLowerCase();
        final local = widget.repository is OfflineNovelRepository
            ? (widget.repository as OfflineNovelRepository).local
            : null;
        final entries = libraryBookmarks(widget.state, books: local).where((
          entry,
        ) {
          final book = _known(entry.novelId);
          return query.isEmpty ||
              '${entry.bookmark.quote}\n${entry.bookmark.chapterTitle}\n${book?.title ?? ''}\n${book?.author ?? ''}'
                  .toLowerCase()
                  .contains(query);
        }).toList();
        return Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ListView.builder(
              padding: featurePadding(context),
              itemCount: entries.length + 1,
              itemBuilder: (context, index) {
                if (index == 0) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      AppSearchField(
                        inputKey: const ValueKey('bookmark-search'),
                        hint: '搜索摘录、书名或作者',
                        onChanged: (value) => setState(() => _query = value),
                      ),
                      const SizedBox(height: 18),
                      AppText(
                        '${entries.length} 条书签',
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 16),
                      if (entries.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 36),
                          child: AppText(
                            query.isEmpty
                                ? '长按正文选择喜欢的句子，点「书签」即可收藏。\n已有的位置书签也会显示在这里。'
                                : '没有找到匹配的书签',
                            style: const TextStyle(height: 1.8),
                          ),
                        ),
                    ],
                  );
                }
                final entry = entries[index - 1], mark = entry.bookmark;
                final novel = _known(entry.novelId);
                return Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: ContentPanel(
                    key: ValueKey('my-bookmark-${mark.id}'),
                    onTap: () => _open(entry.novelId, mark),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (mark.quote.isNotEmpty) ...[
                          AppText(
                            mark.quote,
                            maxLines: 5,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontFamily: 'SourceHanSerifCN',
                              fontSize: 15,
                              height: 1.75,
                            ),
                          ),
                          const SizedBox(height: 20),
                        ],
                        AppText(
                          novel?.title ?? '书籍 ${entry.novelId}',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 6),
                        AppText(
                          mark.chapterTitle,
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.6,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 6,
                          children: [
                            GlassTextButton(
                              key: ValueKey('bookmark-read-${mark.id}'),
                              onPressed: _opening == null
                                  ? () => _open(entry.novelId, mark)
                                  : null,
                              child: AppText(
                                _opening == mark.id ? '正在打开…' : '回到原文',
                              ),
                            ),
                            if (mark.quote.isNotEmpty)
                              GlassTextButton(
                                key: ValueKey('bookmark-share-${mark.id}'),
                                onPressed: () => pushNovelPage<void>(
                                  context,
                                  QuoteCardPage(
                                    data: QuoteCardData(
                                      text: mark.quote,
                                      book:
                                          novel?.title ?? '书籍 ${entry.novelId}',
                                      author: novel?.author ?? '',
                                      chapter: mark.chapterTitle,
                                    ),
                                  ),
                                  reduceMotion: widget.state.reduceMotion,
                                ),
                                child: const AppText('分享图片'),
                              ),
                            GlassIconButton(
                              icon: CupertinoIcons.trash,
                              label: '删除书签 ${mark.id}',
                              onPressed: () => _remove(entry.novelId, mark),
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
