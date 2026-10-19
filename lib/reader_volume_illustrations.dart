import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'app_interactions.dart';
import 'app_ui.dart';
import 'catalog.dart';
import 'feature_pages.dart';
import 'local_image_layout.dart';
import 'reader_content.dart';
import 'reader_illustrations.dart';

class ReaderVolumeIllustrationsPage extends StatefulWidget {
  const ReaderVolumeIllustrationsPage({
    super.key,
    required this.novel,
    required this.chapter,
    required this.repository,
    this.known = const {},
    this.reduceMotion = false,
  });
  final Novel novel;
  final int chapter;
  final NovelRepository repository;
  final Map<int, ReaderContent> known;
  final bool reduceMotion;
  @override
  State<ReaderVolumeIllustrationsPage> createState() =>
      _ReaderVolumeIllustrationsPageState();
}

class _ReaderVolumeIllustrationsPageState
    extends State<ReaderVolumeIllustrationsPage> {
  late final _volume = NovelVolume.of(
    widget.novel.chapters,
  ).firstWhere((v) => widget.chapter >= v.start && widget.chapter < v.end);
  final _imagesByChapter = <int, List<String>>{};
  final _failed = <int>{};
  bool _loading = false;

  // Small EPUB annotation glyphs are not full-page illustrations.
  List<String> _images(ReaderContent content) {
    final result = <String>[];
    for (final index in content.order) {
      final paragraph = content.paragraphs[index];
      final url = readerIllustrationUrl(paragraph);
      if (url != null && !_noteIcon(paragraph)) result.add(url);
    }
    return result;
  }

  bool _noteIcon(String paragraph) {
    final width = LocalImageLayout.fromParagraph(paragraph).width;
    if (width == null) return false;
    final match = RegExp(r'^(\d+(?:\.\d+)?)(em|rem|px|pt)?$').firstMatch(width);
    if (match == null) return false;
    final value = double.parse(match[1]!);
    return switch (match[2]) {
      'em' || 'rem' => value <= 4,
      'pt' => value * 96 / 72 < 80,
      _ => value < 80,
    };
  }

  List<String> get _urls => {
    for (var i = _volume.start; i < _volume.end; i++) ...?_imagesByChapter[i],
  }.toList(growable: false);

  @override
  void initState() {
    super.initState();
    for (final entry in widget.known.entries) {
      if (entry.key >= _volume.start && entry.key < _volume.end) {
        _imagesByChapter[entry.key] = _images(entry.value);
      }
    }
    _load();
  }

  Future<void> _load() async {
    if (_loading) return;
    final pending = [
      for (var i = _volume.start; i < _volume.end; i++)
        if (!_imagesByChapter.containsKey(i)) i,
    ];
    final illustrationTitle = RegExp(
      r'插[图圖畫画絵]|彩[页頁]|イラスト|illustration',
      caseSensitive: false,
    );
    // Dedicated illustration chapters appear immediately; inline images are
    // then gathered from the rest of this volume, never from adjacent volumes.
    pending.sort((a, b) {
      final priorityA =
          illustrationTitle.hasMatch(widget.novel.chapters[a].title) ? 0 : 1;
      final priorityB =
          illustrationTitle.hasMatch(widget.novel.chapters[b].title) ? 0 : 1;
      return priorityA != priorityB ? priorityA - priorityB : a - b;
    });
    setState(() {
      _loading = pending.isNotEmpty;
      _failed.clear();
    });
    var cursor = 0;
    Future<void> next() async {
      while (mounted && cursor < pending.length) {
        final index = pending[cursor++], chapter = widget.novel.chapters[index];
        try {
          final source = chapter.content.isNotEmpty
              ? chapter.content
              : await widget.repository.chapterContent(
                  widget.novel.id,
                  chapter,
                );
          final content = await ReaderContent.parse(source);
          if (!mounted) return;
          setState(() => _imagesByChapter[index] = _images(content));
        } catch (_) {
          if (!mounted) return;
          setState(() => _failed.add(index));
        }
      }
    }

    await Future.wait(List.generate(pending.length.clamp(0, 2), (_) => next()));
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _open(String url) => pushNovelPage<void>(
    context,
    ReaderIllustrationGallery(
      urls: _urls,
      initialUrl: url,
      title: '本卷插图',
      fileNamePrefix: widget.novel.title,
    ),
    reduceMotion: widget.reduceMotion,
  );

  @override
  Widget build(BuildContext context) {
    final images = _urls;
    return ArchiveFeaturePage(
      title: '本卷插图',
      code: 'READER / IMAGES',
      child: CustomScrollView(
        slivers: [
          SliverPadding(
            padding: featurePadding(context).copyWith(bottom: 20),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ArchiveSection(
                    title: _volume.title.isEmpty
                        ? widget.novel.title
                        : _volume.title,
                    code:
                        '${images.length} IMAGES${_loading ? ' / LOADING' : ''}',
                  ),
                  if (_volume.title.isEmpty) ...[
                    const SizedBox(height: 10),
                    const AppText(
                      '本书未分卷，显示全书插图。',
                      style: TextStyle(fontSize: 12),
                    ),
                  ],
                  if (_loading) ...[
                    const SizedBox(height: 10),
                    const AppText('正在整理本卷插图…', style: TextStyle(fontSize: 12)),
                  ],
                  if (_failed.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    AppText(
                      '${_failed.length} 个章节暂未载入${images.isEmpty ? '，可稍后重试' : '，已找到的插图仍可查看'}。',
                      style: const TextStyle(fontSize: 12, height: 1.6),
                    ),
                    GlassTextButton(
                      key: const ValueKey('volume-images-retry'),
                      onPressed: _loading ? null : _load,
                      child: const AppText('重试未载入的章节'),
                    ),
                  ],
                  if (!_loading && images.isEmpty && _failed.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 40),
                      child: AppText('本卷没有找到插图。'),
                    ),
                ],
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            sliver: SliverGrid.builder(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 240,
                childAspectRatio: .72,
                mainAxisSpacing: 16,
                crossAxisSpacing: 16,
              ),
              itemCount: images.isEmpty && _loading ? 4 : images.length,
              itemBuilder: (context, index) => images.isEmpty
                  ? const LoadingSkeleton(layout: SkeletonLayout.cover)
                  : ContentPanel(
                      key: ValueKey('volume-image-${images[index]}'),
                      onTap: () => _open(images[index]),
                      child: ReaderIllustration(
                        url: images[index],
                        fitPage: true,
                        onOpen: () => _open(images[index]),
                      ),
                    ),
            ),
          ),
          SliverToBoxAdapter(
            child: SizedBox(height: MediaQuery.paddingOf(context).bottom + 32),
          ),
        ],
      ),
    );
  }
}
