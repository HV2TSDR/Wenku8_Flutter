import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'app_ui.dart';
import 'catalog.dart';
import 'feature_pages.dart';
import 'illustration_placement.dart';
import 'library_state.dart';
import 'reader_content.dart';
import 'reader_illustrations.dart';

class IllustrationLayoutPage extends StatefulWidget {
  const IllustrationLayoutPage({
    super.key,
    required this.novel,
    required this.chapter,
    required this.state,
    required this.repository,
    this.paragraph,
    this.source,
  });
  final Novel novel;
  final int chapter;
  final LibraryState state;
  final NovelRepository repository;
  final int? paragraph;
  final ReaderContent? source;
  @override
  State<IllustrationLayoutPage> createState() => _IllustrationLayoutPageState();
}

class _IllustrationLayoutPageState extends State<IllustrationLayoutPage> {
  late int? _paragraph = widget.paragraph;
  late Future<List<String>> _images = _load();
  String? _selected, _error;
  bool _saving = false;
  Future<List<String>> _load() async {
    if (_paragraph == null) return const [];
    final volume = NovelVolume.of(widget.novel.chapters).firstWhere(
      (volume) => widget.chapter >= volume.start && widget.chapter < volume.end,
    );
    final images = <String>{};
    for (final chapter in widget.novel.chapters.sublist(
      volume.start,
      volume.end,
    )) {
      if (!RegExp(
        r'插[图畫画絵]|彩页|イラスト|illustration',
        caseSensitive: false,
      ).hasMatch(chapter.title)) {
        continue;
      }
      final content = await ReaderContent.parse(
        await widget.repository.chapterContent(widget.novel.id, chapter),
      );
      images.addAll(content.illustrations);
    }
    return images.toList(growable: false);
  }

