import 'dart:async';

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'package:scroll_to_index/scroll_to_index.dart';

import 'package:lolisnatcher/src/data/booru_item.dart';
import 'package:lolisnatcher/src/data/settings/preview_display_mode.dart';
import 'package:lolisnatcher/src/handlers/booru_handler.dart';
import 'package:lolisnatcher/src/handlers/search_handler.dart';
import 'package:lolisnatcher/src/handlers/settings_handler.dart';
import 'package:lolisnatcher/src/utils/grid_layout_math.dart';
import 'package:lolisnatcher/src/widgets/preview/masonry_grid_delegate.dart';

/// What [GridScrollTargeter.revealIndex] did, so callers (and tests) can tell
/// a deliberate no-op from a failure to resolve the index.
enum GridRevealAction {
  /// Already wholly on screen and clear of the floating bars.
  alreadyVisible,

  /// Close enough that animating there is cheap.
  animated,

  /// Far enough that animating would build every tile in between.
  jumped,

  /// No laid-out grid, or the index is not in the current list.
  unavailable,
}

/// Answers "what offset puts item N at the top of the visible viewport".
///
/// `scroll_to_index` can only answer that by *hunting*: an index whose tile was
/// never built has no [AutoScrollTag] in `tagMap`, so it hops towards the
/// nearest built tile, re-checks, hops again, then corrects -- several
/// animations in alternating directions. Since the grid's geometry is fully
/// known from the same layout math the sliding-window trim already relies on,
/// compute the destination instead and move there once.
///
/// The [gridSliverKey] / [isStaggered] / [columnCountOf] trio mirrors
/// `ScrollCacheTrimmer`, so both can be built from the same callbacks.
class GridScrollTargeter {
  GridScrollTargeter({
    required this.gridSliverKey,
    required this.isStaggered,
    required this.columnCountOf,
  });

  /// Key on the widget that builds the grid sliver, used to read the sliver's
  /// own [SliverConstraints] rather than guessing geometry from MediaQuery.
  final GlobalKey gridSliverKey;
  final bool Function() isStaggered;
  final int Function() columnCountOf;

  /// Matches the spacing both grid builders pass to their delegates.
  static const double _spacing = 4;

  /// Distance, in viewports, beyond which [revealIndex] jumps.
  static const double defaultMaxAnimateViewports = 1.5;

  /// Below this a correction is not worth a second jump.
  static const double _correctionEpsilon = 0.5;

  SearchHandler get _searchHandler => SearchHandler.instance;
  SettingsHandler get _settingsHandler => SettingsHandler.instance;

  AutoScrollController get _controller => _searchHandler.gridScrollController;

  /// Region of the viewport covered by the floating bars. Reading it off the
  /// controller keeps this in step with whatever `AutoScrollPosition.begin`
  /// used to subtract.
  Rect get _boundary => _controller.viewportBoundaryGetter();

  /// Offset that puts [index] just below the app bar, derived from the grid's
  /// layout math.
  ///
  /// Works for any index, including one whose tile was never built -- that is
  /// the whole point. Null when the grid has not been laid out yet, or when
  /// [index] is out of range.
  double? estimatedOffsetForIndex(int index) {
    if (index < 0) {
      return null;
    }

    final SliverConstraints? constraints = _gridConstraints();
    if (constraints == null) {
      return null;
    }

    final SearchTab? tab = _searchHandler.currentTabOrNull;
    if (tab == null) {
      return null;
    }

    final BooruHandler handler = tab.booruHandler;
    final List<BooruItem> items = handler.filteredFetched.value;
    if (index >= items.length) {
      return null;
    }

    final int columnCount = columnCountOf();
    if (columnCount <= 0) {
      return null;
    }

    final double crossAxisExtent = constraints.crossAxisExtent;
    final double itemTop = isStaggered()
        ? _staggeredItemTop(
            tab: tab,
            items: items,
            index: index,
            columnCount: columnCount,
            crossAxisExtent: crossAxisExtent,
          )
        : _fixedItemTop(
            handler: handler,
            index: index,
            columnCount: columnCount,
            crossAxisExtent: crossAxisExtent,
          );

    // RenderSliverEdgeInsetsPadding folds its leading padding into
    // precedingScrollExtent, so the SliverPadding above the grid and the app
    // bar sliver are already accounted for.
    return _clamped(constraints.precedingScrollExtent + itemTop - _boundary.top);
  }

  /// Same offset, but measured off the live render tree instead of predicted.
  ///
  /// Only available once the tile exists, which is exactly what makes it
  /// useful as a correction after an estimated jump has brought the index into
  /// the build range.
  double? exactOffsetForBuiltIndex(int index) {
    final RevealedOffset? revealed = _revealedOffset(index, 0);
    if (revealed == null) {
      return null;
    }
    return _clamped(revealed.offset - _boundary.top);
  }

  /// Whether [index] is already on screen in full, clear of the floating bars.
  ///
  /// Lets a caller skip a re-align that would move the grid for no reason.
  bool isIndexFullyVisible(int index) {
    final ScrollPosition? position = _position();
    if (position == null) {
      return false;
    }

    final RevealedOffset? begin = _revealedOffset(index, 0);
    final RevealedOffset? end = _revealedOffset(index, 1);
    if (begin == null || end == null) {
      return false;
    }

    // `begin` puts the item's leading edge at the viewport's leading edge and
    // `end` its trailing edge at the trailing edge, so the item is wholly
    // between the bars while the offset sits inside that inset range.
    final Rect boundary = _boundary;
    return position.pixels <= (begin.offset - boundary.top) &&
        position.pixels >= (end.offset + boundary.bottom);
  }

