import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Color;
import 'package:html/dom.dart' as html;
import 'package:html/parser.dart' as html;
import 'package:path_provider/path_provider.dart';
import 'package:xml/xml.dart';

import 'catalog.dart';
import 'book_identity.dart';
import 'book_import_limits.dart';
import 'local_book_media.dart';
import 'local_book_series.dart';
import 'epub_image_styles.dart';
import 'local_text_import.dart';
import 'reader_content.dart' show readerIllustrationUrl;

export 'book_identity.dart' show localBookIdStart, isLocalBook;

class ImportedBook {
  const ImportedBook(
    this.novel,
    this.digest,
    this.bodies,
    this.images, {
    this.seriesHint,
  });
  final Novel novel;
  final String digest;
  final List<String> bodies;
  final Map<String, Uint8List> images;
  final LocalSeriesHint? seriesHint;
}

class LocalBookInput {
  const LocalBookInput(this.name, this.bytes, {this.text});
  final String name;
  final Uint8List bytes;

  /// Text decoded by the document bridge (UTF-8, UTF-16 or GB18030).
  final String? text;
}

Iterable<String> _boundedParagraphs(String text) sync* {
  for (var start = 0; start < text.length;) {
    var end = (start + 4000).clamp(0, text.length);
    if (end < text.length) {
      final last = text.codeUnitAt(end - 1);
      if (last >= 0xD800 && last <= 0xDBFF) end--;
    }
    yield text.substring(start, end);
    start = end;
  }
}

String _metadataText(String value) {
  if (value.length <= 2048) return value;
  var end = 2048;
  final last = value.codeUnitAt(end - 1);
  if (last >= 0xD800 && last <= 0xDBFF) end--;
  return value.substring(0, end);
}

ImportedBook parseLocalBook(LocalBookInput input) {
  _validateInput(input.name, input.bytes.length);
  // Content identity makes re-import and cross-device sync address the same
  // book. The complete digest also detects the rare truncated-ID collision.
  final digest = sha256.convert(input.bytes).toString();
  final id =
      localBookIdStart |
      (int.parse(digest.substring(0, 8), radix: 16) & 0x1fffffff);
  final name = input.name.replaceAll('\\', '/').split('/').last;
  if (name.toLowerCase().endsWith('.epub')) return _epub(input, id, digest);
  if (!name.toLowerCase().endsWith('.txt')) {
    throw const FormatException('目前支持 TXT 与 EPUB 格式');
  }
  final text = (input.text ?? utf8.decode(input.bytes)).replaceFirst(
    '\uFEFF',
    '',
  );
  final lines = text.replaceAll(RegExp(r'\r\n?'), '\n').split('\n');
  final chapters = <NovelChapter>[];
  final bodies = <String>[];
  final buffer = <String>[];
  var title = name.substring(0, name.length - 4);
  var volume = '';
  var volumeId = 0;
  final chapterPattern = RegExp(
    r'^(第[零〇一二三四五六七八九十百千万两0-9０-９]+[章节回幕话話]|chapter\s+\d+|序章|序言|楔子|尾声|尾聲|后记|後記|番外)',
    caseSensitive: false,
  );
  final volumePattern = RegExp(
    r'^(第[零〇一二三四五六七八九十百千万两0-9０-９]+[卷部]|volume\s+\d+)',
    caseSensitive: false,
  );
  void flush() {
    if (buffer.isEmpty) return;
    // Bound unstructured TXT chapters as well as memory and lazy text layout.
    final paragraphs = <String>[];
    for (final line in buffer) {
      paragraphs.addAll(_boundedParagraphs(line));
    }
    var part = 0;
    for (var start = 0; start < paragraphs.length;) {
      final chunk = <String>[];
      var length = 0;
      while (start < paragraphs.length && length < 100000) {
        final p = paragraphs[start++];
        length += p.length;
        chunk.add(p);
      }
      final section = chunk.length == paragraphs.length
          ? title
          : '$title · 片段 ${++part}';
      chapters.add(
        NovelChapter(
          section,
          '',
          id: chapters.length + 1,
          volumeId: volumeId,
          volumeTitle: volume,
        ),
      );
      bodies.add(chunk.join('\n\n'));
    }
    buffer.clear();
  }

  for (final raw in lines) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    if (line.length <= 90 && volumePattern.hasMatch(line)) {
      flush();
      volume = line;
      volumeId++;
      title = line;
    } else if (line.length <= 90 && chapterPattern.hasMatch(line)) {
      flush();
      title = line;
    } else {
      buffer.add(line);
    }
  }
  flush();
  if (chapters.isEmpty) throw const FormatException('文件中没有可阅读的正文');
  return ImportedBook(
    _novel(id, name.substring(0, name.length - 4), '', chapters),
    digest,
    bodies,
    const {},
  );
}

void _validateInput(String name, int size) {
  if (size <= 0) throw const FormatException('文件为空，请重新下载原书');
  if (!RegExp(r'\.(txt|epub)$', caseSensitive: false).hasMatch(name)) {
    throw const FormatException('目前支持 TXT 与 EPUB 格式');
  }
  if (size > localBookByteLimit(name)) {
    throw FormatException(localBookSizeMessage(name));
  }
}

Novel _novel(
  int id,
  String title,
  String author,
  List<NovelChapter> chapters, {
  String? cover,
}) => Novel(
  id: id,
  title: _metadataText(title),
  author: author.isEmpty ? '本地书籍' : _metadataText(author),
  genre: '本地导入',
  summary: '已保存到本地书库，可离线阅读。',
  colors: const [Color(0xFF646464), Color(0xFF303030)],
  chapters: List.unmodifiable(chapters),
  chapterCount: chapters.length,
  isComplete: true,
  coverUrl: cover,
);

/// Entries are decoded lazily, only after declared sizes and names are checked.
/// No archive-supplied path is ever used as a filesystem destination.
Archive boundedZip(
  Uint8List bytes, {
  int maxSize = 160 * 1024 * 1024,
  int maxEntrySize = 40 * 1024 * 1024,
}) => _boundedZipStream(
  InputMemoryStream(bytes),
  maxSize: maxSize,
  maxEntrySize: maxEntrySize,
);

