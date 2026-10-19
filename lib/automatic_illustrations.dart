import 'reader_content.dart';
import 'local_image_layout.dart';
import 'local_book_media.dart';

String _prose(String text) => text.replaceAll(RegExp(r'[\s\u3000]+'), '');

/// Recover positions from a matching edition already on the device. Both sides
/// of an image must uniquely match adjacent prose; image order alone is never
/// position metadata. Original paragraph IDs and source files remain stable.
ReaderContent autoIllustrationsFromReference(
  ReaderContent source,
  ReaderContent reference,
) {
  final paragraphs = [...source.paragraphs];
  final order = source.order.toList();
  final prose = [
    for (final i in source.order)
      if (readerIllustrationUrl(source.paragraphs[i]) == null &&
          source.paragraphs[i] != '[插图]')
        i,
  ];
  final keys = {for (final i in prose) i: _prose(source.paragraphs[i])};
  final owners = {...source.inlineOwners};
  final present = source.illustrations.toSet();
  final after = <int, List<int>>{};
  final ref = reference.order.toList();
  for (var index = 1; index + 1 < ref.length; index++) {
    final paragraph = reference.paragraphs[ref[index]];
    final url = readerIllustrationUrl(paragraph);
    if (url == null ||
        !LocalBookMedia.valid(Uri.parse(url)) ||
        present.contains(url)) {
      continue;
    }
    final size = LocalImageLayout.fromParagraph(paragraph);
    final width = size.width;
    if (width != null &&
        (RegExp(r'^[1234](\.\d+)?(em|rem)$').hasMatch(width) ||
            RegExp(r'^\d+(px)?$').hasMatch(width) &&
                double.parse(width.replaceAll('px', '')) < 80)) {
      continue;
    }
    var before = index - 1, next = index + 1;
    while (before >= 0 &&
        readerIllustrationUrl(reference.paragraphs[ref[before]]) != null) {
      before--;
    }
    while (next < ref.length &&
        readerIllustrationUrl(reference.paragraphs[ref[next]]) != null) {
      next++;
    }
    if (before < 0 || next >= ref.length) continue;
    final a = _prose(reference.paragraphs[ref[before]]),
        b = _prose(reference.paragraphs[ref[next]]);
    final left = a.length <= 64 ? a : a.substring(a.length - 64);
    final right = b.length <= 64 ? b : b.substring(0, 64);
    if (left.length < 16 ||
        right.length < 16 ||
        left.length + right.length < 48) {
      continue;
    }
    final matches = <int>[];
    for (var p = 0; p + 1 < prose.length; p++) {
      if (keys[prose[p]]!.endsWith(left) &&
          keys[prose[p + 1]]!.startsWith(right)) {
        matches.add(prose[p]);
      }
    }
    if (matches.length != 1) continue;
    final anchor = matches.single, image = paragraphs.length;
    paragraphs.add(
      paragraph,
    ); // Preserve EPUB natural sizing, never enlarge notes.
    owners[image] = anchor;
    after.putIfAbsent(anchor, () => []).add(image);
    present.add(url);
  }
  if (after.isEmpty) return source;
  return ReaderContent(
    List.unmodifiable(paragraphs),
    readingOrder: List.unmodifiable([
      for (final i in order) ...[i, ...?after[i]],
    ]),
    inlineOwners: Map.unmodifiable(owners),
    placementIds: source.placementIds,
  );
}
