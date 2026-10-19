import 'package:flutter/material.dart';
import 'library_reflow.dart';

/// Keep a book's cover, metadata and actions together. Wider panes add columns,
/// not wider covers or fixed-height tiles that clip larger text.
abstract final class BookCollectionLayout {
  static const gap = 24.0;
  static int columnsFor(double width) =>
      ((width + gap) / (272 + gap)).floor().clamp(1, 3);
  // Preserve visible books and network prefetch. A wider list must not also
  // multiply its speculative offscreen widget/image work by its column count.
  static double cacheExtentFor(double width, {double base = 500}) =>
      (base / columnsFor(width)).clamp(128.0, base);
}

class BookCollectionSliver extends StatefulWidget {
  const BookCollectionSliver({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
  });
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;

  @override
  State<BookCollectionSliver> createState() => _BookCollectionSliverState();
}

class _BookCollectionSliverState extends State<BookCollectionSliver> {
  Widget? _rows;
  int? _columns;

  @override
  void didUpdateWidget(BookCollectionSliver oldWidget) {
    super.didUpdateWidget(oldWidget);
    _rows = null;
  }

  Widget _item(BuildContext context, int index) {
    final item = widget.itemBuilder(context, index);
    return LibraryReflowPart(relocate: false, order: index, child: item);
  }

  @override
  Widget build(BuildContext context) => SliverLayoutBuilder(
    builder: (context, constraints) {
      final columns = BookCollectionLayout.columnsFor(
        constraints.crossAxisExtent,
      );
      // SliverConstraints include scrollOffset, so this builder is called on
      // every fling frame. Replacing the delegate here rebuilds all mounted
      // book rows, including covers and glass. Only a new data builder or a
      // column-count change needs a new delegate; width still flows to layout.
      if (_rows != null && _columns == columns) return _rows!;
      _columns = columns;
      if (columns == 1) {
        return _rows = SliverList.builder(
          itemCount: widget.itemCount,
          itemBuilder: _item,
        );
      }
      return _rows = SliverList.builder(
        itemCount: (widget.itemCount / columns).ceil(),
        itemBuilder: (context, row) => Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var column = 0; column < columns; column++) ...[
              if (column != 0) const SizedBox(width: BookCollectionLayout.gap),
              Expanded(
                child: row * columns + column < widget.itemCount
                    ? _item(context, row * columns + column)
                    : const SizedBox.shrink(),
              ),
            ],
          ],
        ),
      );
    },
  );
}

/// Full-width headings/featured books, followed by a lazy responsive collection.
class BookCollectionView extends StatelessWidget {
  const BookCollectionView.builder({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.leadingCount = 0,
    this.trailingCount = 0,
    this.padding = EdgeInsets.zero,
    this.physics,
  }) : assert(itemCount >= leadingCount + trailingCount);
  final int itemCount, leadingCount, trailingCount;
  final IndexedWidgetBuilder itemBuilder;
  final EdgeInsets padding;
  final ScrollPhysics? physics;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => CustomScrollView(
      physics: physics,
      clipBehavior: LibraryReflowScope.clipOf(context),
      cacheExtent: BookCollectionLayout.cacheExtentFor(
        constraints.maxWidth - padding.horizontal,
        base: 250,
      ),
      slivers: [
        SliverPadding(
          padding: padding,
          sliver: SliverMainAxisGroup(
            slivers: [
              if (leadingCount > 0)
                SliverList.builder(
                  itemCount: leadingCount,
                  itemBuilder: itemBuilder,
                ),
              BookCollectionSliver(
                itemCount: itemCount - leadingCount - trailingCount,
                itemBuilder: (context, index) =>
                    itemBuilder(context, index + leadingCount),
              ),
              if (trailingCount > 0)
                SliverList.builder(
                  itemCount: trailingCount,
                  itemBuilder: (context, index) =>
                      itemBuilder(context, itemCount - trailingCount + index),
                ),
            ],
          ),
        ),
      ],
    ),
  );
}
