import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// One cell of a [StaggeredGrid].
///
/// The three states map one-to-one onto the desktop app's
/// `CardStatus = 'col-span-2' | 'col-span-1' | 'hidden'`: [columnSpan] carries
/// the span, [visible] carries `hidden`.
@immutable
class StaggeredGridItem {
  const StaggeredGridItem({
    required this.child,
    this.columnSpan = 1,
    this.visible = true,
  }) : assert(columnSpan >= 1, 'columnSpan must be at least 1');

  /// Convenience for a full-width (2 column) card.
  const StaggeredGridItem.wide({required Widget child, bool visible = true})
    : this(child: child, columnSpan: 2, visible: visible);

  final Widget child;

  /// How many grid columns this card occupies. Clamped to the grid's column
  /// count at layout time, so a 2-span card degrades to full width on a
  /// single-column grid instead of overflowing.
  final int columnSpan;

  /// `false` removes the card from the layout entirely — the desktop's
  /// `hidden` status.
  final bool visible;
}

/// The dashboard grid.
///
/// Cards flow left to right and wrap when the running span would exceed the
/// column count; every card in a row is stretched to the tallest card in that
/// row. That is the same packing FlClash's hand-written `Grid` render object
/// performs, expressed with `IntrinsicHeight` rows so it stays a plain
/// composition and keeps working with intrinsic-height children.
///
/// The last row is *not* stretched to fill: a lone 1-span card stays one column
/// wide, which is what keeps the grid reading as a grid.
class StaggeredGrid extends StatelessWidget {
  const StaggeredGrid({
    super.key,
    required this.items,
    this.crossAxisCount,
    this.spacing = AikoDims.gridSpacing,
    this.runSpacing,
  }) : assert(
         crossAxisCount == null || crossAxisCount > 0,
         'crossAxisCount must be positive',
       );

  final List<StaggeredGridItem> items;

  /// Fixed column count. Defaults to [columnsForWidth] of the available width.
  final int? crossAxisCount;

  /// Gap between columns, and between rows when [runSpacing] is null.
  final double spacing;

  /// Gap between rows. Defaults to [spacing].
  final double? runSpacing;

  /// Column count for a given content width.
  ///
  /// Two columns on a phone is the floor: a 1-span card must read as half a row
  /// next to its neighbour, which is the whole point of the span model. Wider
  /// layouts add columns rather than stretching the cards.
  static int columnsForWidth(double width) {
    if (width >= 1120) return 5;
    if (width >= 880) return 4;
    if (width >= 640) return 3;
    return 2;
  }

  @override
  Widget build(BuildContext context) {
    final visible = items.where((item) => item.visible).toList(growable: false);
    if (visible.isEmpty) return const SizedBox.shrink();

    final double rowGap = runSpacing ?? spacing;

    return LayoutBuilder(
      builder: (context, constraints) {
        final double maxWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : 0;
        final int columns =
            crossAxisCount ??
            (maxWidth > 0 ? columnsForWidth(maxWidth) : 1);

        final double cellWidth = math.max(
          0,
          (maxWidth - (columns - 1) * spacing) / columns,
        );

        final List<List<_PlacedItem>> rows = _pack(visible, columns);

        final List<Widget> rowWidgets = <Widget>[];
        for (var r = 0; r < rows.length; r++) {
          if (r > 0) rowWidgets.add(SizedBox(height: rowGap));
          rowWidgets.add(_buildRow(rows[r], cellWidth));
        }

        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: rowWidgets,
        );
      },
    );
  }

  Widget _buildRow(List<_PlacedItem> row, double cellWidth) {
    final List<Widget> children = <Widget>[];
    for (var i = 0; i < row.length; i++) {
      if (i > 0) children.add(SizedBox(width: spacing));
      final placed = row[i];
      children.add(
        SizedBox(
          width: cellWidth * placed.span + spacing * (placed.span - 1),
          child: placed.item.child,
        ),
      );
    }
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisAlignment: MainAxisAlignment.start,
        children: children,
      ),
    );
  }

  /// Greedy left-to-right packing, identical in behaviour to the FlClash grid:
  /// a card that does not fit in the remaining space starts a new row.
  static List<List<_PlacedItem>> _pack(
    List<StaggeredGridItem> items,
    int columns,
  ) {
    final rows = <List<_PlacedItem>>[];
    var current = <_PlacedItem>[];
    var used = 0;

    for (final item in items) {
      final span = item.columnSpan.clamp(1, columns);
      if (used + span > columns && current.isNotEmpty) {
        rows.add(current);
        current = <_PlacedItem>[];
        used = 0;
      }
      current.add(_PlacedItem(item, span));
      used += span;
    }
    if (current.isNotEmpty) rows.add(current);
    return rows;
  }
}

@immutable
class _PlacedItem {
  const _PlacedItem(this.item, this.span);
  final StaggeredGridItem item;
  final int span;
}
