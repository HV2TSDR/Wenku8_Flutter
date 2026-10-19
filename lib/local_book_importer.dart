import 'package:flutter/cupertino.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'app_interactions.dart';
import 'app_ui.dart';
import 'book_documents.dart';
import 'catalog.dart';
import 'cloud_library_page.dart';
import 'cloud_sources.dart';
import 'library_state.dart';
import 'local_books.dart';
import 'local_book_scanner.dart';
import 'local_import_batch.dart';
import 'local_import_review.dart';
import 'local_library_preferences.dart';
import 'local_series_actions.dart';
import 'local_scan_page.dart';
import 'local_scan_selection.dart';

/// Shared by the two library entry points, including series review and cleanup.
class LocalBookImporter extends ChangeNotifier {
  LocalBookImporter({
    required this.books,
    required this.library,
    BookDocuments? documents,
    CloudSourceSettings? cloudSettings,
  }) : documents = documents ?? BookDocuments(),
       _cloud = cloudSettings ?? CloudSourceSettings(),
       _ownsCloud = cloudSettings == null;
  final LocalBookStore books;
  final LibraryState library;
  final BookDocuments documents;
  final CloudSourceSettings _cloud;
  final bool _ownsCloud;
  bool busy = false, _disposed = false;
  (int, int)? progress;
  String? error;
  LocalScanResult? scanResult;
  static bool _scanning = false;
  static DateTime? _lastAutomaticScan;
  bool get _foreground =>
      WidgetsBinding.instance.lifecycleState == null ||
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;

