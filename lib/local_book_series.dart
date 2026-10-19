/// A series refers to durable originals instead of rewriting their EPUBs or
/// illustration URLs. Assigned chapter IDs survive reordering and later imports.
class LocalSeriesVolume {
  const LocalSeriesVolume({
    required this.bookId,
    required this.title,
    required this.chapterIds,
  });
  final int bookId;
  final String title;
  final List<int> chapterIds;
  Map<String, Object> toJson() => {
    'bookId': bookId,
    'title': title,
    'chapterIds': chapterIds,
  };
}

class LocalBookSeries {
  const LocalBookSeries({
    required this.id,
    required this.title,
    required this.author,
    required this.summary,
    required this.volumes,
    required this.nextChapterId,
    required this.updatedAt,
    this.deleted = false,
  });
  final int id, nextChapterId, updatedAt;
  final String title, author, summary;
  final List<LocalSeriesVolume> volumes;
  final bool deleted;
  LocalBookSeries copyWith({
    String? title,
    String? author,
    String? summary,
    List<LocalSeriesVolume>? volumes,
    int? nextChapterId,
    int? updatedAt,
    bool? deleted,
  }) => LocalBookSeries(
    id: id,
    title: title ?? this.title,
    author: author ?? this.author,
    summary: summary ?? this.summary,
    volumes: volumes ?? this.volumes,
    nextChapterId: nextChapterId ?? this.nextChapterId,
    updatedAt: updatedAt ?? this.updatedAt,
    deleted: deleted ?? this.deleted,
  );
  Map<String, Object> toJson() => {
    'id': id,
    'title': title,
    'author': author,
    'summary': summary,
    'volumes': [for (final volume in volumes) volume.toJson()],
    'nextChapterId': nextChapterId,
    'at': updatedAt,
    'deleted': deleted,
  };
}

bool _localId(Object? value) =>
    value is int && value >= 0x60000000 && value <= 0x7fffffff;

Map<String, Object> encodeLocalSeries(Iterable<LocalBookSeries> values) => {
  'version': 1,
  'series': [for (final value in values) value.toJson()],
};

List<LocalBookSeries> decodeLocalSeries(Object? raw) {
  Never bad() => throw const FormatException('分卷信息格式有误，请检查分卷顺序与所属书籍');
  if (raw is! Map ||
      raw['version'] != 1 ||
      raw['series'] is! List ||
      raw['series'].length > 2000) {
    bad();
  }
  final result = <LocalBookSeries>[];
  final identities = <int>{}, owners = <int>{};
  for (final item in raw['series']) {
    if (item is! Map ||
        !_localId(item['id']) ||
        !identities.add(item['id']) ||
        item['title'] is! String ||
        item['title'].trim().isEmpty ||
        item['title'].length > 160 ||
        item['author'] is! String ||
        item['author'].length > 160 ||
        item['summary'] is! String ||
        item['summary'].length > 4000 ||
        item['at'] is! int ||
        item['at'] < 0 ||
        item['nextChapterId'] is! int ||
        item['nextChapterId'] <= 0 ||
        item['nextChapterId'] > 0x7fffffff ||
        item['deleted'] is! bool ||
        item['volumes'] is! List ||
        item['volumes'].length < 2 ||
        item['volumes'].length > 2000) {
      bad();
    }
    final volumes = <LocalSeriesVolume>[];
    final members = <int>{}, chapters = <int>{};
    for (final volume in item['volumes']) {
      if (volume is! Map ||
          !_localId(volume['bookId']) ||
          volume['bookId'] == item['id'] ||
          !members.add(volume['bookId']) ||
          (item['deleted'] == false && !owners.add(volume['bookId'])) ||
          volume['title'] is! String ||
          volume['title'].trim().isEmpty ||
          volume['title'].length > 160 ||
          volume['chapterIds'] is! List ||
          volume['chapterIds'].isEmpty ||
          volume['chapterIds'].length > 100000) {
        bad();
      }
      final ids = <int>[];
      for (final chapter in volume['chapterIds']) {
        if (chapter is! int ||
            chapter <= 0 ||
            chapter >= item['nextChapterId'] ||
            !chapters.add(chapter)) {
          bad();
        }
        ids.add(chapter);
      }
      volumes.add(
        LocalSeriesVolume(
          bookId: volume['bookId'],
          title: volume['title'].trim(),
          chapterIds: List.unmodifiable(ids),
        ),
      );
    }
    if (chapters.length > 100000) bad();
    result.add(
      LocalBookSeries(
        id: item['id'],
        title: item['title'].trim(),
        author: item['author'].trim(),
        summary: item['summary'].trim(),
        volumes: List.unmodifiable(volumes),
        nextChapterId: item['nextChapterId'],
        updatedAt: item['at'],
        deleted: item['deleted'],
      ),
    );
  }
  // A series can only own originals, never another series or itself.
  if (owners.any(identities.contains)) bad();
  return List.unmodifiable(result);
}

