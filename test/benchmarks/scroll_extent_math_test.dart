import 'dart:math';

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lolisnatcher/src/utils/grid_layout_math.dart';

import '../support/bench.dart';

/// Only `crossAxisExtent` affects the values under test, but SliverConstraints
/// requires the full set.
SliverConstraints constraintsWith(double crossAxisExtent) {
  return SliverConstraints(
    axisDirection: AxisDirection.down,
    growthDirection: GrowthDirection.forward,
    userScrollDirection: ScrollDirection.idle,
    scrollOffset: 0,
    precedingScrollExtent: 0,
    overlap: 0,
    remainingPaintExtent: 800,
    crossAxisExtent: crossAxisExtent,
    crossAxisDirection: AxisDirection.right,
    viewportMainAxisExtent: 800,
    remainingCacheExtent: 800,
    cacheOrigin: 0,
  );
}

/// Independent transcription of waterfall_flow's `_CrossAxisChildrenData.insert`
/// (sliver_waterfall_flow.dart:846-905), used purely as a golden oracle.
({List<double> tops, List<int> columns, double extent}) referenceMasonry(
  List<double> heights,
  int columnCount,
  double mainAxisSpacing,
) {
  final List<double> tops = <double>[];
  final List<int> columns = <int>[];
  final List<double> trailing = <double>[];

  for (final double h in heights) {
    int column;
    double top;
    if (trailing.length < columnCount) {
      column = trailing.length;
      top = 0;
      trailing.add(0);
    } else {
      column = 0;
      for (int c = 1; c < columnCount; c++) {
        if (trailing[c] < trailing[column]) {
          column = c;
        }
      }
      top = trailing[column] + mainAxisSpacing;
    }
    tops.add(top);
    columns.add(column);
    trailing[column] = top + h;
  }

  return (tops: tops, columns: columns, extent: trailing.isEmpty ? 0 : trailing.reduce(max));
}

