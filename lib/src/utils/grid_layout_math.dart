/// Pure geometry for the two preview grids.
///
/// Deliberately free of any Flutter import so it can be unit-tested and
/// benchmarked directly. Everything here is a pure function of the item data and
/// the grid configuration, which is exactly the property the sliding-window
/// scroll cache needs: to remove a prefix without anything visibly moving, the
/// extent of that prefix has to be computable without consulting live render
/// objects.
///
/// The formulas mirror, and are golden-tested against, Flutter's
/// `SliverGridDelegateWithFixedCrossAxisCount` and `waterfall_flow`'s
/// `_CrossAxisChildrenData.insert`.
library;

import 'dart:math';

/// Width of a single column.
///
/// Identical in Flutter's fixed grid delegate and in `waterfall_flow`'s
/// `getChildUsableCrossAxisExtent`.
double tileCrossAxisExtent({
  required double crossAxisExtent,
  required int columnCount,
  required double crossAxisSpacing,
}) {
  final double usable = max(0, crossAxisExtent - crossAxisSpacing * (columnCount - 1));
  return usable / columnCount;
}

/// Height of one staggered tile.
///
/// Mirrors the height calculation in `staggered_builder.dart`. [tileWidth] is
/// the **column** width, i.e. the `LayoutBuilder` constraint inside a cell, not
/// the viewport width -- confusing the two silently miscomputes every extent.
double staggeredTileHeight({
  required double tileWidth,
  required double? fileWidth,
  required double? fileHeight,
}) {
  final double tileMaxHeight = tileWidth * (16 / 9);

  double height = tileWidth;
  if (fileWidth != null && fileHeight != null && fileHeight != 0) {
    final double aspectRatio = fileWidth / fileHeight;
    if (aspectRatio != 0) {
      height = tileWidth / aspectRatio;
    }
  }

  return max(min(tileMaxHeight, height), 100);
}

/// Main-axis size of one fixed-grid tile.
double fixedGridChildMainAxisExtent({
  required double crossAxisExtent,
  required int columnCount,
  required double crossAxisSpacing,
  required double childAspectRatio,
}) {
  final double childCrossAxisExtent = tileCrossAxisExtent(
    crossAxisExtent: crossAxisExtent,
    columnCount: columnCount,
    crossAxisSpacing: crossAxisSpacing,
  );
  return childCrossAxisExtent / childAspectRatio;
}

/// Distance from the top of one fixed-grid row to the top of the next.
double fixedGridMainAxisStride({
  required double crossAxisExtent,
  required int columnCount,
  required double crossAxisSpacing,
  required double mainAxisSpacing,
  required double childAspectRatio,
}) {
  return fixedGridChildMainAxisExtent(
        crossAxisExtent: crossAxisExtent,
        columnCount: columnCount,
        crossAxisSpacing: crossAxisSpacing,
        childAspectRatio: childAspectRatio,
      ) +
      mainAxisSpacing;
}

/// Total scroll extent of a fixed grid holding [itemCount] items.
///
/// Matches `SliverGridRegularTileLayout.computeMaxScrollOffset`.
double fixedGridMaxScrollOffset({
  required int itemCount,
  required double crossAxisExtent,
  required int columnCount,
  required double crossAxisSpacing,
  required double mainAxisSpacing,
  required double childAspectRatio,
}) {
  if (itemCount <= 0) {
    return 0;
  }
  final double stride = fixedGridMainAxisStride(
    crossAxisExtent: crossAxisExtent,
    columnCount: columnCount,
    crossAxisSpacing: crossAxisSpacing,
    mainAxisSpacing: mainAxisSpacing,
    childAspectRatio: childAspectRatio,
  );
  final int rows = (itemCount / columnCount).ceil();
  return stride * rows - mainAxisSpacing;
}

/// Scroll extent freed by removing the first [removedCount] items of a fixed
/// grid.
///
/// [removedCount] **must** be a whole number of rows, otherwise the surviving
/// items shift sideways and no single offset correction can hide it.
double fixedGridRemovedExtent({
  required int removedCount,
  required double crossAxisExtent,
  required int columnCount,
  required double crossAxisSpacing,
  required double mainAxisSpacing,
  required double childAspectRatio,
}) {
  assert(
    removedCount % columnCount == 0,
    'removedCount must be a whole number of rows',
  );
  if (removedCount <= 0) {
    return 0;
  }
  return (removedCount ~/ columnCount) *
      fixedGridMainAxisStride(
        crossAxisExtent: crossAxisExtent,
        columnCount: columnCount,
        crossAxisSpacing: crossAxisSpacing,
        mainAxisSpacing: mainAxisSpacing,
        childAspectRatio: childAspectRatio,
      );
}

/// Resolved masonry geometry: where every item sits, and how tall the whole
/// thing is.
class MasonryLayoutData {
  const MasonryLayoutData({
    required this.tops,
    required this.heights,
    required this.columns,
    required this.maxBottomPrefix,
    required this.columnTrailing,
    required this.columnCount,
    required this.mainAxisSpacing,
    required this.maxScrollExtent,
  });

  /// Main-axis offset of each item.
  final List<double> tops;
  final List<double> heights;

  /// Column each item was packed into.
  final List<int> columns;

  /// Running maximum of item bottoms. Non-decreasing, so it is binary
  /// searchable.
  final List<double> maxBottomPrefix;

  /// Trailing offset of each column once every item is placed. `null` means the
  /// column never received an item.
  final List<double?> columnTrailing;

  final int columnCount;
  final double mainAxisSpacing;
  final double maxScrollExtent;

