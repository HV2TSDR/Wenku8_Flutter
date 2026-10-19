import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'app_interactions.dart';
import 'app_ui.dart';
import 'app_search_field.dart';
import 'archive_carousel.dart';
import 'book_collection_layout.dart';
import 'book_categories.dart';
import 'book_documents.dart';
import 'book_sync.dart';
import 'catalog.dart';
import 'cloud_book_sync_panel.dart';
import 'cloud_sources.dart';
import 'library_state.dart';
import 'library_toolbar.dart';
import 'library_reflow.dart';
import 'local_books.dart';
import 'local_book_importer.dart';
import 'local_library_preferences.dart';
import 'local_series_editor.dart';
import 'local_book_removal.dart';
import 'local_book_batch_page.dart';
import 'pages.dart' show NovelRow;

export 'cloud_book_sync_panel.dart' show CloudBookSyncPanel;

class LocalLibraryController extends ChangeNotifier {
  void Function(BuildContext)? importMenu;
  VoidCallback? search, refresh;
  bool importing = false;
  void changed() => notifyListeners();
}

Widget _localLibraryHeader(
  BuildContext context,
  LocalLibraryController? controller, {
  bool back = false,
}) {
  Widget header() => Row(
    children: [
      if (back)
        GlassIconButton(
          icon: CupertinoIcons.back,
          label: '返回',
          onPressed: () => Navigator.pop(context),
        ),
      const Expanded(
        child: ArchiveMasthead(title: '本地', code: '03 / LOCAL ARCHIVE'),
      ),
      GlassMenuAnchor(
        child: Builder(
          builder: (anchor) => GlassIconButton(
            key: const ValueKey('local-import-book'),
            icon: CupertinoIcons.plus,
            label: '导入书籍',
            onPressed: controller?.importMenu == null
                ? null
                : () => controller!.importMenu!(anchor),
          ),
        ),
      ),
      GlassIconButton(
        key: const ValueKey('local-search'),
        icon: CupertinoIcons.search,
        label: '搜索本地书籍',
        onPressed: controller?.search,
      ),
    ],
  );
  return controller == null
      ? header()
      : AnimatedBuilder(animation: controller, builder: (_, _) => header());
}

class LocalLibraryPage extends StatefulWidget {
  const LocalLibraryPage({
    super.key,
    required this.books,
    required this.state,
    required this.onOpen,
    this.onOpenWithCover,
    this.showHeader = true,
    this.controller,
    this.documents,
    this.cloudSettings,
    this.onSearch,
  });
  final LocalBookStore books;
  final LibraryState state;
  final void Function(BuildContext, Novel) onOpen;
  final void Function(BuildContext, Novel, Object)? onOpenWithCover;
  final bool showHeader;
  final LocalLibraryController? controller;
  final BookDocuments? documents;
  final CloudSourceSettings? cloudSettings;
  final VoidCallback? onSearch;
  Widget buildHeader(BuildContext context) =>
      _localLibraryHeader(context, controller, back: showHeader);

  @override
  State<LocalLibraryPage> createState() => _LocalLibraryPageState();
}