Archive _boundedZipStream(
  InputStream input, {
  required int maxSize,
  int maxEntrySize = 40 * 1024 * 1024,
}) {
  if (input.length < 22) {
    throw const FormatException('压缩文件不完整，请重新下载原书');
  }
  final headers = ZipDirectory()..read(input);
  if (headers.fileHeaders.isEmpty) {
    throw const FormatException('压缩包中没有可读取的文件');
  }
  if (headers.fileHeaders.length > 12000) {
    throw const FormatException('压缩包包含过多文件');
  }
  var declared = 0;
  for (final header in headers.fileHeaders) {
    declared += header.uncompressedSize;
    if (header.uncompressedSize > maxEntrySize ||
        declared > maxSize ||
        (header.externalFileAttributes >> 16) & 0xf000 == 0xa000) {
      throw const FormatException('压缩包包含不支持的文件或大小超出限制');
    }
  }
  input.setPosition(0);
  final archive = ZipDecoder().decodeStream(input);
  if (archive.length > 12000) throw const FormatException('压缩包包含过多文件');
  var total = 0;
  for (final entry in archive) {
    total += entry.size;
    if (entry.isSymbolicLink ||
        entry.size > maxEntrySize ||
        total > maxSize ||
        entry.name.startsWith('/') ||
        entry.name.contains('\\') ||
        entry.name.split('/').contains('..')) {
      throw const FormatException('压缩包大小或路径不受支持');
    }
  }
  return archive;
}