  int get itemCount => tops.length;

  /// Trailing offsets of each column after laying out only the first [count]
  /// items.
  List<double?> columnTrailingAfter(int count) {
    final List<double?> trailing = List<double?>.filled(columnCount, null);
    final int limit = min(count, itemCount);
    for (int i = 0; i < limit; i++) {
      trailing[columns[i]] = tops[i] + heights[i];
    }
    return trailing;
  }

  /// Lowest index whose bottom edge is past [offset], i.e. the first item that
  /// could still be on screen.
  int firstIndexAtOrAfter(double offset) {
    int low = 0;
    int high = itemCount;
    while (low < high) {
      final int mid = (low + high) >> 1;
      if (maxBottomPrefix[mid] > offset) {
        high = mid;
      } else {
        low = mid + 1;
      }
    }
    return low;
  }
}

/// Packs [heights] into [columnCount] columns, shortest-column-first.
///
/// Transcribed from `waterfall_flow`'s `_CrossAxisChildrenData.insert`: the
/// first [columnCount] items seed columns 0..n-1 at offset 0, and every item
/// after that goes below the column with the smallest trailing offset, ties
/// broken by the lowest column index.
///
/// [baseColumnOffsets] seeds the columns with a pre-existing ragged frontier.
/// This is what makes prefix removal free of reflow: feed the survivors the
/// frontier left behind by the evicted items and every one of them keeps its
/// original column and relative position.
MasonryLayoutData computeMasonryLayout({
  required List<double> heights,
  required int columnCount,
  required double mainAxisSpacing,
  List<double>? baseColumnOffsets,
}) {
  assert(columnCount > 0, 'columnCount must be positive');
  assert(
    baseColumnOffsets == null || baseColumnOffsets.length == columnCount,
    'baseColumnOffsets must have one entry per column',
  );

  final int count = heights.length;
  final List<double> tops = List<double>.filled(count, 0);
  final List<int> columns = List<int>.filled(count, 0);
  final List<double> maxBottomPrefix = List<double>.filled(count, 0);

  final List<double?> trailing = baseColumnOffsets == null
      ? List<double?>.filled(columnCount, null)
      : List<double?>.of(baseColumnOffsets);

  int filled = baseColumnOffsets == null ? 0 : columnCount;
  double runningMaxBottom = 0;

  for (int i = 0; i < count; i++) {
    int column;
    double top;

    if (filled < columnCount) {
      // Seeding phase: waterfall_flow places the first n children at offset 0,
      // one per column, in order.
      column = filled;
      top = 0;
      filled++;
    } else {
      column = 0;
      double best = trailing[0]!;
      for (int c = 1; c < columnCount; c++) {
        final double candidate = trailing[c]!;
        // Strict less-than keeps the lowest index on a tie, matching the
        // package's reduce().
        if (candidate < best) {
          best = candidate;
          column = c;
        }
      }
      top = best + mainAxisSpacing;
    }

    final double height = heights[i];
    tops[i] = top;
    columns[i] = column;
    trailing[column] = top + height;

    final double bottom = top + height;
    if (bottom > runningMaxBottom) {
      runningMaxBottom = bottom;
    }
    maxBottomPrefix[i] = runningMaxBottom;
  }

  double maxScrollExtent = 0;
  for (final double? value in trailing) {
    if (value != null && value > maxScrollExtent) {
      maxScrollExtent = value;
    }
  }

  return MasonryLayoutData(
    tops: tops,
    heights: List<double>.of(heights),
    columns: columns,
    maxBottomPrefix: maxBottomPrefix,
    columnTrailing: trailing,
    columnCount: columnCount,
    mainAxisSpacing: mainAxisSpacing,
    maxScrollExtent: maxScrollExtent,
  );
}

/// How far to shift the scroll offset after dropping the first [removeCount]
/// items, plus the column frontier the survivors must be re-seeded with.
///
/// Let `T_c` be column *c*'s trailing offset once the removed prefix is laid
/// out, and `d = min_c T_c`. Re-laying the survivors with
/// `baseColumnOffsets[c] = T_c - d` leaves every survivor in the same column
/// with its top reduced by exactly `d`. So the whole list shifts up by `d` and
/// nothing reflows.
///
/// Returns a null [MasonryTrimResult.baseColumnOffsets] when the prefix does not
/// yet occupy every column, in which case no exact compensation exists and the
/// caller should not trim.
MasonryTrimResult masonryTrimResult(MasonryLayoutData layout, int removeCount) {
  if (removeCount <= 0 || removeCount >= layout.itemCount) {
    return const MasonryTrimResult(scrollDelta: 0, baseColumnOffsets: null);
  }

  final List<double?> trailing = layout.columnTrailingAfter(removeCount);
  double? delta;
  for (final double? value in trailing) {
    if (value == null) {
      return const MasonryTrimResult(scrollDelta: 0, baseColumnOffsets: null);
    }
    if (delta == null || value < delta) {
      delta = value;
    }
  }
  if (delta == null) {
    return const MasonryTrimResult(scrollDelta: 0, baseColumnOffsets: null);
  }

  return MasonryTrimResult(
    scrollDelta: delta,
    baseColumnOffsets: <double>[
      for (final double? value in trailing) value! - delta,
    ],
  );
}

class MasonryTrimResult {
  const MasonryTrimResult({
    required this.scrollDelta,
    required this.baseColumnOffsets,
  });

  final double scrollDelta;
  final List<double>? baseColumnOffsets;

  bool get canCompensate => baseColumnOffsets != null;
}