class _LocalLibraryPageState extends State<LocalLibraryPage>
    with WidgetsBindingObserver {
  late final _documents = widget.documents ?? BookDocuments();
  late final _controller = widget.controller ?? LocalLibraryController();
  late final _cloudSources = widget.cloudSettings ?? CloudSourceSettings();
  late final _importer = LocalBookImporter(
    books: widget.books,
    library: widget.state,
    documents: _documents,
    cloudSettings: _cloudSources,
  );
  final _search = TextEditingController();
  final _searchFocus = FocusNode(debugLabel: 'local-library-search');
  bool _searchOpen = false;
  BookSync? _sync;
  LocalLibraryPreferences? _organization;
  String? _error;
  String _encoding = 'auto';
  bool _importing = false;
  (int, int)? _importProgress;
  bool? _routeCurrent;
  bool _scanActive = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller.refresh = _reload;
    _controller.search = widget.onSearch ?? _toggleSearch;
    _controller.importMenu = _importMenu;
    _importer.addListener(_importChanged);
    _load();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      _importer.scanOnEntry(context, resumed: true);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final current = ModalRoute.isCurrentOf(context);
    final scanActive = current != false && TickerMode.valuesOf(context).enabled;
    if (scanActive && !_scanActive) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _importer.scanOnEntry(context);
      });
    }
    _scanActive = scanActive;
    if (current == true && _routeCurrent == false) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && ModalRoute.isCurrentOf(context) == true) _reload();
      });
    }
    _routeCurrent = current;
  }

  void _toggleSearch() {
    setState(() {
      _searchOpen = !_searchOpen;
      if (!_searchOpen) {
        _searchFocus.unfocus();
        _search.clear();
      }
    });
    if (_searchOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            _searchOpen &&
            _searchFocus.canRequestFocus &&
            ModalRoute.isCurrentOf(context) != false) {
          _searchFocus.requestFocus();
        }
      });
    }
  }

  Future<void> _importMenu(BuildContext anchor) async {
    _searchFocus.unfocus();
    await _importer.showMenu(anchor);
    if (mounted) _reload();
  }

  void _importChanged() {
    if (!mounted) return;
    setState(() {
      _importing = _importer.busy;
      _importProgress = _importer.progress;
      _error = _importer.error;
    });
    _controller
      ..importing = _importing
      ..importMenu = _importing ? null : _importMenu
      ..changed();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      final organization = widget.state.organization;
      final sync = BookSync(
        books: widget.books,
        state: widget.state,
        preferences: prefs,
        documents: _documents,
        organization: organization,
      );
      setState(() {
        _organization = organization;
        _sync = sync;
        _encoding = prefs.getString('localTxtEncoding') ?? 'auto';
      });
      _controller.changed();
      await Future.wait([sync.load(), _cloudSources.load()]);
    } catch (_) {
      if (mounted) setState(() => _error = '本地书库设置读取失败，请重试');
    }
  }

  void _reload() {
    try {
      _organization?.refresh();
      if (mounted) setState(() {});
    } catch (_) {
      if (mounted) setState(() => _error = '本地分类读取失败，请重试');
    }
  }

  Future<void> _save(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      if (mounted) {
        showNovelFeedback(
          context,
          e is FormatException ? e.message : '设置保存失败，请重试',
        );
      }
    }
  }

  Future<void> _volumes(Novel book, {bool suggested = false}) async {
    final result = await pushNovelPage<LocalSeriesEditResult>(
      context,
      LocalSeriesEditor(
        book: book,
        books: widget.books,
        library: widget.state,
        suggested: suggested,
      ),
      reduceMotion: widget.state.reduceMotion,
    );
    if (!mounted || result == null) return;
    _organization?.refresh();
    showNovelFeedback(
      context,
      result.dissolved
          ? '已恢复为独立书籍'
          : '已保存《${widget.books.book(result.bookId!)!.title}》的分卷',
    );
  }

  Future<void> _syncSettings() async {
    final sync = _sync;
    if (sync != null) {
      await showJellySheet<void>(
        context: context,
        reduceMotion: widget.state.reduceMotion,
        heightFactor: .86,
        builder: (_) => CloudBookSyncPanel(sync: sync),
      );
    }
  }

  Future<void> _remove(Novel book) async {
    await _save(() async {
      await chooseLocalBookRemoval(
        context,
        book: book,
        books: widget.books,
        library: widget.state,
      );
    });
  }

  Future<void> _bookMenu(Novel book) async {
    final organization = _organization!;
    final value = await showJellySheet<String>(
      context: context,
      reduceMotion: widget.state.reduceMotion,
      builder: (sheet) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ArchiveSection(title: book.title, code: 'LOCAL / ORGANIZE'),
            const SizedBox(height: 14),
            for (final entry in {
              LocalLibraryPreferences.unfiled: '未分类',
              ...organization.groups,
            }.entries)
              GlassTextButton(
                onPressed: () => Navigator.pop(sheet, entry.key),
                child: AppText('移至 ${entry.value}'),
              ),
            GlassTextButton(
              onPressed: () => Navigator.pop(sheet, '_series'),
              child: AppText(
                widget.books.seriesFor(book.id) == null ? '合并分卷' : '管理分卷',
              ),
            ),
            GlassTextButton(
              onPressed: () => Navigator.pop(sheet, '_batch'),
              child: const AppText('批量选择'),
            ),
            GlassTextButton(
              onPressed: () => Navigator.pop(sheet, '_delete'),
              child: const AppText('移除书籍'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || value == null) return;
    if (value == '_series') {
      await _volumes(book);
    } else if (value == '_delete') {
      await _remove(book);
    } else if (value == '_batch') {
      await openLocalBookBatch(
        context,
        books: widget.books,
        library: widget.state,
        selected: {book.id},
      );
    } else {
      await _save(() => organization.assign(book.id, value));
    }
  }

  Future<void> _categories() => showBookCategories(
    context,
    _organization!,
    reduceMotion: widget.state.reduceMotion,
  );

  Future<void> _display() async {
    final organization = _organization!;
    final more = await showJellySheet<bool>(
      context: context,
      reduceMotion: widget.state.reduceMotion,
      heightFactor: .72,
      builder: (sheet) => AnimatedBuilder(
        animation: organization,
        builder: (_, _) => LibraryViewOptions(
          shelf: organization.view == LocalLibraryView.shelf,
          viewHint: '当前分类满 10 本时显示立体书架，列表始终显示全部书籍。',
          reading: organization.readingFilter,
          sort: organization.sort.name,
          onView: (v) => _save(
            () => organization.setView(
              v ? LocalLibraryView.shelf : LocalLibraryView.list,
            ),
          ),
          onReading: (v) => _save(() => organization.setReadingFilter(v)),
          onSort: (v) => _save(
            () => organization.setSort(LocalLibrarySort.values.byName(v)),
          ),
          footer: GlassTextButton(
            onPressed: () => Navigator.pop(sheet, true),
            child: const AppText('更多本地设置'),
          ),
        ),
      ),
    );
    if (mounted && more == true) await _settings();
  }

  Future<void> _settings() async {
    final organization = _organization!;
    await showJellySheet<void>(
      context: context,
      reduceMotion: widget.state.reduceMotion,
      heightFactor: .72,
      builder: (sheet) => AnimatedBuilder(
        animation: organization,
        builder: (context, _) => SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const ArchiveSection(title: '书库设置', code: 'LOCAL / SETTINGS'),
              const SizedBox(height: 18),
              const AppText(
                'TXT 编码',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              for (final entry in {
                'auto': '自动识别',
                'UTF-8': 'UTF-8',
                'GB18030': 'GB18030 / GBK',
                'UTF-16LE': 'UTF-16 LE',
              }.entries)
                GlassTextButton(
                  onPressed: () => _save(() async {
                    await organization.setEncoding(entry.key);
                    if (mounted) setState(() => _encoding = entry.key);
                  }),
                  child: AppText(
                    '${_encoding == entry.key ? '✓  ' : ''}${entry.value}',
                  ),
                ),
              const Divider(height: 32),
              GlassTextButton(
                key: const ValueKey('local-removed-books'),
                onPressed: () {
                  Navigator.pop(sheet);
                  pushNovelPage<void>(
                    this.context,
                    RemovedLocalBooksPage(
                      books: widget.books,
                      library: widget.state,
                    ),
                    reduceMotion: widget.state.reduceMotion,
                  );
                },
                child: const AppText('已移出的本地书'),
              ),
              GlassTextButton(
                onPressed: () {
                  Navigator.pop(sheet);
                  _syncSettings();
                },
                child: const AppText('跨设备同步设置'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _open(Novel book, Object tag) {
    if (widget.onOpenWithCover case final open?) {
      open(context, book, tag);
    } else {
      widget.onOpen(context, book);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller
      ..importMenu = null
      ..search = null
      ..refresh = null;
    if (widget.controller == null) _controller.dispose();
    _sync?.dispose();
    _importer.removeListener(_importChanged);
    _importer.dispose();
    if (widget.cloudSettings == null) _cloudSources.dispose();
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  Widget _header(BuildContext context) =>
      _localLibraryHeader(context, _controller, back: true);
  @override
  Widget build(BuildContext context) {
    final organization = _organization;
    final body = GlassHeaderLayout(
      showHeader: widget.showHeader,
      header: _header(context),
      body: AnimatedBuilder(
        animation: Listenable.merge([
          widget.books,
          widget.state.historyChanges,
          widget.state.shelfViewChanges,
          ?organization,
        ]),
        builder: (context, _) {
          final books =
              organization
                  ?.filter(
                    widget.books.books.where(
                      (book) => widget.state.localBookVisible(book.id),
                    ),
                    query: _search.text,
                    addedAt: widget.books.importedAt,
                    readAt: (id) =>
                        widget.state.positionFor(id)?.updatedAt ?? 0,
                  )
                  .where(
                    (book) => switch (organization.readingFilter) {
                      'unread' => !widget.state.hasRead(book.id),
                      'reading' =>
                        widget.state.hasRead(book.id) &&
                            !widget.state.finishedReading(book),
                      'finished' => widget.state.finishedReading(book),
                      _ => true,
                    },
                  )
                  .toList() ??
              const <Novel>[];
          final shelf = organization?.showsShelf(books.length) == true;
          // A carousel is a featured view, not a replacement for the index.
          // Every filtered book remains reachable in the same complete list.
          final rows = books;
          return LoadedContentSequence(
            generation: (
              organization?.selected,
              organization?.readingFilter,
              organization?.sort,
              _search.text,
              shelf,
            ),
            child: CustomScrollView(
              key: const PageStorageKey('local-library'),
              clipBehavior: LibraryReflowScope.clipOf(context),
              cacheExtent: BookCollectionLayout.cacheExtentFor(
                MediaQuery.sizeOf(context).width - 48,
                base: 250,
              ),
              slivers: [
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(
                    24,
                    MediaQuery.paddingOf(context).top +
                        FrostedHeader.toolbarHeight +
                        20,
                    24,
                    14,
                  ),
                  sliver: SliverToBoxAdapter(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        LibraryToolbar(
                          categoryKey: const ValueKey('local-category'),
                          optionsKey: const ValueKey('local-display'),
                          manageKey: const ValueKey('local-manage'),
                          onManage:
                              organization == null || widget.books.books.isEmpty
                              ? null
                              : () => openLocalBookBatch(
                                  context,
                                  books: widget.books,
                                  library: widget.state,
                                ),
                          category:
                              organization?.nameOf(organization.selected) ??
                              '全部书籍',
                          count: books.length,
                          loading: organization == null,
                          activeFilters: organization?.readingFilter == 'all'
                              ? 0
                              : 1,
                          onCategory: organization == null ? null : _categories,
                          onOptions: organization == null ? null : _display,
                        ),
                        AnimatedOptionSection(
                          expanded: _searchOpen,
                          child: Padding(
                            padding: const EdgeInsets.only(top: 14),
                            child: AppSearchField(
                              controller: _search,
                              focusNode: _searchFocus,
                              hint: '搜索本地书名、作者',
                              onChanged: (_) => setState(() {}),
                            ),
                          ),
                        ),
                        const SizedBox(height: 14),
                        if (widget.books.books.isEmpty &&
                            organization != null) ...[
                          const AppText(
                            '还没有本地书籍，点击右上角 ＋ 添加。',
                            style: TextStyle(height: 1.7),
                          ),
                        ],
                        if (_importing || organization == null)
                          BookCollectionSkeleton(
                            rows: 2,
                            label: _importProgress == null
                                ? '正在整理本地书库'
                                : '正在导入 ${_importProgress!.$1} / ${_importProgress!.$2} 本',
                          ),
                        if ((_error ?? widget.books.seriesError) != null) ...[
                          AppText(
                            (_error ?? widget.books.seriesError)!,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                          if (organization == null)
                            GlassTextButton(
                              onPressed: _load,
                              child: const AppText('重试'),
                            ),
                        ],
                        if (organization != null &&
                            books.isEmpty &&
                            widget.books.books.isNotEmpty)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 24),
                            child: AppText('没有符合条件的书籍，换个分类或关键词试试。'),
                          ),
                      ],
                    ),
                  ),
                ),
                if (shelf)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: ArchiveFileCarousel(
                        key: ValueKey(('local-shelf', organization!.selected)),
                        books: books.take(10).toList(),
                        reduceMotion: widget.state.reduceMotion,
                        animateEntrance: true,
                        onOpen: _open,
                      ),
                    ),
                  ),
                if (shelf && rows.isNotEmpty)
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
                    sliver: SliverToBoxAdapter(
                      child: ArchiveSection(
                        title: '全部书籍',
                        code: '${rows.length} FILES',
                      ),
                    ),
                  ),
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  sliver: BookCollectionSliver(
                    itemCount: rows.length,
                    itemBuilder: (context, index) {
                      final book = rows[index],
                          tag = ValueKey('local-cover-${rows[index].id}');
                      return LoadedContentItem(
                        key: ValueKey(book.id),
                        index: index,
                        placeholder: const BookRowSkeleton(),
                        child: NovelRow(
                          novel: book,
                          coverHeroTag: tag,
                          onTap: () => _open(book, tag),
                          trailing: GlassIconButton(
                            icon: CupertinoIcons.ellipsis,
                            label: '整理 ${book.title}',
                            onPressed: () => _bookMenu(book),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                SliverToBoxAdapter(
                  child: SizedBox(
                    height:
                        MediaQuery.paddingOf(context).bottom +
                        (widget.showHeader ? 32 : 120),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
    return widget.showHeader ? Scaffold(body: Atmosphere(child: body)) : body;
  }
}
