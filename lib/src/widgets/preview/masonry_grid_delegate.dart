import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'package:lolisnatcher/src/utils/grid_layout_math.dart';

/// Aspect data for one tile, as read off a `BooruItem`.
typedef MasonryTileAspect = ({double? width, double? height});

/// A masonry [SliverGridLayout] whose geometry is a pure function of the item
/// index.
///
/// This replaces `SliverWaterfallFlow`, which keeps `_previousCrossAxisChildrenData`
/// across frames and only discards it at index 0 or on a geometry change. That
/// carried state means the offset of a given index is history-dependent, so
/// removing a prefix leaves the leading children pinned at stale offsets. Being
/// index-pure is what lets the sliding-window cache drop items and correct the
/// scroll offset exactly.
class MasonrySliverGridLayout extends SliverGridLayout {
  const MasonrySliverGridLayout({
    required this.data,
    required this.tileCrossAxisExtent,
    required this.crossAxisSpacing,
    required this.reverseCrossAxis,
  });

  final MasonryLayoutData data;
  final double tileCrossAxisExtent;
  final double crossAxisSpacing;
  final bool reverseCrossAxis;

  double _crossAxisOffsetFor(int column) {
    final int actual = (reverseCrossAxis && data.columnCount > 1) ? data.columnCount - 1 - column : column;
    return actual * (tileCrossAxisExtent + crossAxisSpacing);
  }

  @override
  int getMinChildIndexForScrollOffset(double scrollOffset) {
    if (data.itemCount == 0) {
      return 0;
    }
    // maxBottomPrefix is a running maximum, so everything before this index is
    // entirely above the offset regardless of which column it sits in.
    return data.firstIndexAtOrAfter(scrollOffset).clamp(0, data.itemCount - 1);
  }

