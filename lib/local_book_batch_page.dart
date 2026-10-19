import 'package:flutter/cupertino.dart';

import 'app_interactions.dart';
import 'app_search_field.dart';
import 'app_ui.dart';
import 'book_collection_layout.dart';
import 'catalog.dart';
import 'feature_pages.dart';
import 'library_state.dart';
import 'local_book_removal.dart';
import 'local_books.dart';

Future<void> openLocalBookBatch(
  BuildContext context, {
  required LocalBookStore books,
  required LibraryState library,
  Set<int> selected = const {},
}) => pushNovelPage<void>(
  context,
  LocalBookBatchPage(books: books, library: library, selected: selected),
  reduceMotion: library.reduceMotion,
);

class LocalBookBatchPage extends StatefulWidget {
  const LocalBookBatchPage({
    super.key,
    required this.books,
    required this.library,
    this.selected = const {},
  });
  final LocalBookStore books;
  final LibraryState library;
  final Set<int> selected;
  @override
  State<LocalBookBatchPage> createState() => _LocalBookBatchPageState();
}

class _LocalBookBatchPageState extends State<LocalBookBatchPage> {
  final _query = TextEditingController();
  late final _selected = {...widget.selected};
  bool _busy = false;
  (int, int)? _progress;
  String? _error;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  void _toggle(int id) => setState(() {
    _selected.contains(id) ? _selected.remove(id) : _selected.add(id);
  });

  Future<void> _remove(Set<int> ids) async {
    if (_busy || ids.isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await chooseLocalBooksRemoval(
        context,
        ids: ids,
        books: widget.books,
        library: widget.library,
        onProgress: (done, total) {
          if (mounted) setState(() => _progress = (done, total));
        },
      );
      if (!mounted || result == null) return;
      setState(() {
        _selected.removeAll(result.removed);
        if (result.failed.isNotEmpty) {
          _error = '${result.failed.length} 本未能完成，已保留选择，请重试。';
        }
      });
      if (result.removed.isNotEmpty) {
        showNovelFeedback(
          context,
          result.choice == LocalBookRemoval.shelfOnly
              ? '已移出 ${result.removed.length} 本书'
              : '已删除 ${result.removed.length} 本书的本机文件',
        );
      }
    } catch (_) {
      if (mounted) setState(() => _error = '移除未完成，书籍选择已保留，请重试。');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([
      widget.books,
      widget.library.shelfViewChanges,
    ]),
    builder: (context, _) {
      final all = widget.books.books
          .where((book) => widget.library.localBookVisible(book.id))
          .toList(growable: false);
      final term = _query.text.trim().toLowerCase();
      final visible = all
          .where(
            (book) =>
                '${book.title}\n${book.author}'.toLowerCase().contains(term),
          )
          .toList();
      final selected = _selected.intersection(all.map((b) => b.id).toSet());
      final allSelected =
          visible.isNotEmpty &&
          visible.every((book) => selected.contains(book.id));
      return PopScope(
        canPop: !_busy,
        child: ArchiveFeaturePage(
          title: '批量整理',
          code: 'LOCAL / ORGANIZE',
          canPop: !_busy,
          actions: [
            GlassTextButton(
              key: const ValueKey('local-batch-all'),
              compact: true,
              onPressed: _busy || visible.isEmpty
                  ? null
                  : () => setState(() {
                      final ids = visible.map((book) => book.id);
                      allSelected
                          ? _selected.removeAll(ids)
                          : _selected.addAll(ids);
                    }),
              child: AppText(allSelected ? '取消全选' : '全选'),
            ),
          ],
          child: Column(
            children: [
              Expanded(
                child: CustomScrollView(
                  slivers: [
                    SliverPadding(
                      padding: featurePadding(context).copyWith(bottom: 12),
                      sliver: SliverToBoxAdapter(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            AppSearchField(
                              inputKey: const ValueKey('local-batch-search'),
                              controller: _query,
                              hint: '搜索本地书名、作者',
                              onChanged: (_) => setState(() {}),
                            ),
                            const SizedBox(height: 12),
                            Row(
                              children: [
                                Expanded(
                                  child: AppText(
                                    '${visible.length} 本 · 已选 ${selected.length} 本',
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                ),
                                if (selected.isNotEmpty)
                                  GlassTextButton(
                                    compact: true,
                                    onPressed: _busy
                                        ? null
                                        : () => setState(_selected.clear),
                                    child: const AppText('清空选择'),
                                  ),
                              ],
                            ),
                            FeatureError(_error),
                            if (visible.isEmpty)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 28,
                                ),
                                child: AppText(
                                  all.isEmpty ? '没有可整理的本地书籍。' : '没有符合关键词的书籍。',
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    SliverPadding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      sliver: BookCollectionSliver(
                        itemCount: visible.length,
                        itemBuilder: (context, index) {
                          final book = visible[index],
                              chosen = selected.contains(book.id);
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: Semantics(
                              selected: chosen,
                              child: ContentPanel(
                                key: ValueKey('local-batch-book-${book.id}'),
                                onTap: _busy ? null : () => _toggle(book.id),
                                child: Row(
                                  children: [
                                    NovelCover(book, width: 40, height: 56),
                                    const SizedBox(width: 12),
                                    Expanded(child: _BookLabel(book)),
                                    const SizedBox(width: 8),
                                    Icon(
                                      chosen
                                          ? CupertinoIcons.checkmark_circle_fill
                                          : CupertinoIcons.circle,
                                      size: 23,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
                  child: SizedBox(
                    width: double.infinity,
                    child: GlassPillButton(
                      key: const ValueKey('local-batch-remove'),
                      icon: CupertinoIcons.trash,
                      label: switch (_progress) {
                        (final done, final total) => '正在处理 $done/$total',
                        null =>
                          selected.isEmpty
                              ? '请选择书籍'
                              : '移除 ${selected.length} 本书',
                      },
                      onPressed: _busy || selected.isEmpty
                          ? null
                          : () => _remove(selected),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

class _BookLabel extends StatelessWidget {
  const _BookLabel(this.book);
  final Novel book;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      AppText(
        book.title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          height: 1.5,
        ),
      ),
      if (book.author.isNotEmpty) ...[
        const SizedBox(height: 4),
        AppText(
          book.author,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12),
        ),
      ],
    ],
  );
}