void main() {
  group("fixed grid math matches Flutter's own delegate", () {
    test('stride and removed extent agree with SliverGridRegularTileLayout', () {
      for (final int columnCount in <int>[2, 3, 4]) {
        for (final double aspect in <double>[1, 9 / 16]) {
          for (final double width in <double>[411.4, 360, 1024]) {
            final SliverGridLayout layout = SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columnCount,
              childAspectRatio: aspect,
              mainAxisSpacing: 4,
              crossAxisSpacing: 4,
            ).getLayout(constraintsWith(width));

            double ours(int index) => fixedGridRemovedExtent(
              removedCount: index,
              crossAxisExtent: width,
              columnCount: columnCount,
              crossAxisSpacing: 4,
              mainAxisSpacing: 4,
              childAspectRatio: aspect,
            );

            for (final int rows in <int>[0, 1, 2, 7, 50]) {
              final int removed = rows * columnCount;
              final double expected =
                  layout.getGeometryForChildIndex(removed).scrollOffset -
                  layout.getGeometryForChildIndex(0).scrollOffset;
              expect(
                ours(removed),
                closeTo(expected, 1e-9),
                reason: 'cols=$columnCount aspect=$aspect width=$width rows=$rows',
              );
            }
          }
        }
      }
    });

    test('max scroll offset agrees with the delegate', () {
      const double width = 411.4;
      const int columnCount = 3;
      const double aspect = 9 / 16;
      final SliverGridLayout layout = const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columnCount,
        childAspectRatio: aspect,
        mainAxisSpacing: 4,
        crossAxisSpacing: 4,
      ).getLayout(constraintsWith(width));

      for (final int n in <int>[1, 2, 3, 7, 20, 1000]) {
        expect(
          fixedGridMaxScrollOffset(
            itemCount: n,
            crossAxisExtent: width,
            columnCount: columnCount,
            crossAxisSpacing: 4,
            mainAxisSpacing: 4,
            childAspectRatio: aspect,
          ),
          closeTo(layout.computeMaxScrollOffset(n), 1e-9),
          reason: 'itemCount=$n',
        );
      }
    });
  });

  group('staggered tile height', () {
    test('matches the widget formula at both clamps', () {
      const double tileWidth = 180; // => tileMaxHeight 320
      expect(staggeredTileHeight(tileWidth: tileWidth, fileWidth: null, fileHeight: null), 180);
      expect(staggeredTileHeight(tileWidth: tileWidth, fileWidth: 1000, fileHeight: 1000), 180);
      // aspect 0.25 -> 720, clamped down to tileMaxHeight
      expect(staggeredTileHeight(tileWidth: tileWidth, fileWidth: 1000, fileHeight: 4000), 320);
      // aspect 4.0 -> 45, clamped up to the 100px floor
      expect(staggeredTileHeight(tileWidth: tileWidth, fileWidth: 4000, fileHeight: 1000), 100);
      expect(
        staggeredTileHeight(tileWidth: tileWidth, fileWidth: 1920, fileHeight: 1080),
        closeTo(101.25, 1e-9),
      );
    });

    test('the 100px floor wins over the aspect ceiling on narrow tiles', () {
      // tileWidth 50 => tileMaxHeight 88.9, below the floor.
      expect(staggeredTileHeight(tileWidth: 50, fileWidth: 1000, fileHeight: 4000), 100);
    });
  });

  group('masonry layout matches waterfall_flow', () {
    test('tops, columns and extent agree with the reference packer', () {
      final Random rng = Random(7);
      for (int trial = 0; trial < 40; trial++) {
        final int columnCount = 1 + rng.nextInt(6);
        final List<double> heights =
            List<double>.generate(200, (_) => 100 + rng.nextDouble() * 400);

        final MasonryLayoutData ours = computeMasonryLayout(
          heights: heights,
          columnCount: columnCount,
          mainAxisSpacing: 4,
        );
        final ({List<double> tops, List<int> columns, double extent}) reference =
            referenceMasonry(heights, columnCount, 4);

        for (int i = 0; i < heights.length; i++) {
          expect(ours.tops[i], closeTo(reference.tops[i], 1e-9), reason: 'trial $trial index $i');
          expect(ours.columns[i], reference.columns[i], reason: 'trial $trial index $i');
        }
        expect(ours.maxScrollExtent, closeTo(reference.extent, 1e-9));
      }
    });

    test('ties are broken by the lowest column index', () {
      final MasonryLayoutData layout = computeMasonryLayout(
        heights: List<double>.filled(9, 100),
        columnCount: 3,
        mainAxisSpacing: 4,
      );
      expect(layout.columns, <int>[0, 1, 2, 0, 1, 2, 0, 1, 2]);
    });

    test('degenerate shapes', () {
      expect(
        computeMasonryLayout(heights: <double>[], columnCount: 3, mainAxisSpacing: 4)
            .maxScrollExtent,
        0,
      );
      // Fewer items than columns: all sit at the top, extent is the tallest.
      final MasonryLayoutData sparse = computeMasonryLayout(
        heights: <double>[100, 250],
        columnCount: 4,
        mainAxisSpacing: 4,
      );
      expect(sparse.tops, <double>[0, 0]);
      expect(sparse.maxScrollExtent, 250);
      // Single column degenerates to a list.
      final MasonryLayoutData single = computeMasonryLayout(
        heights: <double>[100, 200, 300],
        columnCount: 1,
        mainAxisSpacing: 4,
      );
      expect(single.maxScrollExtent, closeTo(100 + 200 + 300 + 4 * 2, 1e-9));
    });

    test('maxBottomPrefix is non-decreasing and binary search agrees with a scan', () {
      final Random rng = Random(11);
      final List<double> heights = List<double>.generate(500, (_) => 100 + rng.nextDouble() * 300);
      final MasonryLayoutData layout = computeMasonryLayout(
        heights: heights,
        columnCount: 3,
        mainAxisSpacing: 4,
      );

      for (int i = 1; i < layout.itemCount; i++) {
        expect(layout.maxBottomPrefix[i], greaterThanOrEqualTo(layout.maxBottomPrefix[i - 1]));
      }

      for (final double offset in <double>[0, 137.5, 900, 5000, 1000000000]) {
        int linear = layout.itemCount;
        for (int i = 0; i < layout.itemCount; i++) {
          if (layout.maxBottomPrefix[i] > offset) {
            linear = i;
            break;
          }
        }
        expect(layout.firstIndexAtOrAfter(offset), linear, reason: 'offset $offset');
      }
    });
  });

  group('the masonry trim theorem', () {
    test('survivors keep their column and shift up by exactly delta', () {
      final Random rng = Random(3);
      for (int trial = 0; trial < 30; trial++) {
        final int columnCount = 1 + rng.nextInt(7);
        final List<double> heights =
            List<double>.generate(300, (_) => 100 + rng.nextDouble() * 400);
        final MasonryLayoutData full = computeMasonryLayout(
          heights: heights,
          columnCount: columnCount,
          mainAxisSpacing: 4,
        );

        for (int attempt = 0; attempt < 5; attempt++) {
          final int cut = columnCount + rng.nextInt(heights.length - columnCount - 1);
          final MasonryTrimResult trim = masonryTrimResult(full, cut);
          if (!trim.canCompensate) {
            continue;
          }

          final MasonryLayoutData survivors = computeMasonryLayout(
            heights: heights.sublist(cut),
            columnCount: columnCount,
            mainAxisSpacing: 4,
            baseColumnOffsets: trim.baseColumnOffsets,
          );

          for (int i = 0; i < survivors.itemCount; i++) {
            expect(
              survivors.tops[i],
              closeTo(full.tops[cut + i] - trim.scrollDelta, 1e-9),
              reason: 'trial $trial cut $cut index $i',
            );
            expect(
              survivors.columns[i],
              full.columns[cut + i],
              reason: 'trial $trial cut $cut index $i column',
            );
          }
          expect(
            survivors.maxScrollExtent,
            closeTo(full.maxScrollExtent - trim.scrollDelta, 1e-9),
          );
        }
      }
    });

    test('refuses to compensate when the prefix has not filled every column', () {
      final MasonryLayoutData layout = computeMasonryLayout(
        heights: List<double>.filled(10, 100),
        columnCount: 4,
        mainAxisSpacing: 4,
      );
      expect(masonryTrimResult(layout, 2).canCompensate, isFalse);
      expect(masonryTrimResult(layout, 0).canCompensate, isFalse);
      expect(masonryTrimResult(layout, 10).canCompensate, isFalse);
    });
  });

  group('masonry performance', () {
    test('layout stays linear in item count', () {
      if (!timingEnabled) {
        markTestSkipped('set LS_BENCH=timing and --concurrency=1 for timing runs');
        return;
      }

      final Random rng = Random(5);
      final Map<int, double> perItem = <int, double>{};
      for (final int n in <int>[50000, 200000]) {
        final List<double> heights = List<double>.generate(n, (_) => 100 + rng.nextDouble() * 300);
        final BenchResult result = runBench(
          'masonry layout n=$n',
          body: () => computeMasonryLayout(heights: heights, columnCount: 4, mainAxisSpacing: 4),
          opCount: n,
        );
        perItem[n] = result.bestMicrosPerOp;
        // ignore: avoid_print
        print(result.format());
      }
      // Linear would be 4.0 for a 4x workload; allow generous headroom.
      expect(perItem[200000]! / perItem[50000]!, lessThan(2));
    });
  });
}
