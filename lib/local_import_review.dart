import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'app_interactions.dart';
import 'app_ui.dart';
import 'library_state.dart';
import 'local_books.dart';
import 'local_import_batch.dart';
import 'local_library_preferences.dart';
import 'local_series_actions.dart';
import 'local_series_editor.dart';
import 'listening/widgets.dart';

class LocalImportReview extends StatefulWidget {
  const LocalImportReview({
    super.key,
    required this.books,
    required this.library,
    required this.report,
  });
  final LocalBookStore books;
  final LibraryState library;
  final LocalImportReport report;
  @override
  State<LocalImportReview> createState() => _LocalImportReviewState();
}

class _LocalImportReviewState extends State<LocalImportReview> {
  late final _groups = localImportGroups(widget.books, widget.report.bookIds);
  late final _selected = {
    for (final g in _groups)
      if (!g.needsTarget) g.seed,
  };
  final _done = <int>{};
  final _errors = <int, String>{};
  bool _busy = false;

  Future<void> _edit(LocalImportGroup group) async {
    final result = await pushNovelPage<LocalSeriesEditResult>(
      context,
      LocalSeriesEditor(
        book: widget.books.book(group.seed)!,
        books: widget.books,
        library: widget.library,
        suggested: true,
      ),
      reduceMotion: widget.library.reduceMotion,
    );
    if (!mounted) return;
    if (result?.bookId != null) {
      setState(() {
        _done.add(group.seed);
        _selected.remove(group.seed);
        _errors.remove(group.seed);
      });
    }
  }

  Future<void> _merge() async {
    if (_busy) return;
    final listening = ListeningScope.maybeOf(context);
    setState(() => _busy = true);
    LocalLibraryPreferences? prefs;
    try {
      prefs = widget.library.organization;
      for (final group in _groups.where((g) => _selected.contains(g.seed))) {
        try {
          final playing = listening?.snapshot.value.novel?.id;
          if (playing != null &&
              (playing == group.targetId ||
                  group.volumes.any((v) => v.bookId == playing))) {
            await listening?.stop();
          }
          // Adopt an already-created target on retry if a record write failed
          // after the durable series file was saved.
          final book = await saveLocalSeries(
            books: widget.books,
            library: widget.library,
            id: widget.books.seriesFor(group.seed)?.id ?? group.targetId,
            title: group.title,
            volumes: group.volumes,
          );
          if (group.targetId == null) {
            await prefs.assign(book.id, prefs.groupOf(group.seed));
          }
          _done.add(group.seed);
          _errors.remove(group.seed);
        } catch (error) {
          _errors[group.seed] = error is FormatException
              ? error.message
              : '合并未完成，原书仍保留，可重试';
        }
      }
      _selected.removeAll(_done);
      if (!mounted) return;
      if (_errors.isEmpty) {
        Navigator.pop(context);
      } else {
        setState(() {});
      }
    } catch (_) {
      if (mounted) showNovelFeedback(context, '分卷配置读取失败，请重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope<void>(
    canPop: !_busy,
    child: Scaffold(
      body: Atmosphere(
        child: GlassHeaderLayout(
          header: ArchiveHeaderBar(
            leading: GlassIconButton(
              icon: CupertinoIcons.back,
              label: '返回',
              onPressed: _busy ? null : () => Navigator.pop(context),
            ),
            title: const ArchiveRouteTitle(
              title: '导入完成',
              code: 'LOCAL / IMPORT',
            ),
          ),
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: ListView(
                padding: EdgeInsets.fromLTRB(
                  24,
                  MediaQuery.paddingOf(context).top +
                      FrostedHeader.toolbarHeight +
                      24,
                  24,
                  MediaQuery.paddingOf(context).bottom + 32,
                ),
                children: [
                  AppText(
                    widget.report.summary,
                    style: const TextStyle(fontSize: 17, height: 1.6),
                  ),
                  if (_groups.isNotEmpty) ...[
                    const SizedBox(height: 24),
                    const ArchiveSection(
                      title: '同系列分卷',
                      code: 'REVIEW / MERGE',
                    ),
                    const SizedBox(height: 12),
                    const AppText(
                      '确认后合并为一本书，也可以保留各卷独立显示。',
                      style: TextStyle(height: 1.7),
                    ),
                    for (final group in _groups)
                      Padding(
                        padding: const EdgeInsets.only(top: 18),
                        child: ContentPanel(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: AppText(
                                      group.title,
                                      style: const TextStyle(
                                        fontSize: 17,
                                        height: 1.6,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  if (_done.contains(group.seed))
                                    const Icon(CupertinoIcons.checkmark_circle)
                                  else
                                    Semantics(
                                      label: '合并 ${group.title}',
                                      child: AppControls.toggle(
                                        context,
                                        key: ValueKey(
                                          'import-group-${group.seed}',
                                        ),
                                        value: _selected.contains(group.seed),
                                        onChanged: _busy || group.needsTarget
                                            ? null
                                            : (value) => setState(() {
                                                if (value) {
                                                  _selected.add(group.seed);
                                                } else {
                                                  _selected.remove(group.seed);
                                                }
                                              }),
                                      ),
                                    ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              AppText(
                                '${group.volumes.length} 卷${group.targetId == null ? '' : ' · 加入已有合订本'}',
                                style: TextStyle(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                              ),
                              const SizedBox(height: 8),
                              for (final volume in group.volumes)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 6),
                                  child: AppText(
                                    '${volume.title} · ${widget.books.book(volume.bookId)!.title}',
                                    style: const TextStyle(
                                      fontSize: 13,
                                      height: 1.6,
                                    ),
                                  ),
                                ),
                              if (_errors[group.seed] case final error?)
                                AppText(
                                  error,
                                  style: TextStyle(
                                    color: Theme.of(context).colorScheme.error,
                                    height: 1.6,
                                  ),
                                ),
                              if (!_done.contains(group.seed))
                                GlassTextButton(
                                  key: ValueKey('import-edit-${group.seed}'),
                                  onPressed: _busy ? null : () => _edit(group),
                                  child: AppText(
                                    group.needsTarget
                                        ? '选择合订本并确认'
                                        : '调整书名与分卷顺序',
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                  ],
                  if (widget.report.failures.isNotEmpty) ...[
                    const SizedBox(height: 28),
                    const ArchiveSection(
                      title: '未导入的文件',
                      code: 'IMPORT / RETRY',
                    ),
                    for (final (index, failure)
                        in widget.report.failures.indexed)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: ContentPanel(
                          key: ValueKey('import-failure-$index'),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Icon(CupertinoIcons.doc_text, size: 20),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: AppText(
                                      failure.name,
                                      style: const TextStyle(
                                        fontSize: 14,
                                        height: 1.5,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              AppText(
                                failure.message,
                                style: TextStyle(
                                  fontSize: 13,
                                  height: 1.6,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                  const SizedBox(height: 28),
                  GlassPillButton(
                    key: const ValueKey('import-confirm-merge'),
                    icon: CupertinoIcons.checkmark,
                    label: _busy
                        ? '正在合并'
                        : _selected.isEmpty
                        ? '完成'
                        : '确认合并 ${_selected.length} 个系列',
                    onPressed: _busy
                        ? null
                        : _selected.isEmpty
                        ? () => Navigator.pop(context)
                        : _merge,
                  ),
                  if (_selected.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    GlassTextButton(
                      key: const ValueKey('import-keep-separate'),
                      onPressed: _busy ? null : () => Navigator.pop(context),
                      child: const AppText('暂不合并'),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