  @override
  int getMaxChildIndexForScrollOffset(double scrollOffset) {
    if (data.itemCount == 0) {
      return 0;
    }
    // `tops` is non-decreasing (the shortest-column frontier only ever rises),
    // so the last item starting at or before the offset is a binary search.
    int low = 0;
    int high = data.itemCount - 1;
    int result = 0;
    while (low <= high) {
      final int mid = (low + high) >> 1;
      if (data.tops[mid] <= scrollOffset) {
        result = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return result;
  }

  @override
  SliverGridGeometry getGeometryForChildIndex(int index) {
    if (index < 0 || index >= data.itemCount) {
      return SliverGridGeometry(
        scrollOffset: index <= 0 ? 0 : data.maxScrollExtent,
        crossAxisOffset: 0,
        mainAxisExtent: 0,
        crossAxisExtent: tileCrossAxisExtent,
      );
    }
    return SliverGridGeometry(
      scrollOffset: data.tops[index],
      crossAxisOffset: _crossAxisOffsetFor(data.columns[index]),
      mainAxisExtent: data.heights[index],
      crossAxisExtent: tileCrossAxisExtent,
    );
  }

  @override
  double computeMaxScrollOffset(int childCount) {
    if (childCount <= 0 || data.itemCount == 0) {
      return 0;
    }
    if (childCount >= data.itemCount) {
      return data.maxScrollExtent;
    }
    return data.maxBottomPrefix[childCount - 1];
  }
}

/// Single-entry memo for the resolved layout.
///
/// [SliverGridDelegate.getLayout] runs on every `performLayout`, i.e. every
/// scroll frame, so packing thousands of tiles there would be far worse than the
/// problem being fixed. Only one grid is on screen at a time, so one slot is
/// enough: scrolling hits it every time, and only an append, a trim or a
/// geometry change misses.
class _MasonryLayoutMemo {
  static Object? _key;
  static MasonryLayoutData? _value;

  /// Extent of the most recently resolved layout.
  static double get lastExtent => _value?.maxScrollExtent ?? 0;

  static MasonryLayoutData resolve({
    required Object key,
    required MasonryLayoutData Function() build,
  }) {
    if (_value != null && _key == key) {
      return _value!;
    }
    final MasonryLayoutData built = build();
    _key = key;
    _value = built;
    return built;
  }
}

class MasonrySliverGridDelegate extends SliverGridDelegate {
  const MasonrySliverGridDelegate({
    required this.aspects,
    required this.listToken,
    required this.columnCount,
    required this.mainAxisSpacing,
    required this.crossAxisSpacing,
    this.baseColumnOffsets,
  });

  final List<MasonryTileAspect> aspects;

  /// Identifies the backing list. Any change to it must change this token, or a
  /// stale layout will be reused.
  final Object listToken;

  final int columnCount;
  final double mainAxisSpacing;
  final double crossAxisSpacing;

  /// Column frontier inherited from items the sliding window already evicted.
  final List<double>? baseColumnOffsets;

  MasonryLayoutData resolveData(double crossAxisExtent, {bool reverseCrossAxis = false}) {
    final double tileWidth = tileCrossAxisExtent(
      crossAxisExtent: crossAxisExtent,
      columnCount: columnCount,
      crossAxisSpacing: crossAxisSpacing,
    );

    final Object key = Object.hash(
      listToken,
      crossAxisExtent,
      columnCount,
      mainAxisSpacing,
      crossAxisSpacing,
      baseColumnOffsets == null ? 0 : Object.hashAll(baseColumnOffsets!),
    );

    return _MasonryLayoutMemo.resolve(
      key: key,
      build: () => computeMasonryLayout(
        heights: <double>[
          for (final MasonryTileAspect aspect in aspects)
            staggeredTileHeight(
              tileWidth: tileWidth,
              fileWidth: aspect.width,
              fileHeight: aspect.height,
            ),
        ],
        columnCount: columnCount,
        mainAxisSpacing: mainAxisSpacing,
        baseColumnOffsets: baseColumnOffsets,
      ),
    );
  }

  @override
  SliverGridLayout getLayout(SliverConstraints constraints) {
    final bool reverseCrossAxis = axisDirectionIsReversed(constraints.crossAxisDirection);
    return MasonrySliverGridLayout(
      data: resolveData(constraints.crossAxisExtent, reverseCrossAxis: reverseCrossAxis),
      tileCrossAxisExtent: tileCrossAxisExtent(
        crossAxisExtent: constraints.crossAxisExtent,
        columnCount: columnCount,
        crossAxisSpacing: crossAxisSpacing,
      ),
      crossAxisSpacing: crossAxisSpacing,
      reverseCrossAxis: reverseCrossAxis,
    );
  }

  /// Extent of the layout resolved by the last [getLayout] call.
  ///
  /// Safe to read from the child delegate's `estimateMaxScrollOffset`, because
  /// `RenderSliverGrid.performLayout` always calls [getLayout] first.
  double get lastResolvedMaxScrollExtent => _MasonryLayoutMemo.lastExtent;

  @override
  bool shouldRelayout(covariant MasonrySliverGridDelegate oldDelegate) {
    return oldDelegate.listToken != listToken ||
        oldDelegate.columnCount != columnCount ||
        oldDelegate.mainAxisSpacing != mainAxisSpacing ||
        oldDelegate.crossAxisSpacing != crossAxisSpacing ||
        !identical(oldDelegate.baseColumnOffsets, baseColumnOffsets);
  }
}

/// Reports the exact scroll extent instead of letting Flutter extrapolate from
/// an average child size.
///
/// The estimate is what makes `maxScrollExtent` wobble while scrolling, which in
/// turn makes the "am I near the end?" page trigger and the scrollbar thumb
/// jittery on a masonry grid.
class MasonryChildBuilderDelegate extends SliverChildBuilderDelegate {
  MasonryChildBuilderDelegate(
    super.builder, {
    required this.exactExtentFor,
    super.childCount,
    super.addAutomaticKeepAlives,
    super.addRepaintBoundaries,
    super.findChildIndexCallback,
  });

  final double Function(int childCount) exactExtentFor;

  @override
  double? estimateMaxScrollOffset(
    int firstIndex,
    int lastIndex,
    double leadingScrollOffset,
    double trailingScrollOffset,
  ) {
    final int? count = childCount;
    if (count == null) {
      return null;
    }
    return exactExtentFor(count);
  }
}
