import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:wenku8_flutter/book_documents.dart';
import 'package:wenku8_flutter/local_books.dart';
import 'package:wenku8_flutter/reader_content.dart';

List<int> _zip(Map<String, List<int>> files) {
  final archive = Archive();
  for (final entry in files.entries) {
    archive.addFile(ArchiveFile(entry.key, entry.value.length, entry.value));
  }
  return ZipEncoder().encode(archive);
}

List<int> _pdf({bool jpeg2000 = false}) {
  String stream(String body) =>
      '<< /Length ${ascii.encode(body).length} >>\nstream\n${body}endstream';
  final objects = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R 6 0 R] /Count 2 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] /Resources << /Font << /F1 4 0 R >> ${jpeg2000 ? '/XObject << /Image1 8 0 R >>' : ''} >> /Contents 5 0 R >>',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
    stream('BT /F1 18 Tf 30 300 Td (Example story text.) Tj ET\n'),
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] /Resources << >> /Contents 7 0 R >>',
    stream('0.5 g 30 30 200 300 re f\n'),
    if (jpeg2000)
      '<< /Type /XObject /Subtype /Image /Width 1 /Height 1 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /JPXDecode /Length 1 >>\nstream\nx\nendstream',
  ];
  var source = '%PDF-1.4\n';
  final offsets = <int>[0];
  for (final (i, object) in objects.indexed) {
    offsets.add(source.length);
    source += '${i + 1} 0 obj\n$object\nendobj\n';
  }
  final xref = source.length;
  source += 'xref\n0 ${offsets.length}\n0000000000 65535 f \n';
  source += offsets
      .skip(1)
      .map((n) => '${n.toString().padLeft(10, '0')} 00000 n \n')
      .join();
  source +=
      'trailer\n<< /Size ${offsets.length} /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n';
  return ascii.encode(source);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native document converters import complete readable books and images', (
    tester,
  ) async {
    final cache = await getTemporaryDirectory();
    final staging = await Directory(
      '${cache.path}/book-documents',
    ).create(recursive: true);
    final root = await cache.createTemp('document-fixtures-');
    final books = LocalBookStore(Directory('${root.path}/books'));
    addTearDown(books.dispose);
    addTearDown(() => root.delete(recursive: true));
    await books.load();
    final docs = BookDocuments();
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a6i0AAAAASUVORK5CYII=',
    );
    final files = <String, List<int>>{
      '中文小说.fb2': utf8.encode(
        '<FictionBook xmlns:l="http://www.w3.org/1999/xlink"><description><title-info><book-title>中文小说</book-title></title-info></description><body><section><title><p>第一章</p></title><p>图前中文。</p><image l:href="#picture"/><p>图后中文。</p></section></body><binary id="picture" content-type="image/png">${base64Encode(png)}</binary></FictionBook>',
      ),
      '文档.docx': _zip({
        'word/_rels/document.xml.rels': utf8.encode(
          '<Relationships><Relationship Id="image1" Target="media/pic.png"/></Relationships>',
        ),
        'word/document.xml': utf8.encode(
          '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:a="a" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><w:body><w:p><w:r><w:t>图前中文。</w:t><a:blip r:embed="image1"/><w:t>图后中文。</w:t></w:r></w:p></w:body></w:document>',
        ),
        'word/media/pic.png': png,
      }),
      '网页.html': utf8.encode(
        '<html><head><meta charset="UTF-8"/></head><body><h1>第一章</h1><p>图前中文。</p><img src="data:image/png;base64,${base64Encode(png)}"/><p>图后中文。</p></body></html>',
      ),
      '文章.md': utf8.encode('# 第一章\n\n**图前中文。**\n\n图后中文。'),
      '文章.rtf': ascii.encode(
        r'{\rtf1\ansi\uc1\u20013?\u25991?\par Continued reading.}',
      ),
      '文档.pdf': _pdf(),
    };
    for (final entry in files.entries) {
      final source = await File(
        '${staging.path}/import-fixture.source',
      ).writeAsBytes(entry.value);
      final selected = BookDocumentSelection(
        name: entry.key,
        path: source.path,
      );
      final prepared = await docs.prepareBook(selected);
      expect(prepared.single.error, isNull, reason: entry.key);
      final book = await books.importFile(
        prepared.single.name,
        prepared.single.path!,
      );
      final bodies = <String>[];
      for (final chapter in book.chapters) {
        bodies.add(await books.chapterContent(book.id, chapter));
      }
      expect(bodies.join(), isNotEmpty);
      if (entry.key.endsWith('.pdf')) {
        expect(bodies.first, contains('Example story text.'));
        expect(
          ReaderContent(bodies.last.split('\n\n')).illustrations,
          isNotEmpty,
        );
      } else if (!entry.key.endsWith('.rtf')) {
        expect(bodies.join(), contains('图前中文。'));
        expect(bodies.join(), contains('图后中文。'));
      } else {
        expect(bodies.join(), contains('中文'));
      }
      if (['fb2', 'docx', 'html'].contains(entry.key.split('.').last)) {
        expect(
          ReaderContent(bodies.join('\n\n').split('\n\n')).illustrations.length,
          1,
        );
      }
      await docs.releaseBooks([selected, ...prepared]);
      // ignore: avoid_print
      print(
        'DOCUMENT_FORMAT_OK ${entry.key.split('.').last} chapters=${book.chapters.length}',
      );
    }
    final source = await File(
      '${staging.path}/import-jpx-fixture.source',
    ).writeAsBytes(_pdf(jpeg2000: true));
    final rejected = await docs.prepareBook(
      BookDocumentSelection(name: '不支持的图片.pdf', path: source.path),
    );
    expect(rejected.single.path, isNull);
    expect(rejected.single.error, contains('JPEG2000'));
    await docs.releaseBooks([
      BookDocumentSelection(name: '不支持的图片.pdf', path: source.path),
    ]);
  });
  testWidgets(
    'native streaming decoder and import accept a TXT larger than 60 MiB',
    (tester) async {
      final cache = await getTemporaryDirectory();
      final staging = await Directory(
        '${cache.path}/book-documents',
      ).create(recursive: true);
      final source = File('${staging.path}/import-large-fixture.source');
      final output = source.openWrite();
      const block = '这是一段完整的正文。\n';
      final bytes = utf8.encode(block * 2048);
      final count = (61 * 1024 * 1024 / bytes.length).ceil();
      for (var i = 0; i < count; i++) {
        output.add(bytes);
        if (i % 32 == 0) await output.flush();
      }
      output.add(utf8.encode('最后一段。'));
      await output.close();
      final root = await cache.createTemp('large-document-');
      final books = LocalBookStore(root);
      await books.load();
      addTearDown(books.dispose);
      addTearDown(() => root.delete(recursive: true));
      final docs = BookDocuments();
      var beats = 0;
      final clock = Stopwatch()..start();
      final heartbeat = Timer.periodic(
        const Duration(milliseconds: 16),
        (_) => beats++,
      );
      String? decoded;
      try {
        decoded = await docs.decodeTextFile(source.path);
        final book = await books.importFile(
          '大书.txt',
          source.path,
          decodedPath: decoded,
        );
        expect(book.chapters.length, greaterThan(100));
        expect(
          await books.chapterContent(book.id, book.chapters.last),
          endsWith('最后一段。'),
        );
        expect(await source.length(), greaterThan(60 * 1024 * 1024));
        expect(beats, greaterThan(0));
        // ignore: avoid_print
        print(
          'NATIVE_LARGE_TXT_OK bytes=${await source.length()} chapters=${book.chapters.length} ms=${clock.elapsedMilliseconds} uiHeartbeats=$beats',
        );
      } finally {
        heartbeat.cancel();
        await docs.releaseBooks([
          BookDocumentSelection(name: '大书.txt', path: source.path),
          if (decoded != null)
            BookDocumentSelection(name: 'decoded.txt', path: decoded),
        ]);
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
