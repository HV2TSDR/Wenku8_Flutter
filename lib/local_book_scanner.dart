import 'book_documents.dart';
import 'cloud_sources.dart' show cloudFailureMessage;
import 'local_import_batch.dart';

class LocalScanResult {
  const LocalScanResult({
    required this.report,
    required this.total,
    required this.unchanged,
    this.warnings = const [],
    this.interrupted = false,
    this.pending = 0,
  });
  final LocalImportReport report;
  final int total, unchanged;
  final List<String> warnings;
  final bool interrupted;
  final int pending;
  String get summary => [
    pending > 0
        ? '发现 $pending 个候选文件，选择后导入'
        : report.summary.isEmpty
        ? (total == 0 ? '未找到支持的书籍' : '没有新增书籍')
        : report.summary,
    if (unchanged > 0) '跳过 $unchanged 个未变动文件',
    if (warnings.isNotEmpty) '${warnings.length} 项需要检查',
    if (interrupted) '余下文件将在下次扫描时继续',
  ].join(' · ');
}

/// Copy and import one original at a time. Only a completely successful source
/// is acknowledged, so a failed ZIP member is retried on the next scan.
Future<LocalScanResult> scanLocalBooks({
  required BookDocuments documents,
  required BookScanSnapshot snapshot,
  required Set<String> selectedTokens,
  required Future<LocalImportReport> Function(BookDocumentSelection source)
  importSource,
  required bool Function() current,
  void Function(int done, int total)? onProgress,
}) async {
  final selected = snapshot.books
      .where((entry) => selectedTokens.contains(entry.token))
      .toList();
  final ids = <int>{}, warnings = [...snapshot.warnings];
  final failures = <LocalImportFailure>[];
  var added = 0, existing = 0, done = 0;
  onProgress?.call(0, selected.length);
  try {
    for (final entry in selected) {
      if (!current()) break;
      BookDocumentSelection? staged;
      try {
        staged = await documents.stageScanBook(entry.token);
        final report = await importSource(staged);
        ids.addAll(report.bookIds);
        added += report.added;
        existing += report.existing;
        failures.addAll(report.failures);
        if (report.failures.isEmpty && report.bookIds.isNotEmpty) {
          try {
            await documents.markScanBook(entry.token);
          } catch (_) {
            warnings.add('${entry.name}：扫描记录未保存，下次扫描将重新检查，不会重复添加');
          }
        }
      } catch (error) {
        failures.add((name: entry.name, message: cloudFailureMessage(error)));
      } finally {
        if (staged != null) {
          try {
            await documents.releaseBooks([staged]);
          } catch (_) {
            warnings.add('${entry.name}：临时文件将在系统清理缓存时移除');
          }
        }
        onProgress?.call(++done, selected.length);
      }
    }
  } finally {
    try {
      await documents.finishBookScan();
    } catch (_) {
      warnings.add('扫描记录未能完整保存，下次会重新检查，不会重复添加');
    }
  }
  return LocalScanResult(
    report: LocalImportReport(
      bookIds: ids.toList(),
      added: added,
      existing: existing,
      failures: failures,
    ),
    total: snapshot.total,
    unchanged: snapshot.unchanged,
    warnings: warnings,
    interrupted: done < selected.length,
  );
}
