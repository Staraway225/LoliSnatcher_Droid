import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'package:lolisnatcher/src/handlers/booru_handler.dart';
import 'package:lolisnatcher/src/handlers/search_handler.dart';
import 'package:lolisnatcher/src/handlers/settings_handler.dart';
import 'package:lolisnatcher/src/handlers/viewer_handler.dart';
import 'package:lolisnatcher/src/utils/grid_layout_math.dart';
import 'package:lolisnatcher/src/widgets/preview/masonry_grid_delegate.dart';

/// Enforces the sliding-window scroll cache.
///
/// Drops the oldest pages once a tab holds more than the configured limit, then
/// shifts the scroll offset by exactly the extent that was removed, so nothing
/// under the user's finger moves.
class ScrollCacheTrimmer {
  ScrollCacheTrimmer({
    required this.gridSliverKey,
    required this.isStaggered,
    required this.columnCountOf,
  });

  /// Key on the widget that builds the grid sliver, used to read the sliver's
  /// own [SliverConstraints] rather than guessing geometry from MediaQuery.
  final GlobalKey gridSliverKey;
  final bool Function() isStaggered;
  final int Function() columnCountOf;

  /// Trim no more than twice a second, so a fast fling cannot spend its time
  /// re-packing layouts.
  static const int _cooldownMs = 500;

  /// Extra rows of headroom kept above the first built child.
  static const int _safetyRows = 2;

  int _lastTrimAtMs = 0;

  SearchHandler get _searchHandler => SearchHandler.instance;
  SettingsHandler get _settingsHandler => SettingsHandler.instance;
  ViewerHandler get _viewerHandler => ViewerHandler.instance;

  /// Trims the current tab if it is over the limit and it is safe to do so.
  ///
  /// Must only be called when the scroll has settled: [ScrollPosition.jumpTo]
  /// calls `goIdle()`, which would kill an in-flight drag or fling.
  void maybeTrim({required int nowMs}) {
    final int pageLimit = _settingsHandler.scrollCachePageLimit;
    if (pageLimit <= 0) {
      return;
    }

    final SearchTab? tab = _searchHandler.currentTabOrNull;
    if (tab == null) {
      return;
    }

    final BooruHandler handler = tab.booruHandler;
    if (!handler.supportsTrim) {
      return;
    }

    if (nowMs - _lastTrimAtMs < _cooldownMs) {
      return;
    }

    // The viewer indexes into filteredFetched by integer position and cannot be
    // re-anchored without visibly reloading the page, so never trim underneath
    // it. This costs nothing: the list cannot grow while the viewer is open.
    if (_viewerHandler.activeViewers.isNotEmpty) {
      return;
    }

    // Trimming mid-fetch would race the append, and the end-of-results check.
    if (_searchHandler.isLoading.value) {
      return;
    }

    // A selection that includes invisible items the user can no longer reach is
    // worse than holding the memory a little longer.
    if (tab.selected.isNotEmpty) {
      return;
    }

    final ScrollController controller = _searchHandler.gridScrollController;
    if (!controller.hasClients || !controller.position.hasContentDimensions) {
      return;
    }

    final RenderObject? renderObject = gridSliverKey.currentContext?.findRenderObject();
    // geometry is null until the sliver has been laid out at least once, and
    // reading `constraints` before that throws.
    if (renderObject is! RenderSliver || renderObject.geometry == null) {
      return;
    }
    final SliverConstraints sliverConstraints = renderObject.constraints;

    final int perPage = handler.limit > 0 ? handler.limit : _settingsHandler.itemLimit;
    if (perPage <= 0) {
      return;
    }
    final int limitItems = pageLimit * perPage;
    final int currentLength = handler.filteredFetched.length;

    // Hysteresis: only act once we are two whole pages over, so a trim does not
    // fire on every single appended page.
    if (currentLength < limitItems + (2 * perPage)) {
      return;
    }

    final int columnCount = columnCountOf();
    if (columnCount <= 0) {
      return;
    }

    final double crossAxisExtent = sliverConstraints.crossAxisExtent;
    // cacheOrigin is <= 0: this is the top of the cache region, i.e. the first
    // content that may already be built.
    final double cacheTop = sliverConstraints.scrollOffset + sliverConstraints.cacheOrigin;

    final bool staggered = isStaggered();
    tab.gridTrim.invalidateIfChanged(
      generation: handler.fetchedGeneration,
      columnCount: columnCount,
      crossAxisExtent: crossAxisExtent,
      staggered: staggered,
    );

    final int targetRemove = currentLength - limitItems;
    if (targetRemove <= 0) {
      return;
    }

    if (staggered) {
      _trimStaggered(
        tab: tab,
        handler: handler,
        controller: controller,
        targetRemove: targetRemove,
        columnCount: columnCount,
        crossAxisExtent: crossAxisExtent,
        cacheTop: cacheTop,
        nowMs: nowMs,
      );
    } else {
      _trimFixed(
        tab: tab,
        handler: handler,
        controller: controller,
        targetRemove: targetRemove,
        columnCount: columnCount,
        crossAxisExtent: crossAxisExtent,
        cacheTop: cacheTop,
        nowMs: nowMs,
      );
    }
  }

