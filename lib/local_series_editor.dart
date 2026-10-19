import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import 'app_ui.dart';
import 'app_search_field.dart';
import 'catalog.dart';
import 'feature_pages.dart' show confirmNovelAction;
import 'library_state.dart';
import 'local_books.dart';
import 'local_book_series.dart';
import 'local_series_actions.dart';
import 'listening/widgets.dart';

class LocalSeriesEditResult {
  const LocalSeriesEditResult({this.bookId, this.dissolved = false});
  final int? bookId;
  final bool dissolved;
}

class LocalSeriesEditor extends StatefulWidget {
  const LocalSeriesEditor({
    super.key,
    required this.book,
    required this.books,
    required this.library,
    this.suggested = false,
  });
  final Novel book;
  final LocalBookStore books;
  final LibraryState library;
  final bool suggested;
  @override
  State<LocalSeriesEditor> createState() => _LocalSeriesEditorState();
}

class _LocalSeriesEditorState extends State<LocalSeriesEditor> {
  final _title = TextEditingController();
  final _search = TextEditingController();
  final _labels = <int, TextEditingController>{};
  final _order = <int>[];
  final _fixed = <int>{};
  LocalBookSeries? _series;
  bool _busy = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    final current = widget.books.seriesFor(widget.book.id);
    final related = widget.books.relatedVolumes(widget.book.id);
    final suggested = widget.suggested
        ? related
              .map((b) => widget.books.seriesFor(b.id))
              .whereType<LocalBookSeries>()
              .firstOrNull
        : null;
    _configure(current ?? suggested, related: related);
  }

  TextEditingController _label(int id, [String? value]) => _labels.putIfAbsent(
    id,
    () => TextEditingController(
      text:
          value ??
          widget.books.seriesHint(id)?.volumeTitle ??
          widget.books.book(id)!.title,
    ),
  );

  void _configure(LocalBookSeries? series, {List<Novel> related = const []}) {
    _series = series;
    _order.clear();
    _fixed.clear();
    if (series != null) {
      for (final volume in series.volumes) {
        _order.add(volume.bookId);
        _fixed.add(volume.bookId);
        _label(volume.bookId, volume.title).text = volume.title;
      }
    }
    final initial = widget.books.originals
        .where((b) => b.id == widget.book.id)
        .firstOrNull;
    void add(int id) {
      if (_order.contains(id)) return;
      final hint = widget.books.seriesHint(id);
      final before = hint == null
          ? -1
          : _order.indexWhere((other) {
              final h = widget.books.seriesHint(other);
              return h?.key == hint.key && h!.number > hint.number;
            });
      if (before < 0) {
        _order.add(id);
      } else {
        _order.insert(before, id);
      }
    }

    if (initial != null) add(initial.id);
    for (final book in related) {
      if (widget.books.seriesFor(book.id) == null &&
          !_order.contains(book.id)) {
        add(book.id);
      }
    }
    if (series == null) {
      _order.sort(
        (a, b) => (widget.books.seriesHint(a)?.number ?? double.infinity)
            .compareTo(widget.books.seriesHint(b)?.number ?? double.infinity),
      );
    }
    for (final id in _order) {
      _label(id);
    }
    _title.text =
        series?.title ??
        widget.books.seriesHint(widget.book.id)?.title ??
        widget.book.title;
    _error = null;
  }

  @override
  void dispose() {
    _title.dispose();
    _search.dispose();
    for (final label in _labels.values) {
      label.dispose();
    }
    super.dispose();
  }

  Future<void> _chooseTarget() async {
    final selected = await showJellySheet<int>(
      context: context,
      reduceMotion: widget.library.reduceMotion,
      heightFactor: .68,
      builder: (sheet) => ListView(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
        children: [
          const ArchiveSection(title: '合并到', code: 'LOCAL / COLLECTION'),
          const SizedBox(height: 16),
          GlassTextButton(
            onPressed: () => Navigator.pop(sheet, 0),
            child: const AppText('新建合订本'),
          ),
          for (final series in widget.books.series)
            GlassTextButton(
              onPressed: () => Navigator.pop(sheet, series.id),
              child: AppText('${series.title} · ${series.volumes.length} 卷'),
            ),
        ],
      ),
    );
    if (!mounted || selected == null) return;
    setState(
      () => _configure(selected == 0 ? null : widget.books.seriesFor(selected)),
    );
  }

  Future<void> _stopReading() async {
    final listening = ListeningScope.maybeOf(context);
    final id = listening?.snapshot.value.novel?.id;
    if (id != null && (id == _series?.id || _order.contains(id))) {
      await listening!.stop();
    }
  }

  Future<void> _save() async {
    if (_busy) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _stopReading();
      final book = await saveLocalSeries(
        books: widget.books,
        library: widget.library,
        id: _series?.id,
        title: _title.text,
        volumes: [
          for (final id in _order) (bookId: id, title: _label(id).text),
        ],
      );
      final groups = widget.library.organization;
      if (_series == null && _order.isNotEmpty) {
        await groups.assign(book.id, groups.groupOf(_order.first));
      }
      if (mounted) {
        Navigator.pop(context, LocalSeriesEditResult(bookId: book.id));
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e is FormatException ? e.message : '分卷保存未完成，原书仍保留，请重试';
          _series ??= widget.books.seriesFor(widget.book.id);
          _fixed.addAll(_series?.volumes.map((v) => v.bookId) ?? const <int>[]);
        });
      }
    }
  }

  Future<void> _dissolve() async {
    final series = _series;
    if (_busy ||
        series == null ||
        !await confirmNovelAction(
          context,
          title: '恢复为独立书籍？',
          message: '各卷会重新显示在本地书库，阅读进度与书签按原章节保留。',
          confirmLabel: '恢复独立书籍',
          reduceMotion: widget.library.reduceMotion,
        )) {
      return;
    }
    if (!mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _stopReading();
      await dissolveLocalSeries(
        books: widget.books,
        library: widget.library,
        series: series,
      );
      if (mounted) {
        Navigator.pop(context, const LocalSeriesEditResult(dissolved: true));
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e is FormatException ? e.message : '恢复未完成，原书仍保留，请重试';
        });
      }
    }
  }

  Widget _volume(BuildContext context, int index) {
    final id = _order[index], book = widget.books.book(_order[index])!;
    return Padding(
      key: ValueKey('series-volume-$id'),
      padding: const EdgeInsets.only(bottom: 18),
      child: Material(
        type: MaterialType.transparency,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            NovelCover(book, width: 44, height: 60),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  AppText(
                    book.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.5,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 8),
                  CupertinoTextField(
                    key: ValueKey('series-label-$id'),
                    controller: _label(id),
                    enabled: !_busy,
                    maxLength: 160,
                    placeholder: appText(context, '分卷名称'),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    style: TextStyle(
                      fontSize: 15,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                    decoration: BoxDecoration(
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurface.withValues(alpha: .045),
                      borderRadius: BorderRadius.circular(
                        ArchiveDesign.panelRadius,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 4),
            Column(
              children: [
                if (!_fixed.contains(id))
                  GlassIconButton(
                    icon: CupertinoIcons.minus_circle,
                    label: '不合并 ${book.title}',
                    onPressed: _busy
                        ? null
                        : () => setState(() => _order.remove(id)),
                  ),
                ReorderableDragStartListener(
                  key: ValueKey('series-reorder-$id'),
                  index: index,
                  enabled: !_busy,
                  child: Semantics(
                    label: '拖动调整 ${book.title} 的顺序',
                    customSemanticsActions: {
                      if (index > 0)
                        CustomSemanticsAction(label: '向前移动'): () =>
                            _move(index, index - 1),
                      if (index + 1 < _order.length)
                        CustomSemanticsAction(label: '向后移动'): () =>
                            _move(index, index + 1),
                    },
                    child: const ColoredBox(
                      color: Colors.transparent,
                      child: SizedBox(
                        width: 48,
                        height: 48,
                        child: Icon(CupertinoIcons.line_horizontal_3, size: 19),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _move(int from, int to) {
    if (_busy) return;
    setState(() => _order.insert(to, _order.removeAt(from)));
  }

  @override
  Widget build(BuildContext context) {
    final query = _search.text.trim().toLowerCase();
    final candidates = widget.books.originals.where((book) {
      final owner = widget.books.seriesFor(book.id);
      return !_order.contains(book.id) &&
          (owner == null || owner.id == _series?.id) &&
          (query.isEmpty ||
              '${book.title} ${book.author}'.toLowerCase().contains(query));
    }).toList();
    return PopScope<void>(
      canPop: !_busy,
      child: Scaffold(
        body: Atmosphere(
          child: GlassHeaderLayout(
            header: ArchiveHeaderBar(
              leading: GlassIconButton(
                icon: CupertinoIcons.back,
                label: '返回',
                onPressed: _busy ? null : () => Navigator.maybePop(context),
              ),
              title: ArchiveRouteTitle(
                title: _series == null ? '合并分卷' : '管理分卷',
                code: 'LOCAL / VOLUMES',
              ),
            ),
            body: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: CustomScrollView(
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  slivers: [
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(
                        24,
                        MediaQuery.paddingOf(context).top +
                            FrostedHeader.toolbarHeight +
                            20,
                        24,
                        20,
                      ),
                      sliver: SliverToBoxAdapter(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (widget.suggested) ...[
                              const AppText(
                                '发现同系列书籍。确认分卷与顺序后，合并为一部作品。',
                                style: TextStyle(height: 1.7),
                              ),
                              const SizedBox(height: 20),
                            ],
                            if (widget.books.seriesFor(widget.book.id) == null)
                              GlassTextButton(
                                key: const ValueKey('series-target'),
                                onPressed: _busy ? null : _chooseTarget,
                                child: AppText(
                                  '合并到：${_series?.title ?? '新建合订本'}',
                                ),
                              ),
                            const SizedBox(height: 16),
                            const AppText(
                              '合订本书名',
                              style: TextStyle(fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(height: 9),
                            CupertinoTextField(
                              key: const ValueKey('series-title'),
                              controller: _title,
                              enabled: !_busy,
                              maxLength: 160,
                              padding: const EdgeInsets.all(15),
                              style: TextStyle(
                                fontSize: 16,
                                color: Theme.of(context).colorScheme.onSurface,
                              ),
                              decoration: BoxDecoration(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurface.withValues(alpha: .045),
                                borderRadius: BorderRadius.circular(
                                  ArchiveDesign.panelRadius,
                                ),
                              ),
                            ),
                            const SizedBox(height: 24),
                            ArchiveSection(
                              title: '阅读顺序 · ${_order.length} 卷',
                              code: 'DRAG TO REORDER',
                            ),
                            const SizedBox(height: 8),
                            const AppText(
                              '拖动右侧横线调整顺序，分卷名称可直接修改。',
                              style: TextStyle(fontSize: 13, height: 1.65),
                            ),
                          ],
                        ),
                      ),
                    ),
                    SliverPadding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      sliver: SliverReorderableList(
                        itemCount: _order.length,
                        itemBuilder: _volume,
                        onReorder: (from, to) =>
                            _move(from, to > from ? to - 1 : to),
                      ),
                    ),
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(24, 6, 24, 24),
                      sliver: SliverToBoxAdapter(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (_error != null) ...[
                              AppText(
                                _error!,
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.error,
                                  height: 1.6,
                                ),
                              ),
                              const SizedBox(height: 16),
                            ],
                            GlassPillButton(
                              key: const ValueKey('series-save'),
                              icon: CupertinoIcons.checkmark,
                              label: _busy
                                  ? '正在保存分卷'
                                  : _series == null
                                  ? '合并为一本书'
                                  : '保存分卷',
                              onPressed: _busy || _order.length < 2
                                  ? null
                                  : _save,
                            ),
                            if (_series != null) ...[
                              const SizedBox(height: 12),
                              GlassTextButton(
                                key: const ValueKey('series-dissolve'),
                                onPressed: _busy ? null : _dissolve,
                                child: const AppText('恢复为独立书籍'),
                              ),
                            ],
                            const SizedBox(height: 28),
                            const ArchiveSection(
                              title: '添加分卷',
                              code: 'LOCAL / ORIGINALS',
                            ),
                            const SizedBox(height: 14),
                            AppSearchField(
                              controller: _search,
                              hint: '搜索书名、作者',
                              onChanged: (_) => setState(() {}),
                            ),
                          ],
                        ),
                      ),
                    ),
                    SliverPadding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      sliver: SliverList.builder(
                        itemCount: candidates.length,
                        itemBuilder: (context, index) {
                          final book = candidates[index];
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: GlassTextButton(
                              key: ValueKey('series-add-${book.id}'),
                              onPressed: _busy
                                  ? null
                                  : () => setState(() {
                                      _label(book.id);
                                      _order.add(book.id);
                                    }),
                              child: Row(
                                children: [
                                  const Icon(
                                    CupertinoIcons.plus_circle,
                                    size: 20,
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        AppText(
                                          book.title,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        AppText(
                                          book.author,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(fontSize: 12),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    SliverToBoxAdapter(
                      child: SizedBox(
                        height: MediaQuery.paddingOf(context).bottom + 32,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
