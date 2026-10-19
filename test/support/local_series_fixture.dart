import 'dart:typed_data';
import '../local_books_test.dart' show epubFixture;

Uint8List seriesEpubFixture(
  int volume, {
  String title = '星海图书馆',
  String author = '青木',
}) => epubFixture(
  overrides: {
    'OPS/book.opf':
        '''<package><metadata><title>$title $volume</title><creator>$author</creator><meta name="cover" content="cover"/></metadata>
      <manifest><item id="a" href="a.xhtml" media-type="application/xhtml+xml"/><item id="b" href="b.xhtml" media-type="application/xhtml+xml"/>
      <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/><item id="cover" href="images/cover.png" media-type="image/png"/></manifest>
      <spine><itemref idref="a"/><itemref idref="b"/></spine></package>''',
    'OPS/a.xhtml':
        '<html><body><p>第 $volume 卷的第一段正文。</p><img src="images/cover.png"/><p>插图后的正文。</p></body></html>',
    'OPS/b.xhtml': '<html><body><p>第 $volume 卷的第二章正文。</p></body></html>',
  },
);