ImportedBook _epub(
  LocalBookInput input,
  int id,
  String digest, {
  Archive? archive,
  void Function(String name, ArchiveFile file)? saveImage,
  void Function(int index, String body)? saveBody,
}) {
  final zip = archive ?? boundedZip(input.bytes, maxSize: 1024 * 1024 * 1024);
  final files = {
    for (final f in zip)
      if (f.isFile) f.name: f,
  };
  String read(String path) {
    final file = files[path];
    if (file == null || file.size > 8 * 1024 * 1024) {
      throw const FormatException('EPUB 缺少有效的章节或目录');
    }
    final output = OutputMemoryStream();
    file.writeContent(output);
    return utf8.decode(output.getBytes());
  }

  if (files.containsKey('META-INF/encryption.xml')) {
    final encryption = read('META-INF/encryption.xml');
    if (!encryption.contains('http://www.idpf.org/2008/embedding') &&
        !encryption.contains('http://ns.adobe.com/pdf/enc#RC')) {
      throw const FormatException('不支持受 DRM 保护的 EPUB');
    }
  }
  final container = XmlDocument.parse(read('META-INF/container.xml'));
  final opfPath = container.descendants
      .whereType<XmlElement>()
      .firstWhere((e) => e.name.local == 'rootfile')
      .getAttribute('full-path');
  if (opfPath == null) throw const FormatException('EPUB 缺少书籍索引');
  String resolve(String base, String href) {
    final uri = Uri.parse('https://local/$base').resolve(href);
    if (uri.host != 'local') throw const FormatException('EPUB 引用了外部资源');
    return Uri.decodeComponent(uri.path.substring(1));
  }

  final package = XmlDocument.parse(read(opfPath));
  final elements = package.descendants.whereType<XmlElement>().toList();
  String field(String name) =>
      elements
          .where((e) => e.name.local == name)
          .firstOrNull
          ?.innerText
          .trim() ??
      '';
  final manifest = {
    for (final e in elements.where((e) => e.name.local == 'item'))
      if (e.getAttribute('id') != null && e.getAttribute('href') != null)
        e.getAttribute('id')!: (
          path: resolve(opfPath, e.getAttribute('href')!),
          type: e.getAttribute('media-type') ?? '',
          props: e.getAttribute('properties') ?? '',
        ),
  };
  ({String path, String fragment}) target(String base, String href) => (
    path: resolve(base, href),
    fragment: Uri.decodeComponent(
      Uri.parse('https://local/$base').resolve(href).fragment,
    ),
  );
  final labels =
      <({String path, String fragment}), ({String title, String volume})>{};
  final ncx = manifest.values
      .where((e) => e.type == 'application/x-dtbncx+xml')
      .firstOrNull;
  if (ncx != null) {
    final nav = XmlDocument.parse(read(ncx.path));
    void walk(XmlElement node, String parent) {
      final points = node.childElements.where(
        (e) => e.name.local == 'navPoint',
      );
      for (final point in points) {
        final title =
            point.childElements
                .where((e) => e.name.local == 'navLabel')
                .firstOrNull
                ?.innerText
                .trim() ??
            '';
        final href = point.childElements
            .where((e) => e.name.local == 'content')
            .firstOrNull
            ?.getAttribute('src');
        final children = point.childElements.any(
          (e) => e.name.local == 'navPoint',
        );
        if (href != null) {
          labels[target(ncx.path, href)] = (
            title: title,
            volume: children ? title : parent,
          );
        }
        walk(point, children ? title : parent);
      }
    }

    for (final node in nav.descendants.whereType<XmlElement>().where(
      (e) => e.name.local == 'navMap',
    )) {
      walk(node, '');
    }
  }
  final epubNav = manifest.values
      .where((e) => e.props.split(' ').contains('nav'))
      .firstOrNull;
  if (epubNav != null) {
    final document = html.parse(read(epubNav.path));
    final nav =
        document.querySelector('nav[epub\\:type="toc"]') ??
        document.querySelector('nav');
    void walk(html.Element root, String parent) {
      for (final li in root.children.where((e) => e.localName == 'li')) {
        final a = li.children.where((e) => e.localName == 'a').firstOrNull;
        final ol = li.children.where((e) => e.localName == 'ol').firstOrNull;
        final title =
            (a ?? li.children.where((e) => e.localName == 'span').firstOrNull)
                ?.text
                .trim() ??
            '';
        final href = a?.attributes['href'];
        if (href != null) {
          labels[target(epubNav.path, href)] = (
            title: title,
            volume: ol == null ? parent : title,
          );
        }
        if (ol != null) walk(ol, title);
      }
    }

    final ol = nav?.querySelector('ol');
    if (ol != null) walk(ol, '');
  }
  final images = <String, Uint8List>{};
  final imagePaths = <String, String>{};
  String? addImage(String path, {bool cover = false}) {
    if (imagePaths.containsKey(path) && !cover) return imagePaths[path];
    final file = files[path];
    final ext = path.split('.').last.toLowerCase();
    if (file == null ||
        file.size > 8 * 1024 * 1024 ||
        !['png', 'jpg', 'jpeg', 'webp', 'gif'].contains(ext)) {
      return null;
    }
    final name = cover ? 'cover.$ext' : 'img-${imagePaths.length}.$ext';
    if (saveImage == null) {
      images[name] = file.readBytes()!;
    } else {
      saveImage(name, file);
    }
    return imagePaths[path] = 'wenku-local://$id/$name';
  }

  final coverId = elements
      .where((e) => e.name.local == 'meta' && e.getAttribute('name') == 'cover')
      .firstOrNull
      ?.getAttribute('content');
  final cover =
      manifest[coverId] ??
      manifest.values
          .where((e) => e.props.split(' ').contains('cover-image'))
          .firstOrNull;
  String? coverPath = cover?.path;
  // A broken optional cover reference must not reject an otherwise readable
  // book. EPUB2 guide entries may name XHTML/SVG wrappers rather than images.
  try {
    coverPath ??= elements
        .where(
          (e) =>
              e.name.local == 'reference' && e.getAttribute('type') == 'cover',
        )
        .map((e) => e.getAttribute('href'))
        .whereType<String>()
        .map((href) => resolve(opfPath, href))
        .firstOrNull;
    if (coverPath != null &&
        RegExp(r'\.(x?html?|svg)$', caseSensitive: false).hasMatch(coverPath)) {
      final doc = html.parse(read(coverPath));
      final image = doc.querySelector('img, image');
      final href =
          image?.attributes['src'] ??
          image?.attributes['href'] ??
          image?.attributes['xlink:href'];
      coverPath = href == null ? null : resolve(coverPath, href);
    }
  } on FormatException {
    coverPath = null;
  }
  coverPath ??= manifest.values
      .where(
        (e) =>
            e.type.startsWith('image/') &&
            RegExp(
              r'(^|[/_.-])cover([_.-]|$)',
              caseSensitive: false,
            ).hasMatch(e.path),
      )
      .firstOrNull
      ?.path;
  final coverUrl = coverPath == null ? null : addImage(coverPath, cover: true);
  final chapters = <NovelChapter>[];
  final bodies = <String>[];
  var currentVolume = '';
  var volumeId = 0;
  for (final item in elements.where((e) => e.name.local == 'itemref')) {
    if (item.getAttribute('linear') == 'no') continue;
    final file = manifest[item.getAttribute('idref')];
    if (file == null ||
        !['application/xhtml+xml', 'text/html'].contains(file.type)) {
      continue;
    }
    final document = html.parse(read(file.path));
    final imageLayouts = epubImageStyles(document, (href) {
      try {
        final path = resolve(file.path, href);
        return files.containsKey(path) ? read(path) : null;
      } on FormatException {
        return null;
      }
    });
    for (final el in document.querySelectorAll(
      'script, style, nav, noscript',
    )) {
      el.remove();
    }
    var label = labels[(path: file.path, fragment: '')];
    final boundaries = {
      for (final e in labels.entries)
        if (e.key.path == file.path && e.key.fragment.isNotEmpty)
          e.key.fragment: e.value,
    };
    final heading = document.querySelector('h1, h2, h3')?.text.trim();
    final output = <String>[];
    final text = StringBuffer();
    void flush() {
      final value = text
          .toString()
          .replaceAll(RegExp(r'[ \t\r\n]+'), ' ')
          .trim();
      if (value.isNotEmpty) output.addAll(_boundedParagraphs(value));
      text.clear();
    }

    void finishChapter() {
      flush();
      final title = label?.title.isNotEmpty == true
          ? label!.title
          : heading?.isNotEmpty == true
          ? heading!
          : '第 ${chapters.length + 1} 章';
      if (output.isNotEmpty && output.first == title && output.length > 1) {
        output.removeAt(0);
      }
      final body = output.join('\n\n');
      output.clear();
      if (body.isEmpty) return;
      if (utf8.encode(body).length > 8 * 1024 * 1024) {
        throw const FormatException('EPUB 单章超过 8 MB');
      }
      final nextVolume = label?.volume ?? currentVolume;
      if (nextVolume != currentVolume) {
        currentVolume = nextVolume;
        volumeId++;
      }
      chapters.add(
        NovelChapter(
          _metadataText(title),
          '',
          id: chapters.length + 1,
          volumeTitle: currentVolume,
          volumeId: volumeId,
        ),
      );
      if (saveBody == null) {
        bodies.add(body);
      } else {
        saveBody(chapters.length, body);
      }
    }

    void visit(html.Node node) {
      if (node is html.Text) {
        text.write(node.text);
        return;
      }
      if (node is! html.Element) return;
      final boundary =
          boundaries[node.id.isNotEmpty ? node.id : node.attributes['name']];
      if (boundary != null) {
        finishChapter();
        label = boundary;
      }
      final tag = node.localName;
      if (tag == 'img' || tag == 'image') {
        flush();
        final src =
            node.attributes['src'] ??
            node.attributes['href'] ??
            node.attributes.entries
                .where((e) => e.key.toString() == 'xlink:href')
                .firstOrNull
                ?.value;
        if (src != null) {
          try {
            final url = addImage(resolve(file.path, src));
            if (url != null) {
              output.add(
                '<!--image-->$url<!--image-->${imageLayouts[node]?.suffix ?? ''}',
              );
            }
          } on FormatException {
            /* External images are not fetched during import. */
          }
        }
        return;
      }
      const blocks = {
        'p',
        'div',
        'section',
        'h1',
        'h2',
        'h3',
        'h4',
        'blockquote',
        'li',
        'br',
      };
      final block = blocks.contains(tag);
      if (block) flush();
      for (final child in node.nodes) {
        visit(child);
      }
      if (block) flush();
    }

    visit(document.body!);
    finishChapter();
  }
  if (chapters.isEmpty) throw const FormatException('EPUB 未找到可阅读的正文');
  final title = field('title');
  String meta(String name) =>
      elements
          .where(
            (e) =>
                e.name.local == 'meta' &&
                (e.getAttribute('name') == name ||
                    e.getAttribute('property') == name),
          )
          .map((e) => e.getAttribute('content') ?? e.innerText.trim())
          .firstOrNull ??
      '';
  final collection = meta('calibre:series').isNotEmpty
      ? meta('calibre:series')
      : meta('belongs-to-collection');
  final collectionNumber = double.tryParse(
    meta('calibre:series_index').isNotEmpty
        ? meta('calibre:series_index')
        : meta('group-position'),
  );
  return ImportedBook(
    _novel(
      id,
      title.isEmpty
          ? input.name.replaceFirst(
              RegExp(r'\.epub$', caseSensitive: false),
              '',
            )
          : title,
      field('creator'),
      chapters,
      cover: coverUrl,
    ),
    digest,
    bodies,
    images,
    seriesHint:
        collection.isNotEmpty &&
            collectionNumber != null &&
            collectionNumber.isFinite &&
            collectionNumber > 0
        ? LocalSeriesHint(_metadataText(collection), collectionNumber)
        : inferLocalSeries(title) ?? inferLocalSeries(input.name),
  );
}

