import 'package:csslib/parser.dart' as css;
import 'package:csslib/visitor.dart' as ast;
import 'package:html/dom.dart';
import 'local_image_layout.dart';

/// Only image dimensions are carried into the text reader, not a second HTML
/// renderer. csslib and html handle declarations and matching selectors.
Map<Element, LocalImageLayout> epubImageStyles(
  Document document,
  String? Function(String) readStylesheet,
) {
  final images = document.querySelectorAll('img, image');
  final values =
      <Element, Map<String, ({String value, bool important, int specificity})>>{
        for (final image in images)
          image: {
            for (final name in ['width', 'height'])
              if (image.attributes[name] case final value?)
                name: (value: value, important: false, specificity: -1),
          },
      };
  void apply(Element image, ast.DeclarationGroup group, int specificity) {
    for (final declaration in group.declarations.whereType<ast.Declaration>()) {
      final name = declaration.property.toLowerCase();
      if (!['width', 'height', 'max-width', 'max-height'].contains(name)) {
        continue;
      }
      final expression = declaration.expression;
      if (expression == null) continue;
      final printer = ast.CssPrinter();
      expression.visit(printer);
      final value = printer.toString().trim().toLowerCase();
      if ((value != 'auto' &&
          value != 'none' &&
          LocalImageLayout.length(value) == null)) {
        continue;
      }
      final old = values[image]![name];
      if (old != null &&
          (old.important && !declaration.important ||
              old.important == declaration.important &&
                  old.specificity > specificity)) {
        continue;
      }
      values[image]![name] = (
        value: value,
        important: declaration.important,
        specificity: specificity,
      );
    }
  }

  for (final source in document.querySelectorAll(
    'style, link[rel~="stylesheet"]',
  )) {
    final text = source.localName == 'style'
        ? source.text
        : readStylesheet(source.attributes['href'] ?? '');
    if (text == null || text.isEmpty) continue;
    final sheet = css.parse(text);
    for (final rule in sheet.topLevels.whereType<ast.RuleSet>()) {
      for (final selector
          in rule.selectorGroup?.selectors ?? <ast.Selector>[]) {
        final query = selector.span?.text;
        if (query == null) continue;
        final specificity = selector.simpleSelectorSequences.fold<int>(
          0,
          (sum, s) =>
              sum +
              switch (s.simpleSelector) {
                ast.IdSelector() => 1000000,
                ast.ClassSelector() ||
                ast.AttributeSelector() ||
                ast.PseudoClassSelector() => 1000,
                ast.ElementSelector() => 1,
                _ => 0,
              },
        );
        try {
          for (final image
              in document.querySelectorAll(query).where(values.containsKey)) {
            apply(image, rule.declarationGroup, specificity);
          }
        } on FormatException {
          /* An unsupported selector does not discard the chapter. */
        }
      }
    }
  }
  for (final image in images) {
    final inline = image.attributes['style'];
    if (inline == null) continue;
    for (final rule
        in css.parse('img{$inline}').topLevels.whereType<ast.RuleSet>()) {
      apply(image, rule.declarationGroup, 1000000000);
    }
  }
  return {
    for (final image in images)
      image: LocalImageLayout.fromProperties(
        values[image]!.map((key, value) => MapEntry(key, value.value)),
      ),
  };
}
