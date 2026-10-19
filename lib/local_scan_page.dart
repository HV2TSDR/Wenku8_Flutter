import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'app_ui.dart';
import 'book_documents.dart';
import 'cloud_sources.dart' show cloudFailureMessage;
import 'local_book_scanner.dart';
import 'book_import_limits.dart';

class LocalScanPage extends StatefulWidget {
  const LocalScanPage({
    super.key,
    required this.documents,
    required this.changes,
    required this.isBusy,
    required this.progress,
    required this.result,
    required this.failure,
    required this.onScan,
  });
  final BookDocuments documents;
  final Listenable changes;
  final bool Function() isBusy;
  final (int, int)? Function() progress;
  final LocalScanResult? Function() result;
  final String? Function() failure;
  final Future<void> Function(BuildContext) onScan;
  @override
  State<LocalScanPage> createState() => _LocalScanPageState();
}

class _LocalScanPageState extends State<LocalScanPage> {
  BookScanFolder? _folder;
  bool _loading = true, _saving = false;
  bool _showFormats = false;
  String? _error;
  Set<String> _formats = bookFormatLabels.keys.toSet();
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final folder = await widget.documents.scanFolderInfo();
      final formats = await widget.documents.scanFormats();
      if (mounted) {
        setState(() {
          _folder = folder;
          _formats = formats;
          _loading = false;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = cloudFailureMessage(error);
          _loading = false;
        });
      }
    }
  }

  Future<void> _configure(Future<void> Function() action) async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await action();
      await _load();
    } catch (error) {
      if (mounted) setState(() => _error = cloudFailureMessage(error));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _select() async {
    var selected = false;
    await _configure(() async {
      selected = await widget.documents.selectScanFolder() != null;
    });
    if (mounted && selected) await widget.onScan(context);
  }

  Future<void> _all() async {
    var selected = false;
    await _configure(() async {
      selected = await widget.documents.selectAllScan() != null;
    });
    if (mounted && selected) await widget.onScan(context);
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.changes,
    builder: (context, _) {
      final busy = _loading || _saving || widget.isBusy();
      final canScan = !busy && _formats.isNotEmpty;
      final result = widget.result(), progress = widget.progress();
      final error = _error ?? widget.failure();
      return Scaffold(
        body: Atmosphere(
          child: GlassHeaderLayout(
            header: ArchiveHeaderBar(
              leading: GlassIconButton(
                icon: CupertinoIcons.back,
                label: '返回书库',
                onPressed: () => Navigator.pop(context),
              ),
              title: const ArchiveRouteTitle(
                title: '扫描本地书籍',
                code: 'LOCAL / FOLDER SCAN',
              ),
            ),
            body: ListView(
              padding: EdgeInsets.fromLTRB(
                24 + MediaQuery.paddingOf(context).left,
                MediaQuery.paddingOf(context).top +
                    FrostedHeader.toolbarHeight +
                    20,
                24 + MediaQuery.paddingOf(context).right,
                MediaQuery.paddingOf(context).bottom + 32,
              ),
              children: [
                ContentPanel(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const AppText(
                        '扫描格式',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        children: [
                          GlassTextButton(
                            compact: true,
                            selected:
                                _formats.length == bookFormatLabels.length,
                            onPressed: busy
                                ? null
                                : () => _configure(
                                    () => widget.documents.setScanFormats(
                                      bookFormatLabels.keys.toSet(),
                                    ),
                                  ),
                            child: const AppText(
                              '全部格式',
                              style: TextStyle(fontSize: 12),
                            ),
                          ),
                          for (final format in bookFormatLabels.entries)
                            GlassTextButton(
                              key: ValueKey('scan-format-${format.key}'),
                              compact: true,
                              selected:
                                  _formats.length != bookFormatLabels.length &&
                                  _formats.contains(format.key),
                              onPressed: busy
                                  ? null
                                  : () {
                                      final next =
                                          _formats.length ==
                                              bookFormatLabels.length
                                          ? <String>{format.key}
                                          : {..._formats};
                                      if (_formats.length !=
                                          bookFormatLabels.length) {
                                        next.contains(format.key)
                                            ? next.remove(format.key)
                                            : next.add(format.key);
                                      }
                                      if (next.isEmpty) {
                                        setState(() => _error = '请至少选择一种格式');
                                        return;
                                      }
                                      _configure(
                                        () => widget.documents.setScanFormats(
                                          next,
                                        ),
                                      );
                                    },
                              child: AppText(
                                format.value,
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                ContentPanel(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      AppText(
                        _folder?.name ?? '选择扫描范围',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 10),
                      const AppText(
                        '先扫描候选文件，再由你勾选导入。全部扫描需要共享存储访问权限，不扫描其他 App 的私有目录。',
                        style: TextStyle(height: 1.6),
                      ),
                      if (_folder?.readable == false)
                        const Padding(
                          padding: EdgeInsets.only(top: 10),
                          child: AppText('文件夹权限已失效，请重新选择。'),
                        ),
                      const SizedBox(height: 18),
                      GlassPillButton(
                        key: const ValueKey('scan-all-storage'),
                        icon: CupertinoIcons.search,
                        label: '全部扫描',
                        onPressed: canScan ? _all : null,
                      ),
                      const SizedBox(height: 10),
                      GlassPillButton(
                        key: const ValueKey('scan-select-folder'),
                        icon: CupertinoIcons.folder,
                        label: _folder?.allStorage == false
                            ? '更换指定文件夹'
                            : '指定文件夹扫描',
                        onPressed: canScan ? _select : null,
                      ),
                    ],
                  ),
                ),
                if (_folder != null) ...[
                  const SizedBox(height: 20),
                  ContentPanel(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            const Expanded(
                              child: AppText(
                                '自动扫描新增书籍',
                                style: TextStyle(fontWeight: FontWeight.w600),
                              ),
                            ),
                            const SizedBox(width: 12),
                            AppControls.toggle(
                              context,
                              key: const ValueKey('scan-automatic'),
                              value: _folder!.automatic,
                              onChanged: busy
                                  ? null
                                  : (value) => _configure(
                                      () => widget.documents.setScanAutomatic(
                                        value,
                                      ),
                                    ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        const AppText(
                          '进入书库时只查找新增和更新的文件。扫描后由你勾选，不会自动导入。',
                          style: TextStyle(fontSize: 13, height: 1.5),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  GlassPillButton(
                    key: const ValueKey('scan-now'),
                    icon: CupertinoIcons.arrow_clockwise,
                    label: widget.isBusy()
                        ? (progress == null
                              ? '正在查找书籍'
                              : '正在导入 ${progress.$1} / ${progress.$2}')
                        : '立即扫描',
                    onPressed: !canScan || !_folder!.readable
                        ? null
                        : () => widget.onScan(context),
                  ),
                  const SizedBox(height: 8),
                  GlassTextButton(
                    onPressed: busy
                        ? null
                        : () =>
                              _configure(widget.documents.disconnectScanFolder),
                    child: const AppText('停止自动扫描'),
                  ),
                ],
                AnimatedOptionSection(
                  expanded: result != null,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SizedBox(height: 24),
                      AppText(
                        result?.summary ?? '',
                        style: const TextStyle(height: 1.6),
                      ),
                      for (final warning
                          in result?.warnings ?? const <String>[])
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: AppText(warning),
                        ),
                    ],
                  ),
                ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: AppText(
                      error,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                const SizedBox(height: 24),
                GlassTextButton(
                  onPressed: () => setState(() => _showFormats = !_showFormats),
                  child: Row(
                    children: [
                      const Expanded(
                        child: AppText(
                          '支持格式与大小',
                          style: TextStyle(fontSize: 13),
                        ),
                      ),
                      Icon(
                        _showFormats
                            ? CupertinoIcons.chevron_up
                            : CupertinoIcons.chevron_down,
                        size: 13,
                      ),
                    ],
                  ),
                ),
                AnimatedOptionSection(
                  expanded: _showFormats,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: AppText(
                      '$bookImportFormatsSummary。\n\n$bookImportLimitsSummary',
                      style: TextStyle(fontSize: 12, height: 1.7),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