class _ImportJob {
  const _ImportJob({
    required this.root,
    required this.name,
    required this.known,
    this.input,
    this.path,
    this.text,
    this.decodedPath,
  });
  final String root, name;
  final Map<int, String> known;
  final LocalBookInput? input;
  final String? path, text, decodedPath;
}

class _ImportedFile {
  const _ImportedFile(this.id, [this.novel, this.source]);
  final int id;
  final Novel? novel;
  final Map<String, dynamic>? source;
}

/// File-backed imports keep compressed bytes and extracted illustrations off
/// the UI isolate. Only the chapter directory comes back across the port.
Future<_ImportedFile> _importOriginal(_ImportJob job) async {
  final file = job.path == null ? null : File(job.path!);
  final size = job.input?.bytes.length ?? await file!.length();
  _validateInput(job.name, size);
  final digest = job.input == null
      ? (await sha256.bind(file!.openRead()).first).toString()
      : sha256.convert(job.input!.bytes).toString();
  final id =
      localBookIdStart |
      (int.parse(digest.substring(0, 8), radix: 16) & 0x1fffffff);
  if (job.known[id] case final previous?) {
    if (previous != digest) {
      throw const FormatException('本地书籍标识冲突，原书已保留');
    }
    return _ImportedFile(id);
  }
  final staging = Directory('${job.root}/.$id-import');
  if (await staging.exists()) await staging.delete(recursive: true);
  await staging.create(recursive: true);
  InputFileStream? stream;
  try {
    late ImportedBook parsed;
    if (file != null && job.name.toLowerCase().endsWith('.epub')) {
      stream = InputFileStream(file.path);
      parsed = _epub(
        LocalBookInput(job.name, Uint8List(0)),
        id,
        digest,
        archive: _boundedZipStream(stream, maxSize: 1024 * 1024 * 1024),
        saveBody: (index, body) =>
            File('${staging.path}/c$index.txt').writeAsStringSync(body),
        saveImage: (name, image) {
          final output = OutputFileStream('${staging.path}/$name');
          try {
            image.writeContent(output);
          } finally {
            output.closeSync();
          }
        },
      );
    } else if (file != null &&
        job.name.toLowerCase().endsWith('.txt') &&
        job.text == null) {
      final chapters = await importTextChapters(
        File(job.decodedPath ?? file.path),
        job.name,
        (index, body) =>
            File('${staging.path}/c$index.txt').writeAsStringSync(body),
      );
      parsed = ImportedBook(
        _novel(
          id,
          job.name
              .replaceAll('\\', '/')
              .split('/')
              .last
              .replaceFirst(RegExp(r'\.txt$', caseSensitive: false), ''),
          '',
          chapters,
        ),
        digest,
        const [],
        const {},
      );
    } else {
      parsed = parseLocalBook(
        job.input ??
            LocalBookInput(job.name, await file!.readAsBytes(), text: job.text),
      );
    }
    final text = job.input?.text ?? job.text;
    final source = <String, dynamic>{
      'name': job.name,
      'digest': digest,
      'encoding': text == null && job.decodedPath == null ? 'utf8' : 'decoded',
      'parser': 2,
      'imageSizing': 1,
      'importedAt': DateTime.now().millisecondsSinceEpoch,
      if (parsed.seriesHint != null) 'seriesHint': parsed.seriesHint!.toJson(),
    };
    if (file == null) {
      await File(
        '${staging.path}/original',
      ).writeAsBytes(job.input!.bytes, flush: true);
    } else {
      await file.copy('${staging.path}/original');
    }
    if (text != null) {
      await File(
        '${staging.path}/decoded.txt',
      ).writeAsString(text, flush: true);
    } else if (job.decodedPath != null) {
      await File(job.decodedPath!).copy('${staging.path}/decoded.txt');
    }
    for (var i = 0; i < parsed.bodies.length; i++) {
      File('${staging.path}/c${i + 1}.txt').writeAsStringSync(parsed.bodies[i]);
    }
    for (final image in parsed.images.entries) {
      File('${staging.path}/${image.key}').writeAsBytesSync(image.value);
    }
    final metadata = jsonEncode({
      'version': 1,
      'novel': parsed.novel.toSnapshot(),
      'source': source,
      'chapters': [
        for (final c in parsed.novel.chapters)
          {
            'id': c.id,
            'title': c.title,
            'volumeId': c.volumeId,
            'volumeTitle': c.volumeTitle,
          },
      ],
    });
    if (utf8.encode(metadata).length > 4 * 1024 * 1024) {
      throw const FormatException('书籍目录过大，请拆分原书后导入');
    }
    await File(
      '${staging.path}/book.json',
    ).writeAsString(metadata, flush: true);
    await staging.rename('${job.root}/$id');
    return _ImportedFile(id, parsed.novel, source);
  } on ArchiveException {
    throw const FormatException('EPUB 压缩文件损坏，请重新下载原书');
  } finally {
    stream?.closeSync();
    if (await staging.exists()) await staging.delete(recursive: true);
  }
}