  /// Moves the grid so [index] sits just below the app bar.
  ///
  /// Animates when the destination is close and jumps when it is not: an
  /// animated scroll makes the viewport build and lay out every tile it passes
  /// through, which across several screens of thumbnails is guaranteed jank.
  GridRevealAction revealIndex(
    int index, {
    Duration duration = const Duration(milliseconds: 300),
    Curve curve = Curves.easeOutCubic,
    double maxAnimateViewports = defaultMaxAnimateViewports,
  }) {
    final ScrollPosition? position = _position();
    if (position == null || index < 0) {
      return GridRevealAction.unavailable;
    }

    // Re-aligning something that never left the screen would be movement for
    // its own sake.
    if (isIndexFullyVisible(index)) {
      return GridRevealAction.alreadyVisible;
    }

    final bool wasBuilt = _controller.tagMap[index] != null;
    final double? target = exactOffsetForBuiltIndex(index) ?? estimatedOffsetForIndex(index);
    if (target == null) {
      return GridRevealAction.unavailable;
    }

    if ((target - position.pixels).abs() <= position.viewportDimension * maxAnimateViewports) {
      unawaited(_controller.animateTo(target, duration: duration, curve: curve));
      return GridRevealAction.animated;
    }

    _controller.jumpTo(target);
    if (!wasBuilt) {
      // The estimate only has to land the tile inside the build range; once it
      // exists the viewport can be asked for the exact offset instead.
      WidgetsBinding.instance.addPostFrameCallback((_) => _correctToBuiltIndex(index));
    }
    return GridRevealAction.jumped;
  }

  void _correctToBuiltIndex(int index) {
    final ScrollPosition? position = _position();
    final double? exact = exactOffsetForBuiltIndex(index);
    if (position == null || exact == null) {
      return;
    }
    if ((exact - position.pixels).abs() > _correctionEpsilon) {
      _controller.jumpTo(exact);
    }
  }

  double _fixedItemTop({
    required BooruHandler handler,
    required int index,
    required int columnCount,
    required double crossAxisExtent,
  }) {
    return (index ~/ columnCount) *
        fixedGridMainAxisStride(
          crossAxisExtent: crossAxisExtent,
          columnCount: columnCount,
          crossAxisSpacing: _spacing,
          mainAxisSpacing: _spacing,
          childAspectRatio: _childAspectRatio(handler),
        );
  }

  double _staggeredItemTop({
    required SearchTab tab,
    required List<BooruItem> items,
    required int index,
    required int columnCount,
    required double crossAxisExtent,
  }) {
    // Must be built with exactly the arguments StaggeredBuilder uses: the
    // delegate memoises a single layout keyed on them, so a mismatch would
    // evict the one the live sliver is using.
    final MasonrySliverGridDelegate delegate = MasonrySliverGridDelegate(
      aspects: <MasonryTileAspect>[
        for (final BooruItem item in items) (width: item.fileWidth, height: item.fileHeight),
      ],
      listToken: Object.hash(identityHashCode(items), items.length),
      columnCount: columnCount,
      mainAxisSpacing: _spacing,
      crossAxisSpacing: _spacing,
      baseColumnOffsets: tab.gridTrim.baseColumnOffsets,
    );
    return delegate.resolveData(crossAxisExtent).tops[index];
  }

  /// Resolved the way GridBuilder resolves it, including the fallback display
  /// mode when the handler carries no size data.
  ///
  /// Note ScrollCacheTrimmer._trimFixed reads `previewDisplay.isSquare`
  /// unconditionally and so disagrees with the grid in that case.
  double _childAspectRatio(BooruHandler handler) {
    final PreviewDisplayMode mode = (_settingsHandler.previewDisplay.isStaggered && !handler.hasSizeData)
        ? _settingsHandler.previewDisplayFallback
        : _settingsHandler.previewDisplay;
    return mode.isSquare ? 1 : 9 / 16;
  }

  SliverConstraints? _gridConstraints() {
    final RenderObject? renderObject = gridSliverKey.currentContext?.findRenderObject();
    // geometry is null until the sliver has been laid out at least once, and
    // reading `constraints` before that throws.
    if (renderObject is! RenderSliver || renderObject.geometry == null) {
      return null;
    }
    return renderObject.constraints;
  }

  /// Offset that reveals a *built* tile at [alignment], straight from the
  /// viewport. This is what the package does internally, minus the animation.
  RevealedOffset? _revealedOffset(int index, double alignment) {
    final AutoScrollTagState? tag = _controller.tagMap[index];
    if (tag == null || !tag.mounted) {
      return null;
    }

    final RenderObject? renderObject = tag.context.findRenderObject();
    if (renderObject == null || !renderObject.attached) {
      return null;
    }

    return RenderAbstractViewport.maybeOf(renderObject)?.getOffsetToReveal(renderObject, alignment);
  }

  ScrollPosition? _position() {
    if (!_controller.hasClients) {
      return null;
    }
    final ScrollPosition position = _controller.position;
    return position.hasContentDimensions ? position : null;
  }

  double? _clamped(double offset) {
    final ScrollPosition? position = _position();
    if (position == null) {
      return null;
    }
    return offset.clamp(position.minScrollExtent, position.maxScrollExtent);
  }
}
