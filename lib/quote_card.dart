import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';

import 'app_interactions.dart';
import 'app_ui.dart';
import 'feature_pages.dart';
import 'local_platform.dart';

enum QuoteCardStyle { paper, night }

class QuoteCardData {
  const QuoteCardData({
    required this.text,
    required this.book,
    required this.chapter,
    this.author = '',
  });
  final String text, book, author, chapter;
}

/// The preview and PNG use the same laid-out drawing, not a screen capture.
/// Long excerpts paginate into complete cards; neither text nor attribution is
/// silently cropped to fit an arbitrary phone viewport.
class QuoteCardLayout {
  QuoteCardLayout._(this.data, this.style, this.body, this.title, this.source);
  static const width = 480.0;
  final QuoteCardData data;
  final QuoteCardStyle style;
  final TextPainter body, title, source;
  double get height =>
      math.max(530, 160 + body.height + 72 + title.height + source.height + 80);
  Color get background => style == QuoteCardStyle.paper
      ? const Color(0xfff7f5ee)
      : const Color(0xff25272b);
  Color get ink => style == QuoteCardStyle.paper
      ? const Color(0xff303630)
      : const Color(0xfff1eee6);
  Color get muted => style == QuoteCardStyle.paper
      ? const Color(0xff757c72)
      : const Color(0xffa6aea8);

