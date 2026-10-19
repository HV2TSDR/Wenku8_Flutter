import 'dart:convert';
import 'dart:io';
import 'catalog.dart';

final _textChapter = RegExp(
  r'^(第[零〇一二三四五六七八九十百千万两0-9０-９]+[章节回幕话話]|chapter\s+\d+|序章|序言|楔子|尾声|尾聲|后记|後記|番外)',
  caseSensitive: false,
);
final _textVolume = RegExp(
  r'^(第[零〇一二三四五六七八九十百千万两0-9０-９]+[卷部]|volume\s+\d+)',
  caseSensitive: false,
);

/// Even a book with no newline keeps only a bounded physical-line fragment.
/// Decoder preserves UTF-8 sequences; fragment boundaries preserve surrogates.
Stream<({String text, bool heading})> _lines(File file) async* {
  var tail = '', split = false, first = true;
  await for (var chunk in file.openRead().transform(utf8.decoder)) {
    if (first) {
      chunk = chunk.replaceFirst(RegExp('^\uFEFF'), '');
      first = false;
    }
    var start = 0;
    for (final end in [
      ...RegExp(r'[\r\n]').allMatches(chunk).map((m) => m.start),
      chunk.length,
    ]) {
      final value = tail + chunk.substring(start, end);
      var at = 0;
      while (value.length - at > 4000) {
        var next = at + 4000;
        final last = value.codeUnitAt(next - 1);
        if (last >= 0xd800 && last <= 0xdbff) next--;
        yield (text: value.substring(at, next), heading: false);
        at = next;
        split = true;
      }
      tail = value.substring(at);
      if (end < chunk.length) {
        yield (text: tail, heading: !split);
        tail = '';
        split = false;
      }
      start = end + 1;
    }
  }
  if (tail.isNotEmpty) yield (text: tail, heading: !split);
}

/// Called inside the import worker; emits each chapter straight to staging.
Future<List<NovelChapter>> importTextChapters(
  File file,
  String name,
  void Function(int index, String body) save,
) async {
  final chapters = <NovelChapter>[];
  final paragraphs = <String>[];
  var length = 0, volume = '', volumeId = 0, part = 0;
  var title = name
      .replaceAll('\\', '/')
      .split('/')
      .last
      .replaceFirst(RegExp(r'\.txt$', caseSensitive: false), '');
  if (title.length > 2048) title = title.substring(0, 2048);
  void flush() {
    if (paragraphs.isEmpty) return;
    if (chapters.length >= 10000) {
      throw const FormatException('TXT 章节超过 10000 个，请拆分原书后导入');
    }
    chapters.add(
      NovelChapter(
        part == 0 ? title : '$title · 片段 ${part + 1}',
        '',
        id: chapters.length + 1,
        volumeTitle: volume,
        volumeId: volumeId,
      ),
    );
    save(chapters.length, paragraphs.join('\n\n'));
    part++;
    length = 0;
    paragraphs.clear();
  }

  await for (final line in _lines(file)) {
    final value = line.text.trim();
    if (value.isEmpty) continue;
    if (line.heading && value.length <= 90 && _textVolume.hasMatch(value)) {
      flush();
      volume = value;
      volumeId++;
      title = value;
      part = 0;
    } else if (line.heading &&
        value.length <= 90 &&
        _textChapter.hasMatch(value)) {
      flush();
      title = value;
      part = 0;
    } else {
      paragraphs.add(value);
      length += value.length + 2;
      if (length >= 100000) flush();
    }
  }
  flush();
  if (chapters.isEmpty) throw const FormatException('文件中没有可阅读的正文');
  return chapters;
}
