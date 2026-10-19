import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:tategaki/tategaki.dart'
    show CharacterClassifier, RotationRules, KinsokuProcessor;
import 'reader_content.dart';
import 'reader_text.dart';
import 'reader_preferences.dart';
import 'local_image_layout.dart';

class ReaderTextAnchor {
  const ReaderTextAnchor(this.paragraph, this.offset);
  final int paragraph, offset;
}

class ReaderPageFragment {
  const ReaderPageFragment({
    required this.paragraph,
    required this.start,
    required this.end,
    required this.text,
    required this.rect,
    this.indent = false,
    this.image = false,
  });
  final int paragraph, start, end;
  final String text;
  final Rect rect;
  final bool indent, image;
}

class ReaderVerticalGlyph {
  const ReaderVerticalGlyph({
    required this.text,
    required this.start,
    required this.end,
    required this.paragraph,
    required this.sourceStart,
    required this.sourceEnd,
    required this.rect,
    required this.rotation,
  });
  final String text;
  final int start, end, paragraph, sourceStart, sourceEnd;
  final Rect rect;
  final double rotation;
}

class ReaderLeaf {
  ReaderLeaf(
    List<ReaderPageFragment> fragments, {
    this.text = '',
    List<ReaderVerticalGlyph> glyphs = const [],
  }) : fragments = List.unmodifiable(fragments),
       glyphs = List.unmodifiable(glyphs);
  final List<ReaderPageFragment> fragments;
  final String text;
  final List<ReaderVerticalGlyph> glyphs;
  ReaderTextAnchor get anchor => fragments.isEmpty
      ? const ReaderTextAnchor(0, 0)
      : ReaderTextAnchor(fragments.first.paragraph, fragments.first.start);
}

class ReaderPagination {
  ReaderPagination(this.pages, this.size);
  final List<ReaderLeaf> pages;
  final Size size;
  int pageFor(ReaderTextAnchor anchor) {
    var nearest = 0;
    for (var p = 0; p < pages.length; p++) {
      for (final f in pages[p].fragments) {
        if (f.paragraph == anchor.paragraph &&
            (f.image || anchor.offset >= f.start && anchor.offset < f.end)) {
          return p;
        }
        if (f.paragraph < anchor.paragraph ||
            f.paragraph == anchor.paragraph && f.start <= anchor.offset) {
          nearest = p;
        }
      }
    }
    return nearest;
  }
}

class _HorizontalMetrics {
  _HorizontalMetrics(this.lines, this.starts);
  final List<ui.LineMetrics> lines;
  final List<int> starts;
}

class _VerticalMetrics {
  _VerticalMetrics(this.clusters, this.offsets, this.advances, this.rotations);
  final List<String> clusters;
  final List<int> offsets;
  final List<double> advances, rotations;
}

class _ReaderMeasurements {
  final horizontal = <int, _HorizontalMetrics>{};
  final vertical = <int, _VerticalMetrics>{};
  final glyphs = <String, ({double advance, double rotation})>{};
}

/// A height change re-packs measured lines/columns; it must not shape an entire
/// chapter again. Two typography/width configurations are retained per reader.
class ReaderTextLayoutCache {
  final _layouts = <Object, _ReaderMeasurements>{};
  int paragraphMeasurements = 0;
  _ReaderMeasurements _for(Object key) {
    final cached = _layouts.remove(key);
    if (cached != null) {
      _layouts[key] = cached;
      return cached;
    }
    if (_layouts.length == 2) _layouts.remove(_layouts.keys.first);
    return _layouts[key] = _ReaderMeasurements();
  }
}