  void _trimFixed({
    required SearchTab tab,
    required BooruHandler handler,
    required ScrollController controller,
    required int targetRemove,
    required int columnCount,
    required double crossAxisExtent,
    required double cacheTop,
    required int nowMs,
  }) {
    final double childAspectRatio = _settingsHandler.previewDisplay.isSquare ? 1 : 9 / 16;
    final double stride = fixedGridMainAxisStride(
      crossAxisExtent: crossAxisExtent,
      columnCount: columnCount,
      crossAxisSpacing: 4,
      mainAxisSpacing: 4,
      childAspectRatio: childAspectRatio,
    );
    if (stride <= 0) {
      return;
    }

    final int firstBuiltIndex = (cacheTop ~/ stride) * columnCount;
    int removeCount = _clampToBuiltChildren(
      targetRemove: targetRemove,
      firstBuiltIndex: firstBuiltIndex,
      columnCount: columnCount,
      handler: handler,
    );

    // Partial rows would shift survivors sideways, which no single offset
    // correction can hide.
    removeCount -= removeCount % columnCount;
    if (removeCount <= 0) {
      return;
    }

    final double delta = fixedGridRemovedExtent(
      removedCount: removeCount,
      crossAxisExtent: crossAxisExtent,
      columnCount: columnCount,
      crossAxisSpacing: 4,
      mainAxisSpacing: 4,
      childAspectRatio: childAspectRatio,
    );

    _apply(
      tab: tab,
      handler: handler,
      controller: controller,
      removeCount: removeCount,
      delta: delta,
      newBases: null,
      nowMs: nowMs,
    );
  }

  void _trimStaggered({
    required SearchTab tab,
    required BooruHandler handler,
    required ScrollController controller,
    required int targetRemove,
    required int columnCount,
    required double crossAxisExtent,
    required double cacheTop,
    required int nowMs,
  }) {
    final MasonrySliverGridDelegate delegate = MasonrySliverGridDelegate(
      aspects: <MasonryTileAspect>[
        for (final item in handler.filteredFetched) (width: item.fileWidth, height: item.fileHeight),
      ],
      listToken: Object.hash(
        identityHashCode(handler.filteredFetched.value),
        handler.filteredFetched.length,
      ),
      columnCount: columnCount,
      mainAxisSpacing: 4,
      crossAxisSpacing: 4,
      baseColumnOffsets: tab.gridTrim.baseColumnOffsets,
    );
    final MasonryLayoutData layout = delegate.resolveData(crossAxisExtent);

    final int firstBuiltIndex = layout.firstIndexAtOrAfter(cacheTop);
    final int removeCount = _clampToBuiltChildren(
      targetRemove: targetRemove,
      firstBuiltIndex: firstBuiltIndex,
      columnCount: columnCount,
      handler: handler,
    );
    if (removeCount <= 0) {
      return;
    }

    final MasonryTrimResult trim = masonryTrimResult(layout, removeCount);
    if (!trim.canCompensate) {
      return;
    }

    _apply(
      tab: tab,
      handler: handler,
      controller: controller,
      removeCount: removeCount,
      delta: trim.scrollDelta,
      newBases: trim.baseColumnOffsets,
      nowMs: nowMs,
    );
  }

  /// Never remove an index that already has a live child, so nothing is
  /// destroyed underfoot. When the user has scrolled back up into the region
  /// this goes non-positive and the trim is simply skipped.
  int _clampToBuiltChildren({
    required int targetRemove,
    required int firstBuiltIndex,
    required int columnCount,
    required BooruHandler handler,
  }) {
    int maxRemove = firstBuiltIndex - (_safetyRows * columnCount);

    // Desktop keeps an inline viewer with no route, so guard the current item by
    // identity rather than suppressing trimming entirely.
    final current = ViewerHandler.instance.current.value;
    if (current != null) {
      final int currentIndex = handler.filteredFetched.value.indexWhere(
        (e) => identical(e, current),
      );
      if (currentIndex >= 0 && currentIndex < maxRemove) {
        maxRemove = currentIndex;
      }
    }

    return targetRemove < maxRemove ? targetRemove : maxRemove;
  }

  void _apply({
    required SearchTab tab,
    required BooruHandler handler,
    required ScrollController controller,
    required int removeCount,
    required double delta,
    required List<double>? newBases,
    required int nowMs,
  }) {
    if (removeCount <= 0 || delta <= 0) {
      return;
    }

    final int removed = handler.trimFrontByFilteredCount(removeCount);
    if (removed != removeCount) {
      // Post-condition not met: skip compensation rather than desync the offset.
      return;
    }

    if (newBases != null) {
      tab.gridTrim.baseColumnOffsets = newBases;
    }

    // The list mutation only marks widgets dirty; nothing lays out until the
    // next frame. jumpTo -> forcePixels sets pixels immediately without
    // clamping against the stale maxScrollExtent, so the next frame builds the
    // shortened list *and* lays out at the corrected offset -- there is no
    // intermediate frame at the old position. We always shrink, so the forced
    // value stays in range.
    final double newOffset = (controller.offset - delta).clamp(0.0, double.infinity);
    controller.jumpTo(newOffset);
    tab.scrollPosition = newOffset;

    tab.gridTrim
      ..trimmedItems += removed
      ..trimmedExtent += delta;
    _lastTrimAtMs = nowMs;
  }
}