class _ImageSizingJob {
  const _ImageSizingJob(this.root, this.name, this.id, this.digest);
  final String root, name, digest;
  final int id;
}

List<String> _readImageSizing(_ImageSizingJob job) {
  final stream = InputFileStream('${job.root}/${job.id}/original');
  try {
    return _epub(
      LocalBookInput(job.name, Uint8List(0)),
      job.id,
      job.digest,
      archive: _boundedZipStream(stream, maxSize: 512 * 1024 * 1024),
      saveImage: (_, _) {},
    ).bodies;
  } finally {
    stream.closeSync();
  }
}

/// Durable originals are separate from disposable network caches.
class LocalBookStore extends ChangeNotifier {
  LocalBookStore(this.directory);
  final Directory directory;
  final Map<int, Novel> _books = {};
  final Map<int, Map<String, dynamic>> _sources = {};
  final Map<int, LocalBookSeries> _series = {};
  final Map<int, Novel> _seriesBooks = {};
  final Map<int, Map<int, ({int bookId, int chapterId})>> _seriesChapters = {};
  final Map<int, String?> _seriesCovers = {};
  String? seriesError;
  Future<void> _writes = Future.value();
  final _imageUpgrades = <int, Future<void>>{};
  bool _disposed = false;
  List<Novel>? _visibleBooks;
  @override
  void notifyListeners() {
    _visibleBooks = null;
    super.notifyListeners();
  }

  List<Novel> get books {
    if (_visibleBooks case final snapshot?) return snapshot;
    final members = <int>{
      for (final id in _seriesBooks.keys)
        ..._series[id]!.volumes.map((v) => v.bookId),
    };
    return _visibleBooks = List.unmodifiable([
      ..._books.values.where((b) => !members.contains(b.id)),
      ..._seriesBooks.values,
    ]);
  }

  List<Novel> get originals => List.unmodifiable(_books.values);
  List<LocalBookSeries> get series =>
      List.unmodifiable(_seriesBooks.keys.map((id) => _series[id]!));
  List<LocalBookSeries> get seriesDefinitions =>
      List.unmodifiable(_series.values);

  /// A dissolved series still maps stale cloud positions to the original
  /// volumes. Its chapter map is retained, but it is not a visible book.
  Novel? seriesSnapshot(int id) {
    if (_seriesBooks[id] case final current?) return current;
    final series = _series[id];
    if (series == null ||
        series.volumes.any(
          (v) => _books[v.bookId]?.chapters.length != v.chapterIds.length,
        )) {
      return null;
    }
    final first = _books[series.volumes.first.bookId]!;
    return Novel.fromSnapshot({
      ...first.toSnapshot(),
      'id': id,
      'title': series.title,
      'author': series.author,
      'summary': series.summary,
      'coverUrl': null,
    }).withChapters([
      for (final volume in series.volumes)
        for (final (i, chapter) in _books[volume.bookId]!.chapters.indexed)
          NovelChapter(
            chapter.title,
            '',
            id: volume.chapterIds[i],
            volumeId: volume.bookId,
            volumeTitle: volume.title,
          ),
    ]);
  }

  LocalBookSeries? seriesFor(int id) {
    if (_seriesBooks.containsKey(id)) return _series[id];
    return series
        .where((s) => s.volumes.any((v) => v.bookId == id))
        .firstOrNull;
  }

  Novel? book(int id) => _seriesBooks[id] ?? _books[id];
  int importedAt(int id) =>
      _sources[id]?['importedAt'] as int? ??
      _series[id]?.volumes.map((v) => importedAt(v.bookId)).fold<int>(0, max) ??
      0;
  bool contains(int id) => book(id) != null;
  LocalSeriesHint? seriesHint(int id) =>
      LocalSeriesHint.fromJson(_sources[id]?['seriesHint']) ??
      inferLocalSeries(_books[id]?.title ?? '') ??
      inferLocalSeries(_sources[id]?['name'] ?? '');

  List<Novel> relatedVolumes(int id) {
    final hint = seriesHint(id);
    if (hint == null || seriesFor(id) != null) return const [];
    final author = _books[id]?.author ?? '';
    bool matches(Novel b) {
      final hints = _seriesBooks.containsKey(b.id)
          ? _series[b.id]!.volumes.map((v) => seriesHint(v.bookId))
          : [seriesHint(b.id)];
      final sameTitle =
          seriesTitleKey(b.title) == hint.key ||
          hints.any((h) => h?.key == hint.key);
      return sameTitle &&
          (author == '本地书籍' ||
              b.author == '本地书籍' ||
              seriesTitleKey(author) == seriesTitleKey(b.author));
    }

    return books.where((b) => b.id != id && matches(b)).toList();
  }

  static Future<LocalBookStore> forApp() async {
    final store = LocalBookStore(
      Directory(
        '${(await getApplicationSupportDirectory()).path}/local-books-v1',
      ),
    );
    await store.load();
    LocalBookMedia.root = store.directory;
    return store;
  }