  Future<void> _save() async {
    if (_saving ||
        _selected == null ||
        _paragraph == null ||
        widget.source == null) {
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.state.putIllustration(
        widget.novel.id,
        IllustrationPlacement.at(
          chapterId: widget.novel.chapters[widget.chapter].id,
          chapterTitle: widget.novel.chapters[widget.chapter].title,
          url: _selected!,
          paragraphs: widget.source!.paragraphs,
          paragraph: _paragraph!,
        ),
      );
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is FormatException
              ? error.message
              : '插图位置未能保存，请重试',
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _remove(IllustrationPlacement placement) async {
    try {
      await widget.state.removeIllustration(widget.novel.id, placement.id);
    } catch (_) {
      if (mounted) setState(() => _error = '插图位置未能移除，请重试');
    }
  }

  Future<void> _chooseParagraph() async {
    final source = widget.source;
    if (source == null) return;
    final ids = [
      for (var i = 0; i < source.paragraphs.length; i++)
        if (readerIllustrationUrl(source.paragraphs[i]) == null &&
            source.paragraphs[i] != '[插图]')
          i,
    ];
    final selected = await showJellySheet<int>(
      context: context,
      reduceMotion: widget.state.reduceMotion,
      heightFactor: .78,
      builder: (sheet) => ListView.builder(
        padding: const EdgeInsets.all(24),
        itemCount: ids.length,
        itemBuilder: (_, index) => GlassTextButton(
          onPressed: () => Navigator.pop(sheet, ids[index]),
          child: AppText(
            source.paragraphs[ids[index]],
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13, height: 1.65),
          ),
        ),
      ),
    );
    if (mounted && selected != null) {
      setState(() {
        _paragraph = selected;
        _selected = null;
        _images = _load();
      });
    }
  }

  @override
  Widget build(BuildContext context) => ArchiveFeaturePage(
    title: '插图排版',
    code: 'ILLUSTRATIONS / PLACEMENT',
    child: AnimatedBuilder(
      animation: widget.state.illustrationChanges,
      builder: (context, _) {
        final placements = widget.state.illustrationsFor(widget.novel.id);
        return Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: FutureBuilder<List<String>>(
              future: _images,
              builder: (context, snapshot) => ListView(
                padding: featurePadding(context),
                children: [
                  if (widget.source != null)
                    GlassTextButton(
                      onPressed: _saving ? null : _chooseParagraph,
                      child: AppText(_paragraph == null ? '手动修正插图位置' : '更换段落'),
                    ),
                  if (_paragraph != null) ...[
                    const AppText(
                      '放在这个段落之后',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 12),
                    ContentPanel(
                      child: AppText(
                        widget.source!.paragraphs[_paragraph!],
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(height: 1.8),
                      ),
                    ),
                    const SizedBox(height: 18),
                    const AppText(
                      '选择本卷插图',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 12),
                    if (snapshot.connectionState != ConnectionState.done)
                      const SizedBox(
                        height: 220,
                        child: LoadingSkeleton(layout: SkeletonLayout.library),
                      )
                    else if (snapshot.hasError) ...[
                      const AppText('本卷插图暂未读取成功，正文和已保存的位置不受影响。'),
                      GlassTextButton(
                        onPressed: () => setState(() => _images = _load()),
                        child: const AppText('重试读取'),
                      ),
                    ] else if (snapshot.data!.isEmpty)
                      const AppText('本卷没有找到独立插图章节。已有的文内插图会保留原位置。')
                    else ...[
                      GridView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        gridDelegate:
                            const SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: 180,
                              childAspectRatio: .72,
                              crossAxisSpacing: 12,
                              mainAxisSpacing: 12,
                            ),
                        itemCount: snapshot.data!.length,
                        itemBuilder: (context, index) {
                          final url = snapshot.data![index];
                          return Semantics(
                            selected: _selected == url,
                            label: '本卷插图 ${index + 1}',
                            child: GestureDetector(
                              key: ValueKey('illustration-choice-$index'),
                              onTap: _saving
                                  ? null
                                  : () => setState(() => _selected = url),
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  border: Border.all(
                                    color: _selected == url
                                        ? Theme.of(
                                            context,
                                          ).colorScheme.onSurface
                                        : Colors.transparent,
                                    width: 2,
                                  ),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.all(5),
                                  child: IgnorePointer(
                                    child: ReaderIllustration(
                                      url: url,
                                      sizedFrame: true,
                                      onOpen: () {},
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                      const SizedBox(height: 16),
                      GlassTextButton(
                        key: const ValueKey('illustration-confirm-placement'),
                        onPressed: _selected == null || _saving ? null : _save,
                        child: AppText(_saving ? '正在保存…' : '嵌入此段之后'),
                      ),
                    ],
                    const SizedBox(height: 28),
                  ],
                  AppText(
                    '已保存 ${placements.length} 处',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 12),
                  if (placements.isEmpty && _paragraph == null)
                    const AppText(
                      '原文有插图地址时沿用原位置；本机有同版本 EPUB 时，自动用插图前后正文匹配位置。没有可靠位置的独立图集可在这里手动修正。',
                      style: TextStyle(height: 1.8),
                    ),
                  for (final placement in placements)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: ContentPanel(
                        child: Row(
                          children: [
                            const Icon(CupertinoIcons.photo, size: 20),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  AppText(
                                    placement.chapterTitle,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 7),
                                  AppText(
                                    placement.tail,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      height: 1.7,
                                    ),
                                  ),
                                  if (widget.source != null &&
                                      placement.chapterId ==
                                          widget
                                              .novel
                                              .chapters[widget.chapter]
                                              .id &&
                                      placement.resolve(
                                            widget.source!.paragraphs,
                                          ) ==
                                          null)
                                    const AppText(
                                      '原文已变化，需要重新定位',
                                      style: TextStyle(fontSize: 12),
                                    ),
                                ],
                              ),
                            ),
                            GlassIconButton(
                              icon: CupertinoIcons.trash,
                              label: '移除插图位置 ${placement.id}',
                              onPressed: () => _remove(placement),
                            ),
                          ],
                        ),
                      ),
                    ),
                  FeatureError(_error),
                ],
              ),
            ),
          ),
        );
      },
    ),
  );
}
