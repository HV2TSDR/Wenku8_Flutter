import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'app_ui.dart';
import 'app_search_field.dart';
import 'catalog.dart';
import 'glass_choices.dart';

typedef DiscoverySelection = ({NovelSort? sort, Set<String>? tags});

class DiscoveryFilters extends StatefulWidget {
  const DiscoveryFilters({
    super.key,
    required this.sort,
    required this.books,
    this.selectedTags = const {},
    this.availableTags = const [],
  });
  final NovelSort sort;
  final List<Novel> books;
  final Set<String> selectedTags;
  final Iterable<String> availableTags;
  @override
  State<DiscoveryFilters> createState() => _DiscoveryFiltersState();
}

class _DiscoveryFiltersState extends State<DiscoveryFilters> {
  late String mode = widget.selectedTags.isEmpty ? 'sort' : 'tags';
  late final selected = {...widget.selectedTags};
  final query = TextEditingController();
  @override
  void dispose() {
    query.dispose();
    super.dispose();
  }

  void addTags(String value) {
    final tags = value.split(RegExp(r'[\s,，、]+')).where((t) => t.isNotEmpty);
    setState(() {
      selected.addAll(tags);
      query.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final frequency = <String, int>{
      for (final tag in [...widget.availableTags, ...selected]) tag: 0,
    };
    for (final book in widget.books) {
      for (final tag in book.tags) {
        frequency.update(tag, (n) => n + 1, ifAbsent: () => 1);
      }
    }
    final tags =
        frequency.keys
            .where(
              (tag) =>
                  selected.contains(tag) ||
                  tag.toLowerCase().contains(query.text.trim().toLowerCase()),
            )
            .toList()
          ..sort((a, b) {
            final order = frequency[b]!.compareTo(frequency[a]!);
            return order == 0 ? a.compareTo(b) : order;
          });
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const ArchiveSection(title: '分类与排序', code: 'DISCOVER / CATALOGUE'),
          const SizedBox(height: 16),
          AppControls.segments<String>(
            context,
            groupValue: mode,
            children: const {'sort': AppText('榜单'), 'tags': AppText('标签')},
            onValueChanged: (value) {
              if (value != null) setState(() => mode = value);
            },
          ),
          const SizedBox(height: 12),
          if (mode == 'sort')
            GlassChoiceGroup<NovelSort>(
              name: 'discover-sort',
              label: '选择榜单',
              value: widget.sort,
              options: {for (final sort in NovelSort.values) sort: sort.label},
              optionName: (sort) => sort.name,
              onChanged: (sort) => Navigator.pop<DiscoverySelection>(context, (
                sort: sort,
                tags: null,
              )),
            )
          else ...[
            Row(
              children: [
                GlassTextButton(
                  key: const ValueKey('discover-tags-clear'),
                  onPressed: selected.isEmpty
                      ? null
                      : () => setState(selected.clear),
                  child: const AppText('清空'),
                ),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: GlassTextButton(
                      key: const ValueKey('discover-tags-apply'),
                      selected: selected.isNotEmpty,
                      onPressed: () {
                        FocusScope.of(context).unfocus();
                        Navigator.pop<DiscoverySelection>(context, (
                          sort: null,
                          tags: Set.unmodifiable(selected),
                        ));
                      },
                      child: AppText(
                        selected.isEmpty ? '显示全部' : '应用 ${selected.length} 个标签',
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            AppSearchField(
              inputKey: const ValueKey('discover-tag-input'),
              controller: query,
              hint: '搜索或添加标签',
              onChanged: (_) => setState(() {}),
              onSubmitted: addTags,
              trailing: IconButton(
                tooltip: appText(context, '加入标签'),
                icon: const Icon(CupertinoIcons.plus, size: 18),
                onPressed: query.text.trim().isEmpty
                    ? null
                    : () => addTags(query.text),
              ),
            ),
            const SizedBox(height: 14),
            const AppText('同时包含所选标签', style: TextStyle(fontSize: 12)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              children: [
                for (final tag in tags)
                  GlassTextButton(
                    key: ValueKey('discover-tag-$tag'),
                    compact: true,
                    selected: selected.contains(tag),
                    onPressed: () => setState(() {
                      selected.contains(tag)
                          ? selected.remove(tag)
                          : selected.add(tag);
                    }),
                    child: AppText(tag, style: const TextStyle(fontSize: 13)),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
