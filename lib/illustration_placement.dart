import 'reader_content.dart';

String _key(String text) => text.replaceAll(RegExp(r'[\s\u3000]+'), '');
String _head(String text, [int length = 160]) =>
    text.substring(0, text.length.clamp(0, length));
String _tail(String text, [int length = 512]) =>
    text.substring((text.length - length).clamp(0, text.length));

/// A confirmed placement is anchored to prose, not an image's ordinal number.
/// Neighbour text disambiguates repeated paragraphs after source updates.
class IllustrationPlacement {
  const IllustrationPlacement({
    required this.id,
    required this.chapterId,
    required this.chapterTitle,
    required this.url,
    required this.head,
    required this.tail,
    required this.before,
    required this.after,
    required this.length,
    required this.updatedAt,
  });
  final String id, chapterTitle, url, head, tail, before, after;
  final int chapterId, length, updatedAt;

  factory IllustrationPlacement.at({
    required int chapterId,
    required String chapterTitle,
    required String url,
    required List<String> paragraphs,
    required int paragraph,
  }) {
    if (paragraph < 0 ||
        paragraph >= paragraphs.length ||
        readerIllustrationUrl(paragraphs[paragraph]) != null) {
      throw const FormatException('请选择正文段落');
    }
    final text = _key(paragraphs[paragraph]);
    if (text.isEmpty) throw const FormatException('请选择有文字的段落');
    final now = DateTime.now().microsecondsSinceEpoch;
    return IllustrationPlacement.fromJson({
      'id': '$chapterId-$now',
      'chapterId': chapterId,
      'chapterTitle': chapterTitle,
      'url': url,
      'head': _head(text),
      'tail': _tail(text),
      'length': text.length,
      'before': paragraph == 0
          ? ''
          : _tail(_key(paragraphs[paragraph - 1]), 96),
      'after': paragraph + 1 == paragraphs.length
          ? ''
          : _head(_key(paragraphs[paragraph + 1]), 96),
      'updatedAt': now,
    });
  }

  Map<String, Object> toJson() => {
    'id': id,
    'chapterId': chapterId,
    'chapterTitle': chapterTitle,
    'url': url,
    'head': head,
    'tail': tail,
    'before': before,
    'after': after,
    'length': length,
    'updatedAt': updatedAt,
  };
  factory IllustrationPlacement.fromJson(Map<String, dynamic> json) {
    bool text(String key, int max) =>
        json[key] is String && (json[key] as String).length <= max;
    if (!text('id', 256) ||
        (json['id'] as String).isEmpty ||
        !text('chapterTitle', 2048) ||
        !text('head', 160) ||
        !text('tail', 512) ||
        !text('before', 96) ||
        !text('after', 96) ||
        json['chapterId'] is! int ||
        json['chapterId'] <= 0 ||
        json['chapterId'] > 0x7fffffff ||
        json['length'] is! int ||
        json['length'] <= 0 ||
        json['length'] > 8000000 ||
        json['updatedAt'] is! int ||
        json['updatedAt'] < 0 ||
        json['url'] is! String ||
        readerIllustrationUrl('<!--image-->${json['url']}<!--image-->') ==
            null ||
        (json['url'] as String).startsWith('wenku-local:')) {
      throw const FormatException('插图排版记录格式有误');
    }
    if ((json['head'] as String).isEmpty || (json['tail'] as String).isEmpty) {
      throw const FormatException('插图段落锚点不能为空');
    }
    return IllustrationPlacement(
      id: json['id'],
      chapterId: json['chapterId'],
      chapterTitle: json['chapterTitle'],
      url: readerIllustrationUrl('<!--image-->${json['url']}<!--image-->')!,
      head: json['head'],
      tail: json['tail'],
      before: json['before'],
      after: json['after'],
      length: json['length'],
      updatedAt: json['updatedAt'],
    );
  }

  int? resolve(List<String> paragraphs) {
    final keys = paragraphs.map(_key).toList();
    final matches = <int>[];
    for (var i = 0; i < keys.length; i++) {
      if (keys[i].length == length &&
          keys[i].startsWith(head) &&
          keys[i].endsWith(tail)) {
        matches.add(i);
      }
    }
    if (matches.length == 1) return matches.single;
    final contextual = matches
        .where(
          (index) =>
              (index == 0 ? '' : _tail(keys[index - 1], 96)) == before &&
              (index + 1 == keys.length ? '' : _head(keys[index + 1], 96)) ==
                  after,
        )
        .toList();
    return contextual.length == 1 ? contextual.single : null;
  }
}

ReaderContent placeIllustrations(
  ReaderContent source,
  Iterable<IllustrationPlacement> placements,
) {
  final paragraphs = [...source.paragraphs];
  final following = <int, List<int>>{};
  final owners = {...source.inlineOwners};
  final ids = {...source.placementIds};
  final present = source.illustrations.toSet();
  for (final placement in placements) {
    if (present.contains(placement.url)) continue;
    final anchor = placement.resolve(source.paragraphs);
    if (anchor == null) continue;
    final index = paragraphs.length;
    paragraphs.add('<!--image-->${placement.url}<!--image-->');
    following.putIfAbsent(anchor, () => []).add(index);
    owners[index] = anchor;
    ids[index] = placement.id;
    present.add(placement.url);
  }
  if (following.isEmpty) return source;
  return ReaderContent(
    List.unmodifiable(paragraphs),
    readingOrder: List.unmodifiable([
      for (final i in source.order) ...[i, ...?following[i]],
    ]),
    inlineOwners: Map.unmodifiable(owners),
    placementIds: Map.unmodifiable(ids),
  );
}