  Future<void> load() async {
    await directory.create(recursive: true);
    final found = <int, Novel>{};
    final sources = <int, Map<String, dynamic>>{};
    await for (final entity in directory.list()) {
      if (entity is! Directory) continue;
      final id = int.tryParse(
        entity.uri.pathSegments.where((p) => p.isNotEmpty).last,
      );
      if (id == null || !isLocalBook(id)) continue;
      try {
        final metadata = File('${entity.path}/book.json');
        if (await metadata.length() > 4 * 1024 * 1024) continue;
        final map =
            jsonDecode(await metadata.readAsString()) as Map<String, dynamic>;
        final novel = Novel.fromSnapshot(
          Map<String, dynamic>.from(map['novel']),
        );
        if (novel.id != id) continue;
        final chapters = (map['chapters'] as List)
            .map(
              (c) => NovelChapter(
                c['title'],
                '',
                id: c['id'],
                volumeId: c['volumeId'] ?? 0,
                volumeTitle: c['volumeTitle'] ?? '',
              ),
            )
            .toList();
        if (chapters.isEmpty || chapters.any((c) => c.id <= 0)) continue;
        found[id] = novel.withChapters(chapters);
        sources[id] = Map<String, dynamic>.from(map['source']);
      } catch (_) {
        /* An interrupted staged import is never shown as a book. */
      }
    }
    _books
      ..clear()
      ..addAll(found);
    _sources
      ..clear()
      ..addAll(sources);
    _series.clear();
    seriesError = null;
    final seriesFile = File('${directory.path}/series.json');
    if (await seriesFile.exists()) {
      try {
        if (await seriesFile.length() > 4 * 1024 * 1024) {
          throw const FormatException('分卷记录过大');
        }
        for (final entry in decodeLocalSeries(
          jsonDecode(await seriesFile.readAsString()),
        )) {
          _series[entry.id] = entry;
        }
      } catch (_) {
        seriesError = '分卷记录读取失败，独立原书仍可阅读，请恢复同步副本';
      }
    }
    await _refreshSeries();
    if (!_disposed) notifyListeners();
  }

  Future<Novel> import(LocalBookInput input) =>
      _import(input.name, input: input);

  Future<Novel> importFile(
    String name,
    String path, {
    String? text,
    String? decodedPath,
  }) => _import(name, path: path, text: text, decodedPath: decodedPath);

  Future<Novel> _import(
    String name, {
    LocalBookInput? input,
    String? path,
    String? text,
    String? decodedPath,
  }) async {
    late Novel result;
    final work = _writes.catchError((Object _) {}).then((_) async {
      final imported = await compute(
        _importOriginal,
        _ImportJob(
          root: directory.path,
          name: name,
          input: input,
          path: path,
          text: text,
          decodedPath: decodedPath,
          known: {
            for (final e in _sources.entries)
              e.key: e.value['digest'] as String,
            for (final id in _series.keys) id: 'reserved-series',
          },
        ),
      );
      if (imported.novel != null) {
        _books[imported.id] = imported.novel!;
        _sources[imported.id] = imported.source!;
        await _refreshSeries();
        if (!_disposed) notifyListeners();
      }
      result = _books[imported.id]!;
    });
    _writes = work;
    await work;
    return result;
  }

  Future<String> chapterContent(int id, NovelChapter chapter) async {
    if (!contains(id) || !book(id)!.chapters.any((c) => c.id == chapter.id)) {
      throw const FormatException('本地书籍或章节不存在，请重新导入原书');
    }
    final source = _seriesChapters[id]?[chapter.id];
    final base = source?.bookId ?? id;
    final file = File(
      '${directory.path}/$base/c${source?.chapterId ?? chapter.id}.txt',
    );
    final body = await file.readAsString();
    if (_sources[base]?['imageSizing'] != 1 &&
        (_sources[base]?['name'] as String? ?? '').toLowerCase().endsWith(
          '.epub',
        ) &&
        body.contains('<!--image-->')) {
      try {
        await _imageUpgrades.putIfAbsent(base, () => _upgradeImageSizing(base));
        return await file.readAsString();
      } catch (_) {
        // A missing/damaged original must not make saved prose unreadable.
        // Its images still get natural-size rendering from their own headers.
        return body;
      }
    }
    return body;
  }

  Future<void> _upgradeImageSizing(int id) async {
    final work = _writes.catchError((Object _) {}).then((_) async {
      final source = _sources[id], book = _books[id];
      if (source == null || book == null || source['imageSizing'] == 1) return;
      final bodies = await compute(
        _readImageSizing,
        _ImageSizingJob(
          directory.path,
          source['name'] as String,
          id,
          source['digest'] as String,
        ),
      );
      if (bodies.length != book.chapters.length) {
        throw const FormatException('原书目录与本地目录不一致');
      }
      final replacements = <File, String>{};
      String plain(String body) => body
          .split('\n\n')
          .map((paragraph) {
            final url = readerIllustrationUrl(paragraph);
            return url?.startsWith('wenku-local:') == true
                ? '<!--image-->$url<!--image-->'
                : paragraph;
          })
          .join('\n\n');
      for (var i = 0; i < bodies.length; i++) {
        if (book.chapters[i].id != i + 1) {
          throw const FormatException('本地章节标识已改变');
        }
        final target = File('${directory.path}/$id/c${i + 1}.txt');
        final before = await target.readAsString();
        if (plain(before) != plain(bodies[i])) {
          throw const FormatException('原书正文与本地正文不一致');
        }
        if (before != bodies[i]) replacements[target] = bodies[i];
      }
      // Only sizing suffixes may change: chapter IDs, prose offsets, paragraph
      // counts, user metadata and series references are untouched.
      for (final replacement in replacements.entries) {
        final next = File('${replacement.key.path}.image-size-next');
        try {
          await next.writeAsString(replacement.value, flush: true);
          await next.rename(replacement.key.path);
        } finally {
          if (await next.exists()) await next.delete();
        }
      }
      final target = File('${directory.path}/$id/book.json');
      final record =
          jsonDecode(await target.readAsString()) as Map<String, dynamic>;
      final changedSource = {...source, 'imageSizing': 1};
      record['source'] = changedSource;
      final next = File('${target.path}.image-size-next');
      try {
        await next.writeAsString(jsonEncode(record), flush: true);
        await next.rename(target.path);
      } finally {
        if (await next.exists()) await next.delete();
      }
      _sources[id] = changedSource;
    });
    _writes = work;
    await work;
  }