  Future<void> scanOnEntry(BuildContext context, {bool resumed = false}) async {
    if (!_foreground ||
        busy ||
        _disposed ||
        _scanning ||
        (!resumed &&
            _lastAutomaticScan != null &&
            DateTime.now().difference(_lastAutomaticScan!) <
                const Duration(minutes: 1))) {
      return;
    }
    try {
      final folder = await documents.scanFolderInfo();
      if (folder == null ||
          !folder.automatic ||
          !folder.readable ||
          !_foreground ||
          !context.mounted ||
          _disposed ||
          ModalRoute.isCurrentOf(context) == false ||
          !TickerMode.valuesOf(context).enabled) {
        return;
      }
      await run(context, fromScan: true, automatic: true);
    } catch (_) {
      /* Revoked folders remain actionable from the scan page. */
    }
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> showMenu(
    BuildContext context, {
    bool management = false,
    VoidCallback? onManage,
  }) async {
    if (busy) return;
    final action = await showGlassMenu<String>(
      context: context,
      reduceMotion: library.reduceMotion,
      builder: (menu) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GlassMenuItem(
            label: '导入书籍',
            onPressed: () => Navigator.pop(menu, 'local'),
          ),
          GlassMenuItem(
            order: 1,
            label: '从网盘导入',
            onPressed: () => Navigator.pop(menu, 'cloud'),
          ),
          GlassMenuItem(
            order: 2,
            label: '扫描本地文件夹',
            onPressed: () => Navigator.pop(menu, 'scan'),
          ),
          if (management)
            GlassMenuItem(
              order: 3,
              label: '本地分类与同步',
              onPressed: () => Navigator.pop(menu, 'manage'),
            ),
        ],
      ),
    );
    if (!context.mounted || action == null || _disposed) return;
    if (action == 'manage') {
      onManage?.call();
      return;
    }
    if (action == 'scan') {
      await pushNovelPage<void>(
        context,
        LocalScanPage(
          documents: documents,
          changes: this,
          isBusy: () => busy,
          progress: () => progress,
          result: () => scanResult,
          failure: () => error,
          onScan: (page) => run(page, fromScan: true),
        ),
        reduceMotion: library.reduceMotion,
      );
      return;
    }
    await run(context, fromCloud: action == 'cloud');
  }

  Future<void> run(
    BuildContext context, {
    bool fromCloud = false,
    bool fromScan = false,
    bool automatic = false,
  }) async {
    if (busy || _disposed || fromScan && _scanning) return;
    if (fromScan) {
      _scanning = true;
      _lastAutomaticScan = DateTime.now();
      scanResult = null;
    }
    busy = true;
    error = null;
    _changed();
    LocalLibraryPreferences? organization;
    List<BookDocumentSelection> selections = const [];
    final staged = <BookDocumentSelection>[];
    var stagingReleased = false;
    Future<void> releaseStaging() async {
      if (stagingReleased) return;
      final cleanup = <String, BookDocumentSelection>{
        for (final item in [...selections, ...staged])
          item.path ?? 'error:${item.name}': item,
      };
      try {
        await documents.releaseBooks(cleanup.values);
        stagingReleased = true;
      } catch (_) {
        /* Durable imports stay readable even if cache cleanup fails. */
      }
    }

    LocalImportReport? report;
    try {
      final prefs = await SharedPreferences.getInstance();
      organization = library.organization;
      final encoding = prefs.getString('localTxtEncoding') ?? 'auto';
      final fresh = <int>{};
      Future<Novel> importFile(String name, String path) async {
        String? decoded;
        late Novel imported;
        try {
          if (name.toLowerCase().endsWith('.txt')) {
            decoded = await documents.decodeTextFile(path, encoding: encoding);
          }
          imported = await books.importFile(name, path, decodedPath: decoded);
        } finally {
          if (decoded != null) {
            await documents.releaseBooks([
              BookDocumentSelection(name: 'decoded.txt', path: decoded),
            ]);
          }
        }
        final parent = books.seriesFor(imported.id);
        final book = parent == null ? imported : books.book(parent.id)!;
        if (parent != null) await reconcileLocalSeries(books, library);
        await library.setShelfMembership(book.id, false, novel: book);
        final group = library.combinedShelf
            ? organization!.shelfSelected
            : organization!.selected;
        if (group != LocalLibraryPreferences.all) {
          await organization.assign(book.id, group);
        }
        if (parent == null) fresh.add(book.id);
        return book;
      }

      Future<LocalImportReport> importPrepared(
        List<BookDocumentSelection> sources, {
        bool updateProgress = true,
      }) async {
        final prepared = <BookDocumentSelection>[];
        for (final source in sources) {
          final items = await documents.prepareBook(source);
          prepared.addAll(items);
          staged.addAll(
            items.where(
              (item) => item.path != null && item.path != source.path,
            ),
          );
        }
        if (updateProgress) {
          progress = (0, prepared.length);
          _changed();
        }
        return importLocalBatch(
          selections: prepared,
          books: books,
          importFile: importFile,
          onProgress: (done, total) {
            if (updateProgress) {
              progress = (done, total);
              _changed();
            }
          },
        );
      }

      if (!context.mounted || _disposed) return;
      if (fromScan) {
        final snapshot = await documents.scanBooks();
        if (!context.mounted || _disposed) return;
        if (automatic) {
          scanResult = LocalScanResult(
            report: const LocalImportReport(bookIds: [], added: 0, existing: 0),
            total: snapshot.total,
            unchanged: snapshot.unchanged,
            warnings: snapshot.warnings,
            pending: snapshot.books.length,
          );
          _changed();
          await documents.finishBookScan();
          return;
        }
        final selected = snapshot.books.isEmpty
            ? <String>{}
            : await pushNovelPage<Set<String>>(
                context,
                LocalScanSelection(snapshot: snapshot),
                reduceMotion: library.reduceMotion,
              );
        if (selected == null || !context.mounted || _disposed) {
          await documents.finishBookScan();
          return;
        }
        scanResult = await scanLocalBooks(
          documents: documents,
          snapshot: snapshot,
          selectedTokens: selected,
          importSource: (source) async {
            try {
              return await importPrepared([source], updateProgress: false);
            } finally {
              try {
                await documents.releaseBooks(staged);
                staged.clear();
              } catch (_) {
                /* Retry cleanup when the batch closes. */
              }
            }
          },
          current: () =>
              !_disposed &&
              context.mounted &&
              (!automatic ||
                  _foreground &&
                      ModalRoute.isCurrentOf(context) != false &&
                      TickerMode.valuesOf(context).enabled),
          onProgress: (done, total) {
            progress = (done, total);
            _changed();
          },
        );
        report = scanResult!.report;
        _changed();
      } else if (fromCloud) {
        await _cloud.load();
        if (!context.mounted || _disposed) return;
        await pushNovelPage<void>(
          context,
          CloudLibraryPage(
            settings: _cloud,
            onImport: importFile,
            onImportBatch: (name, path) async {
              final batch = await importPrepared([
                BookDocumentSelection(name: name, path: path),
              ]);
              try {
                await documents.releaseBooks(staged);
                staged.clear();
              } catch (_) {
                /* Retry disposable staging cleanup when the route closes. */
              }
              report = LocalImportReport(
                bookIds: {...?report?.bookIds, ...batch.bookIds}.toList(),
                added: (report?.added ?? 0) + batch.added,
                existing: (report?.existing ?? 0) + batch.existing,
                failures: [...?report?.failures, ...batch.failures],
              );
              return (
                imported: batch.added + batch.existing,
                failed: batch.failures.length,
              );
            },
            reduceMotion: library.reduceMotion,
          ),
          reduceMotion: library.reduceMotion,
        );
        if (report == null && fresh.isNotEmpty) {
          report = LocalImportReport(
            bookIds: fresh.toList(),
            added: fresh.length,
            existing: 0,
          );
        }
      } else {
        selections = await documents.pickBooks();
        if (selections.isEmpty || !context.mounted || _disposed) return;
        progress = (0, selections.length);
        _changed();
        report = await importPrepared(selections);
      }
      final completed = report;
      if (!context.mounted || _disposed || completed == null) return;
      await releaseStaging();
      if (!context.mounted || _disposed) return;
      if (!automatic) {
        for (final id in completed.bookIds) {
          await library.setLocalBookHidden(id, false);
        }
      }
      if (!context.mounted || _disposed) return;
      if (automatic) {
        if (completed.added > 0 &&
            ModalRoute.isCurrentOf(context) != false &&
            TickerMode.valuesOf(context).enabled) {
          showNovelFeedback(context, scanResult!.summary);
        }
        return;
      }
      if (localImportGroups(books, completed.bookIds).isNotEmpty ||
          completed.failures.isNotEmpty) {
        await pushNovelPage<void>(
          context,
          LocalImportReview(books: books, library: library, report: completed),
          reduceMotion: library.reduceMotion,
        );
      } else {
        showNovelFeedback(
          context,
          fromScan ? scanResult!.summary : completed.summary,
        );
      }
    } catch (failure) {
      error = cloudFailureMessage(failure);
      if (context.mounted && !_disposed) showNovelFeedback(context, error!);
    } finally {
      await releaseStaging();
      busy = false;
      if (fromScan) _scanning = false;
      progress = null;
      _changed();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    if (_ownsCloud) _cloud.dispose();
    super.dispose();
  }
}