  static List<QuoteCardLayout> prepare(
    QuoteCardData data,
    QuoteCardStyle style,
  ) {
    final ink = style == QuoteCardStyle.paper
        ? const Color(0xff303630)
        : const Color(0xfff1eee6);
    final muted = style == QuoteCardStyle.paper
        ? const Color(0xff757c72)
        : const Color(0xffa6aea8);
    TextPainter text(
      String value,
      double size,
      Color color, {
      double height = 1.7,
      FontWeight weight = FontWeight.w400,
    }) => TextPainter(
      text: TextSpan(
        text: value,
        style: TextStyle(
          fontFamily: 'SourceHanSerifCN',
          fontSize: size,
          height: height,
          color: color,
          fontWeight: weight,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: width - 100);
    var remaining = data.text.trim();
    final result = <QuoteCardLayout>[];
    while (remaining.isNotEmpty) {
      var body = text(remaining, 25, ink, height: 1.85);
      if (body.height > 880) {
        final last = body.computeLineMetrics().lastWhere(
          (line) => line.baseline + line.descent <= 880,
        );
        final boundary = body.getLineBoundary(
          body.getPositionForOffset(Offset(0, last.baseline)),
        );
        final end = boundary.end.clamp(1, remaining.length);
        body.dispose();
        body = text(
          remaining.substring(0, end).trimRight(),
          25,
          ink,
          height: 1.85,
        );
        remaining = remaining.substring(end).trimLeft();
      } else {
        remaining = '';
      }
      result.add(
        QuoteCardLayout._(
          data,
          style,
          body,
          text(
            '《${data.book}》',
            15,
            ink,
            height: 1.65,
            weight: FontWeight.w700,
          ),
          text(
            [
              if (data.author.trim().isNotEmpty) data.author.trim(),
              data.chapter,
            ].where((v) => v.isNotEmpty).join(' · '),
            11.5,
            muted,
          ),
        ),
      );
    }
    return result;
  }

  void paint(
    Canvas canvas,
    Size size, {
    ui.Image? icon,
    bool watermark = true,
    int page = 0,
    int pages = 1,
  }) {
    canvas.save();
    canvas.scale(size.width / width, size.height / height);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, width, height),
      Paint()..color = background,
    );
    final hairline = Paint()
      ..color = muted.withValues(alpha: .20)
      ..strokeWidth = .7;
    canvas.drawLine(const Offset(50, 66), const Offset(430, 66), hairline);
    final label = TextPainter(
      text: TextSpan(
        text: 'READING  /  EXCERPT',
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 9,
          letterSpacing: 2.1,
          color: muted,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    label.paint(canvas, const Offset(50, 39));
    label.dispose();
    final quotation = TextPainter(
      text: TextSpan(
        text: '“',
        style: TextStyle(
          fontFamily: 'SourceHanSerifCN',
          fontSize: 72,
          height: 1,
          color: muted.withValues(alpha: .32),
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    quotation.paint(canvas, const Offset(44, 84));
    quotation.dispose();
    body.paint(canvas, const Offset(50, 160));
    final footer = height - 80 - source.height - title.height;
    canvas.drawLine(
      Offset(50, footer - 26),
      Offset(82, footer - 26),
      Paint()
        ..color = muted.withValues(alpha: .55)
        ..strokeWidth = 1.2,
    );
    title.paint(canvas, Offset(50, footer));
    source.paint(canvas, Offset(50, footer + title.height + 5));
    if (watermark && icon != null) {
      final rect = Rect.fromLTWH(width - 84, height - 57, 30, 30);
      canvas.save();
      canvas.clipRRect(RRect.fromRectAndRadius(rect, const Radius.circular(9)));
      canvas.drawImageRect(
        icon,
        Rect.fromLTWH(0, 0, icon.width.toDouble(), icon.height.toDouble()),
        rect,
        Paint()..filterQuality = FilterQuality.high,
      );
      canvas.restore();
    }
    if (pages > 1) {
      final counter = TextPainter(
        text: TextSpan(
          text: '${page + 1} / $pages',
          style: TextStyle(
            fontFamily: 'monospace',
            fontSize: 9,
            letterSpacing: 1.4,
            color: muted,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      counter.paint(canvas, Offset(50, height - 47));
      counter.dispose();
    }
    canvas.restore();
  }

  Future<Uint8List> png({
    ui.Image? icon,
    bool watermark = true,
    int page = 0,
    int pages = 1,
  }) async {
    const pixels = 1080;
    final pixelHeight = (height * pixels / width).ceil();
    final recorder = ui.PictureRecorder();
    paint(
      Canvas(recorder),
      Size(pixels.toDouble(), pixelHeight.toDouble()),
      icon: icon,
      watermark: watermark,
      page: page,
      pages: pages,
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(pixels, pixelHeight);
    picture.dispose();
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) throw const FormatException('图片生成失败，请重试');
      return bytes.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  }

  void dispose() {
    body.dispose();
    title.dispose();
    source.dispose();
  }
}

class QuoteCardPage extends StatefulWidget {
  const QuoteCardPage({super.key, required this.data});
  final QuoteCardData data;
  @override
  State<QuoteCardPage> createState() => _QuoteCardPageState();
}

class _QuoteCardPageState extends State<QuoteCardPage> {
  QuoteCardStyle _style = QuoteCardStyle.paper;
  late List<QuoteCardLayout> _cards = QuoteCardLayout.prepare(
    widget.data,
    _style,
  );
  int _page = 0;
  bool _watermark = true, _busy = false;
  ui.Image? _icon;
  String? _error;
  @override
  void initState() {
    super.initState();
    _loadIcon();
  }

  Future<void> _loadIcon() async {
    try {
      final bytes = await rootBundle.load('assets/branding/app-icon.png');
      final codec = await ui.instantiateImageCodec(
        bytes.buffer.asUint8List(),
        targetWidth: 96,
      );
      final frame = await codec.getNextFrame();
      codec.dispose();
      if (!mounted) {
        frame.image.dispose();
        return;
      }
      setState(() => _icon = frame.image);
    } catch (_) {
      if (mounted) setState(() => _error = '图标读取失败，请重新打开分享卡片');
    }
  }

  void _changeStyle(QuoteCardStyle value) {
    if (_style == value || _busy) return;
    for (final card in _cards) {
      card.dispose();
    }
    setState(() {
      _style = value;
      _cards = QuoteCardLayout.prepare(widget.data, _style);
    });
  }

  Future<void> _export(bool share) async {
    if (_busy || _cards.isEmpty || (_watermark && _icon == null)) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final bytes = await _cards[_page].png(
        icon: _icon,
        watermark: _watermark,
        page: _page,
        pages: _cards.length,
      );
      if (!mounted) return;
      final name =
          '文库摘录-${DateTime.now().millisecondsSinceEpoch}-${_page + 1}.png';
      if (share) {
        await LocalPlatform.shareImage(bytes, name);
      } else if (await LocalPlatform.exportImage(bytes, name)) {
        if (mounted) showNovelFeedback(context, '摘录图片已保存');
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is FormatException
              ? error.message
              : '图片未能${share ? '分享' : '保存'}，请重试',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _icon?.dispose();
    for (final card in _cards) {
      card.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ArchiveFeaturePage(
    title: '分享摘录',
    code: 'EXCERPT / EDITION',
    child: Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 700),
        child: ListView(
          padding: featurePadding(context),
          children: [
            if (_cards.isNotEmpty)
              SizedBox(
                height: math.min(560, MediaQuery.sizeOf(context).height * .55),
                child: Center(
                  child: AspectRatio(
                    aspectRatio: QuoteCardLayout.width / _cards[_page].height,
                    child: RepaintBoundary(
                      child: CustomPaint(
                        key: const ValueKey('quote-card-preview'),
                        painter: _QuotePainter(
                          _cards[_page],
                          _icon,
                          _watermark,
                          _page,
                          _cards.length,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 22),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                for (final style in QuoteCardStyle.values)
                  GlassTextButton(
                    key: ValueKey('quote-style-${style.name}'),
                    onPressed: _busy ? null : () => _changeStyle(style),
                    child: AppText(
                      '${_style == style ? '✓  ' : ''}${style == QuoteCardStyle.paper ? '雾白' : '夜读'}',
                    ),
                  ),
              ],
            ),
            if (_cards.length > 1)
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  GlassIconButton(
                    icon: CupertinoIcons.chevron_left,
                    label: '上一张摘录',
                    onPressed: _busy || _page == 0
                        ? null
                        : () => setState(() => _page--),
                  ),
                  AppText('${_page + 1} / ${_cards.length}'),
                  GlassIconButton(
                    icon: CupertinoIcons.chevron_right,
                    label: '下一张摘录',
                    onPressed: _busy || _page + 1 == _cards.length
                        ? null
                        : () => setState(() => _page++),
                  ),
                ],
              ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Expanded(child: AppText('图标水印')),
                AppControls.toggle(
                  context,
                  key: const ValueKey('quote-watermark'),
                  value: _watermark,
                  onChanged: _busy
                      ? null
                      : (value) => setState(() => _watermark = value),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              alignment: WrapAlignment.center,
              children: [
                GlassTextButton(
                  key: const ValueKey('quote-save-image'),
                  onPressed: _busy || (_watermark && _icon == null)
                      ? null
                      : () => _export(false),
                  child: AppText(
                    _busy
                        ? '正在生成…'
                        : _cards.length > 1
                        ? '保存此页图片'
                        : '保存图片',
                  ),
                ),
                GlassTextButton(
                  key: const ValueKey('quote-share-image'),
                  onPressed: _busy || (_watermark && _icon == null)
                      ? null
                      : () => _export(true),
                  child: AppText(_cards.length > 1 ? '分享此页' : '分享图片'),
                ),
              ],
            ),
            FeatureError(_error),
          ],
        ),
      ),
    ),
  );
}

class _QuotePainter extends CustomPainter {
  const _QuotePainter(
    this.card,
    this.icon,
    this.watermark,
    this.page,
    this.pages,
  );
  final QuoteCardLayout card;
  final ui.Image? icon;
  final bool watermark;
  final int page, pages;
  @override
  void paint(Canvas canvas, Size size) => card.paint(
    canvas,
    size,
    icon: icon,
    watermark: watermark,
    page: page,
    pages: pages,
  );
  @override
  bool shouldRepaint(_QuotePainter old) =>
      card != old.card ||
      icon != old.icon ||
      watermark != old.watermark ||
      page != old.page;
}