  Future<void> _refreshSeries() async {
    final novels = <int, Novel>{};
    final references = <int, Map<int, ({int bookId, int chapterId})>>{};
    for (final series in _series.values.where((s) => !s.deleted)) {
      if (series.volumes.any(
        (v) =>
            _books[v.bookId] == null ||
            _books[v.bookId]!.chapters.length != v.chapterIds.length,
      )) {
        continue;
      }
      final chapters = <NovelChapter>[];
      final refs = <int, ({int bookId, int chapterId})>{};
      for (final volume in series.volumes) {
        final original = _books[volume.bookId]!;
        for (final (i, chapter) in original.chapters.indexed) {
          final id = volume.chapterIds[i];
          chapters.add(
            NovelChapter(
              chapter.title,
              '',
              id: id,
              volumeId: volume.bookId,
              volumeTitle: volume.title,
            ),
          );
          refs[id] = (bookId: volume.bookId, chapterId: chapter.id);
        }
      }
      final first = _books[series.volumes.first.bookId]!;
      String? cover;
      final uri = Uri.tryParse(first.coverUrl ?? '');
      if (uri != null && LocalBookMedia.valid(uri)) {
        final source = File('${directory.path}/${uri.host}${uri.path}');
        final folder = Directory('${directory.path}/${series.id}');
        final target = File('${folder.path}${uri.path}');
        if (await source.exists()) {
          await folder.create(recursive: true);
          if ((_seriesCovers.containsKey(series.id) &&
                  _seriesCovers[series.id] != first.coverUrl) ||
              !await target.exists()) {
            final next = await source.copy('${target.path}.next');
            await next.rename(target.path);
            LocalBookMedia.evict(series.id);
          }
          cover = 'wenku-local://${series.id}${uri.path}';
        }
      }
      _seriesCovers[series.id] = first.coverUrl;
      novels[series.id] = Novel.fromSnapshot({
        ...first.toSnapshot(),
        'id': series.id,
        'title': series.title,
        'author': series.author,
        'summary': series.summary,
        'genre': '本地合订本',
        'coverUrl': cover,
        'chapterCount': chapters.length,
      }).withChapters(chapters);
      references[series.id] = refs;
    }
    _seriesBooks
      ..clear()
      ..addAll(novels);
    _seriesChapters
      ..clear()
      ..addAll(references);
  }

  Map<String, Object> exportSeries() => encodeLocalSeries(_series.values);

  Future<void> _writeSeries(Map<int, LocalBookSeries> next) async {
    if (seriesError != null) throw FormatException(seriesError!);
    final valid = decodeLocalSeries(encodeLocalSeries(next.values));
    if (valid.any((s) => _books.containsKey(s.id))) {
      throw const FormatException('合订本标识与原书冲突，原书已保留');
    }
    final target = File('${directory.path}/series.json');
    final pending = File('${target.path}.next');
    final content = jsonEncode(encodeLocalSeries(valid));
    if (utf8.encode(content).length > 4 * 1024 * 1024) {
      throw const FormatException('本地分卷记录超过 4 MiB，请减少合订本中的章节数量');
    }
    try {
      await pending.writeAsString(content, flush: true);
      await pending.rename(target.path);
    } finally {
      if (await pending.exists()) await pending.delete();
    }
    _series
      ..clear()
      ..addEntries(valid.map((s) => MapEntry(s.id, s)));
    await _refreshSeries();
  }

  /// The caller confirms membership and order. Original files stay untouched.
  Future<Novel> saveSeries({
    int? id,
    required String title,
    required List<({int bookId, String title})> volumes,
  }) async {
    late Novel result;
    final work = _writes.catchError((Object _) {}).then((_) async {
      if (title.trim().isEmpty || title.trim().length > 160) {
        throw const FormatException('合订本书名需要 1～160 个字');
      }
      if (volumes.any(
        (v) => v.title.trim().isEmpty || v.title.trim().length > 160,
      )) {
        throw const FormatException('每卷名称需要 1～160 个字');
      }
      if (volumes.length < 2 ||
          volumes.any((v) => !_books.containsKey(v.bookId))) {
        throw const FormatException('请至少选择两本已导入的分卷');
      }
      if (volumes.map((v) => v.bookId).toSet().length != volumes.length) {
        throw const FormatException('同一分卷不能重复添加');
      }
      for (final volume in volumes) {
        final owner = _series.values
            .where(
              (s) =>
                  !s.deleted && s.volumes.any((v) => v.bookId == volume.bookId),
            )
            .firstOrNull;
        if (owner != null && owner.id != id) {
          throw FormatException(
            '《${_books[volume.bookId]!.title}》已属于《${owner.title}》，请在该书的管理分卷中添加',
          );
        }
      }
      var identity = id;
      final previous = id == null ? null : _series[id];
      if (id != null && (previous == null || previous.deleted)) {
        throw const FormatException('合订本已变化，请返回后重试');
      }
      final random = Random.secure();
      while (identity == null ||
          _books.containsKey(identity) ||
          (id == null && _series.containsKey(identity))) {
        identity = localBookIdStart | random.nextInt(0x20000000);
      }
      var nextChapter = previous?.nextChapterId ?? 1;
      final members = <LocalSeriesVolume>[];
      for (final volume in volumes) {
        final book = _books[volume.bookId]!;
        final old = previous?.volumes
            .where((v) => v.bookId == book.id)
            .firstOrNull;
        final ids =
            old?.chapterIds ??
            List.generate(book.chapters.length, (_) => nextChapter++);
        members.add(
          LocalSeriesVolume(
            bookId: book.id,
            title: volume.title.trim(),
            chapterIds: List.unmodifiable(ids),
          ),
        );
      }
      final first = _books[volumes.first.bookId]!;
      final now = DateTime.now().millisecondsSinceEpoch;
      final changed = LocalBookSeries(
        id: identity,
        title: title.trim(),
        author: previous?.author ?? first.author,
        summary: previous?.summary ?? first.summary,
        volumes: List.unmodifiable(members),
        nextChapterId: nextChapter,
        updatedAt: max(now, (previous?.updatedAt ?? 0) + 1),
      );
      await _writeSeries({..._series, identity: changed});
      result = _seriesBooks[identity]!;
      if (!_disposed) notifyListeners();
    });
    _writes = work;
    await work;
    return result;
  }

  Future<void> dissolveSeries(int id) async {
    final work = _writes.catchError((Object _) {}).then((_) async {
      final series = _series[id];
      if (series == null || series.deleted) return;
      await _writeSeries({
        ..._series,
        id: series.copyWith(
          deleted: true,
          updatedAt: max(
            DateTime.now().millisecondsSinceEpoch,
            series.updatedAt + 1,
          ),
        ),
      });
      if (!_disposed) notifyListeners();
    });
    _writes = work;
    await work;
  }

