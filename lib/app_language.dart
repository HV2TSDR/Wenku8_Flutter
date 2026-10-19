import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

enum AppLanguage {
  system('跟随系统', null),
  simplified('简体中文', Locale('zh', 'CN')),
  hongKong('繁體中文 · 香港', Locale('zh', 'HK')),
  taiwan('繁體中文 · 台灣', Locale('zh', 'TW'));

  const AppLanguage(this.label, this.locale);
  final String label;
  final Locale? locale;
  static AppLanguage fromRecord(Object? value) =>
      values.firstWhere((v) => v.name == value, orElse: () => system);
}

Locale chineseLocale(Locale? locale) => Locale(
  'zh',
  locale?.countryCode == 'HK' || locale?.countryCode == 'MO'
      ? 'HK'
      : locale?.countryCode == 'TW' || locale?.scriptCode == 'Hant'
      ? 'TW'
      : 'CN',
);

/// Offline OpenCC dictionary conversion. Text is converted once per bounded
/// cache entry, never in a painter or on a scroll/animation callback.
abstract final class ChineseText {
  static Future<void>? _loading;
  static Map<String, _Lexicon> _lexicons = {};
  static final _cache = <(String, bool, String), String>{};
  static int _cacheUnits = 0;
  static Future<List<String>> readerParagraphs(
    List<String> paragraphs,
    Locale locale,
  ) async {
    final region = chineseLocale(locale).countryCode!;
    if (region == 'CN') return paragraphs;
    final job = (paragraphs: paragraphs, region: region, lexicons: _lexicons);
    if (paragraphs.fold<int>(0, (sum, p) => sum + p.length) > 32 * 1024) {
      return compute(_readerParagraphs, job);
    }
    return _readerParagraphs(job);
  }

  static Future<void> prepare() => _loading ??= () async {
    const names = [
      'STCharacters',
      'STPhrases',
      'TWVariants',
      'HKVariants',
      'TWPhrasesIT',
      'TWPhrasesName',
      'TWPhrasesOther',
    ];
    final sources = await Future.wait(
      names.map((n) => rootBundle.loadString('assets/opencc/$n.txt')),
    );
    _lexicons = await compute(_readLexicons, {
      for (var i = 0; i < names.length; i++) names[i]: sources[i],
    });
  }();

  static String convert(String source, Locale locale, {bool reader = false}) {
    final region = chineseLocale(locale).countryCode!;
    if (region == 'CN' || source.isEmpty || _lexicons.isEmpty) return source;
    final key = (region, reader, source);
    final hit = _cache.remove(key);
    if (hit != null) {
      _cache[key] = hit;
      return hit;
    }
    var text = _lexicons['standard']!.convert(source, preserveOffsets: reader);
    if (region == 'TW' && !reader) text = _lexicons['phrases']!.convert(text);
    text = _lexicons[region]!.convert(text, preserveOffsets: reader);
    if (source.length < 8192) {
      _cache[key] = text;
      _cacheUnits += source.length + text.length;
      while (_cache.length > 2048 || _cacheUnits > 256 * 1024) {
        final oldest = _cache.keys.first;
        _cacheUnits -= oldest.$3.length + _cache.remove(oldest)!.length;
      }
    }
    return text;
  }
}

List<String> _readerParagraphs(
  ({List<String> paragraphs, String region, Map<String, _Lexicon> lexicons})
  job,
) => [
  for (final text in job.paragraphs)
    text.trim() == '[插图]' ||
            text.trimLeft().startsWith('<!--image-->') ||
            job.lexicons.isEmpty
        ? text
        : job.lexicons[job.region]!.convert(
            job.lexicons['standard']!.convert(text, preserveOffsets: true),
            preserveOffsets: true,
          ),
];

class _Lexicon {
  _Lexicon(this.words) {
    for (final key in words.keys) {
      final head = key.codeUnitAt(0);
      if ((_longest[head] ?? 0) < key.length) _longest[head] = key.length;
    }
  }
  final Map<String, String> words;
  final _longest = <int, int>{};
  String convert(String input, {bool preserveOffsets = false}) {
    final out = StringBuffer();
    for (var i = 0; i < input.length;) {
      final bound = (_longest[input.codeUnitAt(i)] ?? 0).clamp(
        0,
        input.length - i,
      );
      String? value;
      var length = bound;
      for (; length > 0; length--) {
        value = words[input.substring(i, i + length)];
        if (value != null && (!preserveOffsets || value.length == length)) {
          break;
        }
        value = null;
      }
      if (value == null) {
        out.writeCharCode(input.codeUnitAt(i++));
      } else {
        out.write(value);
        i += length;
      }
    }
    return out.toString();
  }
}

Map<String, _Lexicon> _readLexicons(Map<String, String> sources) {
  Map<String, String> read(List<String> names) {
    final words = <String, String>{};
    for (final name in names) {
      for (final line in sources[name]!.split('\n')) {
        if (line.isEmpty || line.startsWith('#')) continue;
        final fields = line.trim().split('\t');
        if (fields.length == 2) {
          words.putIfAbsent(fields[0], () => fields[1].split(' ').first);
        }
      }
    }
    return words;
  }

  return {
    'standard': _Lexicon(read(['STPhrases', 'STCharacters'])),
    'TW': _Lexicon(read(['TWVariants'])),
    'HK': _Lexicon(read(['HKVariants'])),
    'phrases': _Lexicon(
      read(['TWPhrasesIT', 'TWPhrasesName', 'TWPhrasesOther']),
    ),
  };
}

String appText(BuildContext context, String value) => ChineseText.convert(
  value,
  Localizations.maybeLocaleOf(context) ?? const Locale('zh', 'CN'),
);

/// All ordinary app labels share the locale; book source data stays unchanged.
class AppText extends StatelessWidget {
  const AppText(
    this.data, {
    super.key,
    this.style,
    this.strutStyle,
    this.textAlign,
    this.textDirection,
    this.locale,
    this.softWrap,
    this.overflow,
    this.textScaler,
    this.maxLines,
    this.semanticsLabel,
    this.textWidthBasis,
    this.textHeightBehavior,
    this.selectionColor,
  });
  final String data;
  final TextStyle? style;
  final StrutStyle? strutStyle;
  final TextAlign? textAlign;
  final TextDirection? textDirection;
  final Locale? locale;
  final bool? softWrap;
  final TextOverflow? overflow;
  final TextScaler? textScaler;
  final int? maxLines;
  final String? semanticsLabel;
  final TextWidthBasis? textWidthBasis;
  final TextHeightBehavior? textHeightBehavior;
  final Color? selectionColor;
  @override
  Widget build(BuildContext context) => Text(
    appText(context, data),
    style: style,
    strutStyle: strutStyle,
    textAlign: textAlign,
    textDirection: textDirection,
    locale: locale,
    softWrap: softWrap,
    overflow: overflow,
    textScaler: textScaler,
    maxLines: maxLines,
    semanticsLabel: semanticsLabel == null
        ? null
        : appText(context, semanticsLabel!),
    textWidthBasis: textWidthBasis,
    textHeightBehavior: textHeightBehavior,
    selectionColor: selectionColor,
  );
}