/// Actual line/glyph boundaries, not viewport-sized scroll jumps. Only the
/// current chapter is measured, yielding between bounded chunks of work.
Future<ReaderPagination?> paginateReader({
  required ReaderContent content,
  required Size size,
  required TextStyle style,
  required ReaderPreferences preferences,
  required TextScaler scaler,
  required bool Function() current,
  ReaderTextAnchor? pageBreak,
  ReaderTextLayoutCache? cache,
  Map<String, Size> localImageSizes = const {},
}) async {
  final pages = <ReaderLeaf>[];
  var fragments = <ReaderPageFragment>[];
  var glyphs = <ReaderVerticalGlyph>[];
  var pageText = StringBuffer();
  var previousParagraph = -1;
  var y = 0.0;
  var right = size.width;
  final clock = Stopwatch()..start();
  final painter = TextPainter(
    textDirection: TextDirection.ltr,
    textScaler: scaler,
    textAlign: preferences.justify ? TextAlign.justify : TextAlign.start,
  );
  final vertical = preferences.mode == ReaderMode.vertical;
  final font = scaler.scale(style.fontSize ?? 19);
  final columnWidth = font * (style.height ?? 1.72);
  final verticalStyle = style.copyWith(
    fontSize: font,
    height: 1,
    letterSpacing: 0,
  );
  final measured =
      cache?._for((
        content,
        size.width,
        style,
        preferences.mode,
        preferences.indent,
        preferences.justify,
        scaler.scale(style.fontSize ?? 19),
      )) ??
      _ReaderMeasurements();
  final glyphMetrics = measured.glyphs;
  void flush() {
    if (fragments.isEmpty) return;
    pages.add(ReaderLeaf(fragments, text: pageText.toString(), glyphs: glyphs));
    fragments = [];
    glyphs = [];
    pageText = StringBuffer();
    previousParagraph = -1;
    y = 0;
    right = size.width;
  }

  try {
    for (final index in content.order) {
      if (!current()) return null;
      final text = content.paragraphs[index];
      final imageUrl = readerIllustrationUrl(text);
      if (imageUrl?.startsWith('wenku-local:') == true &&
          localImageSizes.containsKey(imageUrl)) {
        final natural = localImageSizes[imageUrl]!;
        final imageSize = LocalImageLayout.fromParagraph(
          text,
        ).resolve(natural: natural, available: size, fontSize: font);
        if (!vertical) {
          if (y + imageSize.height > size.height + .1 && fragments.isNotEmpty) {
            flush();
          }
          fragments.add(
            ReaderPageFragment(
              paragraph: index,
              start: 0,
              end: text.length,
              text: text,
              rect: Rect.fromLTWH(
                (size.width - imageSize.width) / 2,
                y,
                imageSize.width,
                imageSize.height,
              ),
              image: true,
            ),
          );
          y += imageSize.height + preferences.paragraphGap;
        } else {
          final width = math.max(
            math.min(columnWidth, size.width),
            imageSize.width,
          );
          if (right < width - .1 && fragments.isNotEmpty) flush();
          fragments.add(
            ReaderPageFragment(
              paragraph: index,
              start: 0,
              end: text.length,
              text: text,
              rect: Rect.fromLTWH(
                right - width + (width - imageSize.width) / 2,
                0,
                imageSize.width,
                imageSize.height,
              ),
              image: true,
            ),
          );
          right -= width + preferences.paragraphGap;
        }
        continue;
      }
      if (imageUrl != null || text.trim() == '[插图]') {
        flush();
        fragments.add(
          ReaderPageFragment(
            paragraph: index,
            start: 0,
            end: text.length,
            text: text,
            rect: Offset.zero & size,
            image: true,
          ),
        );
        flush();
        continue;
      }
      if (text.isEmpty) continue;
      if (!vertical) {
        final prefix = preferences.indent ? readerIndentPlaceholder : '';
        final display = '$prefix$text';
        var metrics = measured.horizontal[index];
        if (metrics == null) {
          if (cache != null) cache.paragraphMeasurements++;
          painter.text = readerParagraphSpan(
            children: [TextSpan(text: text)],
            style: style,
            indent: preferences.indent,
          );
          painter.setPlaceholderDimensions(
            readerIndentDimensions(preferences.indent, font),
          );
          painter.layout(maxWidth: size.width);
          final lines = painter.computeLineMetrics();
          final starts = <int>[];
          for (final line in lines) {
            final position = painter.getPositionForOffset(
              Offset(0, line.baseline - line.ascent / 2),
            );
            starts.add(painter.getLineBoundary(position).start);
          }
          starts.add(display.length);
          metrics = measured.horizontal[index] = _HorizontalMetrics(
            lines,
            starts,
          );
        }
        final lines = metrics.lines, starts = metrics.starts;
        final breakLine = pageBreak?.paragraph == index
            ? pageBreak!.offset == 0
                  ? 0
                  : starts.indexOf(pageBreak.offset + prefix.length)
            : -1;
        var line = 0;
        while (line < lines.length) {
          if (line == breakLine) flush();
          if (y + lines[line].height > size.height + .1 &&
              fragments.isNotEmpty) {
            flush();
          }
          final first = line;
          var height = 0.0;
          while (line < lines.length &&
              (line == first || line != breakLine) &&
              (height == 0 ||
                  y + height + lines[line].height <= size.height + .1)) {
            height += lines[line++].height;
          }
          final start = (starts[first] - prefix.length).clamp(0, text.length);
          final end = (starts[line] - prefix.length).clamp(start, text.length);
          if (end > start) {
            fragments.add(
              ReaderPageFragment(
                paragraph: index,
                start: start,
                end: end,
                text: text.substring(start, end),
                rect: Rect.fromLTWH(0, y, size.width, height),
                indent: start == 0 && preferences.indent,
              ),
            );
            y += height;
          }
          if (line < lines.length) flush();
        }
        y += preferences.paragraphGap;
      } else {
        var metrics = measured.vertical[index];
        if (metrics == null) {
          if (cache != null) cache.paragraphMeasurements++;
          final clusters = text.characters.toList(growable: false);
          final offsets = <int>[0];
          final advances = <double>[];
          final rotations = <double>[];
          painter.textScaler = TextScaler.noScaling;
          for (final cluster in clusters) {
            offsets.add(offsets.last + cluster.length);
            final metric = glyphMetrics.putIfAbsent(cluster, () {
              final rotation = RotationRules.getRotationAngle(
                cluster,
                CharacterClassifier.classify(cluster),
                true,
              );
              if (rotation == 0) return (advance: font + 1, rotation: rotation);
              painter.text = TextSpan(text: cluster, style: verticalStyle);
              painter.layout();
              return (advance: painter.width + 1, rotation: rotation);
            });
            rotations.add(metric.rotation);
            advances.add(metric.advance);
            if (advances.length % 128 == 0 && clock.elapsedMilliseconds >= 4) {
              await Future<void>.delayed(Duration.zero);
              if (!current()) return null;
              clock.reset();
            }
          }
          metrics = measured.vertical[index] = _VerticalMetrics(
            clusters,
            offsets,
            advances,
            rotations,
          );
        }
        final clusters = metrics.clusters, offsets = metrics.offsets;
        final advances = metrics.advances, rotations = metrics.rotations;
        var first = 0;
        final breakCluster = pageBreak?.paragraph == index
            ? offsets.indexOf(pageBreak!.offset)
            : -1;
        while (first < clusters.length) {
          if (first == breakCluster) flush();
          if (right < columnWidth - .1 && fragments.isNotEmpty) flush();
          final indent = first == 0 && preferences.indent ? font * 2 : 0.0;
          var height = indent;
          var end = first;
          while (end < clusters.length &&
              (end == first || end != breakCluster) &&
              (end == first || height + advances[end] <= size.height)) {
            if (clusters[end] == '\n') {
              end++;
              break;
            }
            height += advances[end++];
          }
          // Backtrack on grapheme boundaries. Never split emoji/combining text.
          if (end < clusters.length &&
              end != breakCluster &&
              clusters[end - 1] != '\n') {
            var adjusted = end;
            while (adjusted > first + 1 &&
                !_canBreakVertical(
                  clusters[adjusted - 1],
                  clusters[adjusted],
                )) {
              adjusted--;
            }
            end = adjusted;
          }
          final sourceStart = offsets[first], sourceEnd = offsets[end];
          if (previousParagraph != -1 && previousParagraph != index) {
            pageText.write('\n\n');
          }
          final pageStart = pageText.length;
          pageText.write(text.substring(sourceStart, sourceEnd));
          previousParagraph = index;
          final width = math.min(columnWidth, size.width);
          final left = right - width;
          final used = advances
              .getRange(first, end)
              .fold(0.0, (sum, value) => sum + value);
          final extra =
              preferences.justify &&
                  end < clusters.length &&
                  end - first > 1 &&
                  clusters[end - 1] != '\n'
              ? math.max(0.0, (size.height - indent - used) / (end - first - 1))
              : 0.0;
          var glyphY = indent;
          for (var c = first; c < end; c++) {
            if (clusters[c] == '\n') continue;
            glyphs.add(
              ReaderVerticalGlyph(
                text: clusters[c],
                start: pageStart + offsets[c] - sourceStart,
                end: pageStart + offsets[c + 1] - sourceStart,
                paragraph: index,
                sourceStart: offsets[c],
                sourceEnd: offsets[c + 1],
                rect: Rect.fromLTWH(
                  left + (width - font) / 2,
                  glyphY,
                  font,
                  advances[c],
                ),
                rotation: rotations[c],
              ),
            );
            glyphY += advances[c] + extra;
          }
          fragments.add(
            ReaderPageFragment(
              paragraph: index,
              start: sourceStart,
              end: sourceEnd,
              text: text.substring(sourceStart, sourceEnd),
              rect: Rect.fromLTWH(left, 0, width, glyphY - extra),
            ),
          );
          right -= width;
          first = end;
          if (clock.elapsedMilliseconds >= 4) {
            await Future<void>.delayed(Duration.zero);
            if (!current()) return null;
            clock.reset();
          }
        }
        right -= preferences.paragraphGap;
        painter.textScaler = scaler;
      }
      if (clock.elapsedMilliseconds >= 4) {
        await Future<void>.delayed(Duration.zero);
        clock.reset();
      }
    }
    flush();
    if (pages.isEmpty) pages.add(ReaderLeaf(const []));
    return current() ? ReaderPagination(List.unmodifiable(pages), size) : null;
  } finally {
    painter.dispose();
  }
}

bool _canBreakVertical(String before, String after) {
  const closing = '，。！？、；：）》」』】〕］｝’”';
  const opening = '（《「『【〔［｛‘“';
  return !closing.contains(after) &&
      !opening.contains(before) &&
      KinsokuProcessor.canBreakAt('$before$after', before.length);
}