class LocalSeriesHint {
  const LocalSeriesHint(this.title, this.number);
  final String title;
  final double number;
  String get key => seriesTitleKey(title);
  String get volumeTitle => number == number.roundToDouble()
      ? '第 ${number.toInt()} 卷'
      : '第 $number 卷';
  Map<String, Object> toJson() => {'title': title, 'number': number};
  static LocalSeriesHint? fromJson(Object? value) =>
      value is Map &&
          value['title'] is String &&
          value['title'].trim().isNotEmpty &&
          value['number'] is num &&
          value['number'].isFinite &&
          value['number'] > 0
      ? LocalSeriesHint(
          value['title'].trim(),
          (value['number'] as num).toDouble(),
        )
      : null;
}

String seriesTitleKey(String title) => title.toLowerCase().replaceAll(
  RegExp(r'[\s._\-—·・:：~～《》「」『』【】\[\]（）()]+'),
  '',
);

String _asciiDigits(String value) => String.fromCharCodes(
  value.runes.map((c) => c >= 0xFF10 && c <= 0xFF19 ? c - 0xFEE0 : c),
);

double? _volumeNumber(String value) {
  final numeric = double.tryParse(value);
  if (numeric != null) return numeric > 0 && numeric < 10000 ? numeric : null;
  const digits = {
    '零': 0,
    '〇': 0,
    '一': 1,
    '二': 2,
    '两': 2,
    '三': 3,
    '四': 4,
    '五': 5,
    '六': 6,
    '七': 7,
    '八': 8,
    '九': 9,
  };
  const units = {'十': 10, '百': 100, '千': 1000};
  var result = 0, digit = 0;
  for (final rune in value.runes) {
    final char = String.fromCharCode(rune);
    if (digits.containsKey(char)) {
      digit = digits[char]!;
    } else if (units.containsKey(char)) {
      result += (digit == 0 ? 1 : digit) * units[char]!;
      digit = 0;
    } else {
      return null;
    }
  }
  return result + digit > 0 ? (result + digit).toDouble() : null;
}

/// Exact series keys plus a volume marker produce suggestions, not a merge.
/// A standalone number such as “86” or “1984” has no inferred series.
LocalSeriesHint? inferLocalSeries(String title) {
  final value = _asciiDigits(
    title,
  ).replaceFirst(RegExp(r'\.(epub|txt)$', caseSensitive: false), '').trim();
  final patterns = [
    RegExp(r'^(.*?)\s*第\s*([零〇一二三四五六七八九十百千两0-9]+)\s*[卷集册冊部](?:\s.*)?$'),
    RegExp(
      r'^(.*?)\s+(?:vol\.?|volume)\s*([0-9]+(?:\.[0-9]+)?)(?:\s.*)?$',
      caseSensitive: false,
    ),
    RegExp(r'^(.*?)[\s._\-（(\[]+([0-9]{1,3})[）)\]]?$'),
  ];
  for (final pattern in patterns) {
    final match = pattern.firstMatch(value);
    if (match == null) continue;
    final name = match[1]!.replaceAll(RegExp(r'[\s._\-—·]+$'), '').trim();
    final number = _volumeNumber(match[2]!);
    if (seriesTitleKey(name).length >= 2 && number != null) {
      return LocalSeriesHint(name, number);
    }
  }
  return null;
}
