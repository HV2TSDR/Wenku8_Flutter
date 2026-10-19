import 'package:flutter/widgets.dart';

// A fixed inline box is not discarded as leading whitespace by SkParagraph's
// justification. One placeholder code unit maps back to zero source characters.
const readerIndentLength = 1;
const readerIndentPlaceholder = '\ufffc';

TextSpan readerParagraphSpan({
  required List<InlineSpan> children,
  required TextStyle style,
  required bool indent,
}) => TextSpan(
  style: style,
  children: [
    if (indent)
      WidgetSpan(
        alignment: PlaceholderAlignment.baseline,
        baseline: TextBaseline.alphabetic,
        child: ExcludeSemantics(
          // Text.rich scales inline widgets with its TextScaler already.
          child: SizedBox(width: (style.fontSize ?? 19) * 2, height: 0),
        ),
      ),
    ...children,
  ],
);

List<PlaceholderDimensions> readerIndentDimensions(bool indent, double font) =>
    [
      if (indent)
        PlaceholderDimensions(
          size: Size(font * 2, 0),
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          baselineOffset: 0,
        ),
    ];
