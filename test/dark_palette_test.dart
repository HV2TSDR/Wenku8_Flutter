import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/reader_preferences.dart';

void main() {
  test(
    'dark appearance uses neutral charcoal, including elevated and glass surfaces',
    () {
      final theme = novelTheme(Brightness.dark);
      final scheme = theme.colorScheme;
      for (final color in [
        theme.scaffoldBackgroundColor,
        scheme.surface,
        scheme.surfaceDim,
        scheme.surfaceBright,
        scheme.surfaceContainerLowest,
        scheme.surfaceContainerLow,
        scheme.surfaceContainer,
        scheme.surfaceContainerHigh,
        scheme.surfaceContainerHighest,
        scheme.onSurface,
        scheme.onSurfaceVariant,
        theme.dividerColor,
        ArchiveDesign.glassTint(Brightness.dark, opacity: .87),
        const ReaderPreferences().background(true),
        const ReaderPreferences(paper: ReaderPaper.night).background(false),
      ]) {
        expect(color.r, closeTo(color.g, 1 / 255));
        expect(color.g, closeTo(color.b, 1 / 255));
      }
      expect(theme.scaffoldBackgroundColor, const Color(0xFF191919));
      expect(scheme.surface, const Color(0xFF242424));
      for (final foreground in [scheme.onSurface, scheme.onSurfaceVariant]) {
        final contrast =
            (foreground.computeLuminance() + .05) /
            (scheme.surfaceContainerHighest.computeLuminance() + .05);
        expect(contrast, greaterThanOrEqualTo(4.5));
      }
    },
  );
}