  Future<void> mergeSeries(Object? raw) async {
    final incoming = decodeLocalSeries(raw);
    final work = _writes.catchError((Object _) {}).then((_) async {
      final next = {..._series};
      for (final series in incoming) {
        final old = next[series.id];
        if (old == null ||
            series.updatedAt > old.updatedAt ||
            (series.updatedAt == old.updatedAt &&
                jsonEncode(
                      series.toJson(),
                    ).compareTo(jsonEncode(old.toJson())) >
                    0)) {
          next[series.id] = series;
        }
      }
      await _writeSeries(next);
      if (!_disposed) notifyListeners();
    });
    _writes = work;
    await work;
  }

  static Map<String, dynamic> validateMetadata(Object? raw) {
    if (raw is! Map || raw.length > 2000) {
      throw const FormatException('本地书籍信息格式有误');
    }
    final result = <String, dynamic>{};
    for (final e in raw.entries) {
      final id = e.key is String ? int.tryParse(e.key) : null, v = e.value;
      if (id == null ||
          !isLocalBook(id) ||
          id > 0x7fffffff ||
          v is! Map ||
          v['title'] is! String ||
          v['title'].trim().isEmpty ||
          v['title'].length > 160 ||
          v['author'] is! String ||
          v['author'].length > 160 ||
          v['summary'] is! String ||
          v['summary'].length > 4000 ||
          v['at'] is! int ||
          v['at'] < 0) {
        throw const FormatException('书名限 160 字，作者限 160 字，简介限 4000 字');
      }
      result['$id'] = {
        'title': v['title'].trim(),
        'author': v['author'].trim(),
        'summary': v['summary'].trim(),
        'at': v['at'],
      };
    }
    return result;
  }

  Map<String, dynamic> exportMetadata() => {
    for (final e in _sources.entries)
      if (e.value['userMetadata'] != null)
        '${e.key}': Map<String, dynamic>.from(e.value['userMetadata']),
  };
  Future<void> _writeMetadata(int id, Map<String, dynamic> value) async {
    final current = _books[id];
    if (current == null) return;
    final changed = Novel.fromSnapshot({
      ...current.toSnapshot(),
      'title': value['title'],
      'author': value['author'],
      'summary': value['summary'],
    }).withChapters(current.chapters);
    final source = {..._sources[id]!, 'userMetadata': value};
    final target = File('${directory.path}/$id/book.json');
    final json =
        jsonDecode(await target.readAsString()) as Map<String, dynamic>;
    json['novel'] = changed.toSnapshot();
    json['source'] = source;
    final next = File('${target.path}.next');
    try {
      await next.writeAsString(jsonEncode(json), flush: true);
      await next.rename(target.path);
    } finally {
      if (await next.exists()) await next.delete();
    }
    _sources[id] = source;
    _books[id] = changed;
  }

  Future<Novel> updateMetadata(
    int id, {
    required String title,
    required String author,
    required String summary,
  }) async {
    late Novel result;
    final work = _writes.catchError((Object _) {}).then((_) async {
      if (!contains(id)) throw const FormatException('本地书籍已不存在');
      final previousAt = (_sources[id]?['userMetadata']?['at'] as int?) ?? 0;
      final now = DateTime.now().millisecondsSinceEpoch;
      final valid = validateMetadata({
        '$id': {
          'title': title,
          'author': author,
          'summary': summary,
          'at': now > previousAt ? now : previousAt + 1,
        },
      });
      if (_seriesBooks.containsKey(id)) {
        final value = valid['$id'];
        await _writeSeries({
          ..._series,
          id: _series[id]!.copyWith(
            title: value['title'],
            author: value['author'],
            summary: value['summary'],
            updatedAt: max(value['at'] as int, _series[id]!.updatedAt + 1),
          ),
        });
      } else {
        await _writeMetadata(id, Map<String, dynamic>.from(valid['$id']));
        await _refreshSeries();
      }
      result = book(id)!;
      if (!_disposed) notifyListeners();
    });
    _writes = work;
    await work;
    return result;
  }

  Future<void> mergeMetadata(Object? metadata) async {
    final valid = validateMetadata(metadata);
    final work = _writes.catchError((Object _) {}).then((_) async {
      for (final e in valid.entries) {
        final id = int.parse(e.key),
            incoming = Map<String, dynamic>.from(e.value);
        if (!contains(id)) continue;
        final previous = _sources[id]?['userMetadata'] as Map?;
        if (previous == null ||
            incoming['at'] > previous['at'] ||
            (incoming['at'] == previous['at'] &&
                jsonEncode(incoming).compareTo(jsonEncode(previous)) > 0)) {
          await _writeMetadata(id, incoming);
        }
      }
      if (!_disposed) notifyListeners();
    });
    _writes = work;
    await work;
  }

  Future<LocalBookInput> original(int id) async {
    final source = _sources[id];
    if (source == null) throw const FormatException('本地原书不存在');
    final folder = '${directory.path}/$id';
    final decoded = File('$folder/decoded.txt');
    return LocalBookInput(
      source['name'],
      await File('$folder/original').readAsBytes(),
      text: await decoded.exists() ? await decoded.readAsString() : null,
    );
  }

  Future<void> remove(int id) async {
    final work = _writes.catchError((Object _) {}).then((_) async {
      final series = _series[id];
      final ids = [id];
      if (series != null && !series.deleted) {
        ids.addAll(series.volumes.map((v) => v.bookId));
        await _writeSeries({
          ..._series,
          id: series.copyWith(
            deleted: true,
            updatedAt: max(
              DateTime.now().millisecondsSinceEpoch,
              series.updatedAt + 1,
            ),
          ),
        });
      } else if (seriesFor(id) != null) {
        throw const FormatException('请先将合订本恢复为独立书籍，再删除单卷');
      }
      for (final value in ids) {
        final folder = Directory('${directory.path}/$value');
        if (await folder.exists()) await folder.delete(recursive: true);
        _books.remove(value);
        _sources.remove(value);
        LocalBookMedia.evict(value);
      }
      await _refreshSeries();
      if (!_disposed) notifyListeners();
    });
    _writes = work;
    await work;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
