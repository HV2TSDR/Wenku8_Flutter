/// A metadata query for the device's known books. Keywords are partial matches;
/// spaces join terms with AND, while # limits a term to tags/classification.
enum BookSearchField {
  all('全部', '书名、作者、标签'),
  title('书名', '只搜索书名'),
  author('作者', '只搜索作者'),
  tags('标签', '如：奇幻、女性视角'),
  id('书籍 ID', '输入完整书籍 ID');

  const BookSearchField(this.label, this.hint);
  final String label, hint;
}

class BookSearch {
  BookSearch(String query, {this.field = BookSearchField.all})
    : terms = [
        for (final part in _width(query).trim().split(RegExp(r'\s+')))
          if (part.isNotEmpty)
            (
              tag: part.startsWith('#'),
              text: _normalize(part.startsWith('#') ? part.substring(1) : part),
            ),
      ];
  final List<({bool tag, String text})> terms;
  final BookSearchField field;

  static String _width(String value) => String.fromCharCodes([
    for (final rune in value.runes)
      if (rune >= 0xff01 && rune <= 0xff5e)
        rune - 0xfee0
      else if (rune == 0x3000)
        0x20
      else
        rune,
  ]);
  static final _spacing = RegExp(r'[\s·・_\-—–，,。.:：()（）\[\]【】「」『』《》]');
  static String _normalize(String value) =>
      _width(value).toLowerCase().replaceAll(_spacing, '');

  bool matches({
    required String title,
    required String author,
    required String tags,
    String summary = '',
    String id = '',
    String classification = '',
  }) {
    if (terms.isEmpty) return true;
    final tagText = _normalize('$tags $classification');
    final fields = switch (field) {
      BookSearchField.title => [_normalize(title)],
      BookSearchField.author => [_normalize(author)],
      BookSearchField.tags => [tagText],
      BookSearchField.id => [id],
      BookSearchField.all => [
        _normalize(title),
        _normalize(author),
        tagText,
        _normalize(summary),
        id,
      ],
    };
    return terms.every(
      (term) =>
          term.text.isNotEmpty &&
          (field == BookSearchField.id
              ? id == term.text
              : term.tag
              ? tagText.contains(term.text)
              : fields.any((field) => field.contains(term.text))),
    );
  }
}