class LocalBookImportButton extends StatefulWidget {
  const LocalBookImportButton({
    super.key,
    required this.books,
    required this.library,
    this.onManage,
  });
  final LocalBookStore books;
  final LibraryState library;
  final VoidCallback? onManage;
  @override
  State<LocalBookImportButton> createState() => _LocalBookImportButtonState();
}

class _LocalBookImportButtonState extends State<LocalBookImportButton>
    with WidgetsBindingObserver {
  late final importer = LocalBookImporter(
    books: widget.books,
    library: widget.library,
  );
  bool _active = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      importer.scanOnEntry(context, resumed: true);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final active =
        TickerMode.valuesOf(context).enabled &&
        ModalRoute.isCurrentOf(context) != false;
    if (active && !_active) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) importer.scanOnEntry(context);
      });
    }
    _active = active;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    importer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: importer,
    builder: (context, _) => GlassMenuAnchor(
      child: Builder(
        builder: (anchor) => GlassIconButton(
          key: const ValueKey('shelf-import-book'),
          icon: CupertinoIcons.plus,
          label: switch (importer.progress) {
            final progress? => '正在导入 ${progress.$1} / ${progress.$2} 本',
            _ => importer.busy ? '正在导入书籍' : '导入书籍',
          },
          onPressed: importer.busy
              ? null
              : () => importer.showMenu(
                  anchor,
                  management: widget.onManage != null,
                  onManage: widget.onManage,
                ),
        ),
      ),
    ),
  );
}
