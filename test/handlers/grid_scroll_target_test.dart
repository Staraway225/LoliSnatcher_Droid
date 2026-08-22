import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:scroll_to_index/scroll_to_index.dart';

import 'package:lolisnatcher/src/data/booru.dart';
import 'package:lolisnatcher/src/data/booru_item.dart';
import 'package:lolisnatcher/src/data/settings/preview_display_mode.dart';
import 'package:lolisnatcher/src/data/tag.dart';
import 'package:lolisnatcher/src/handlers/grid_scroll_targeter.dart';
import 'package:lolisnatcher/src/handlers/search_handler.dart';
import 'package:lolisnatcher/src/handlers/settings_handler.dart';
import 'package:lolisnatcher/src/utils/grid_layout_math.dart';
import 'package:lolisnatcher/src/widgets/preview/masonry_grid_delegate.dart';

/// Exercises [GridScrollTargeter] against a grid built exactly the way
/// `GridBuilder` / `StaggeredBuilder` build theirs, because the whole point of
/// the class is that its arithmetic agrees with the live sliver.
///
/// The offsets asserted here are what the viewer-exit reposition moves to, and
/// getting them wrong lands the user somewhere other than the item they were
/// looking at -- a worse failure than the jitter this replaced.

const double kViewportWidth = 400;
const double kViewportHeight = 800;

/// Stands in for the app bar sliver, so `precedingScrollExtent` is not zero and
/// a plain `row * stride` answer would visibly fail.
const double kLeadingExtent = 56;

/// Same as the waterfall's grid padding.
const EdgeInsets kGridPadding = EdgeInsets.fromLTRB(10, 16, 10, 180);

/// What `viewportBoundaryGetter` reports in the app: status bar + toolbar at the
/// top, system inset at the bottom.
const double kTopInset = 90;
const double kBottomInset = 20;

const int kColumnCount = 3;
const double kSpacing = 4;

/// Scroll offset of the grid's first row.
const double kGridOrigin = kLeadingExtent + 16;

double get kGridCrossAxisExtent => kViewportWidth - kGridPadding.horizontal;

List<BooruItem> makeItems(int count) {
  return List<BooruItem>.generate(count, (int i) {
    // Deterministic mix, including the null-size case the staggered height
    // formula falls back on.
    final ({double? w, double? h}) size = switch (i % 4) {
      0 => (w: 1000, h: 1000),
      1 => (w: 1000, h: 1500),
      2 => (w: 1920, h: 1080),
      _ => (w: null, h: null),
    };
    return BooruItem(
      fileURL: 'https://example-booru.test/file/$i.jpg',
      sampleURL: 'https://example-booru.test/sample/$i.jpg',
      thumbnailURL: 'https://example-booru.test/thumb/$i.jpg',
      tagsList: const <Tag>[],
      postURL: 'https://example-booru.test/post/$i',
      fileWidth: size.w,
      fileHeight: size.h,
    );
  });
}

/// The masonry layout the delegate resolves, recomputed independently so the
/// assertions do not lean on the same call the production code makes.
MasonryLayoutData expectedMasonryLayout(
  List<BooruItem> items, {
  List<double>? baseColumnOffsets,
}) {
  final double tileWidth = tileCrossAxisExtent(
    crossAxisExtent: kGridCrossAxisExtent,
    columnCount: kColumnCount,
    crossAxisSpacing: kSpacing,
  );
  return computeMasonryLayout(
    heights: <double>[
      for (final BooruItem item in items)
        staggeredTileHeight(
          tileWidth: tileWidth,
          fileWidth: item.fileWidth,
          fileHeight: item.fileHeight,
        ),
    ],
    columnCount: kColumnCount,
    mainAxisSpacing: kSpacing,
    baseColumnOffsets: baseColumnOffsets,
  );
}

double expectedFixedItemTop(int index, {double childAspectRatio = 1}) {
  return (index ~/ kColumnCount) *
      fixedGridMainAxisStride(
        crossAxisExtent: kGridCrossAxisExtent,
        columnCount: kColumnCount,
        crossAxisSpacing: kSpacing,
        mainAxisSpacing: kSpacing,
        childAspectRatio: childAspectRatio,
      );
}

class TestEnv {
  TestEnv._(this.settings, this.searchHandler, this.tab, this.items);

  factory TestEnv.setUp({
    required int itemCount,
    required PreviewDisplayMode previewDisplay,
  }) {
    final SettingsHandler settings = SettingsHandler.register();
    settings
      ..previewDisplay = previewDisplay
      ..previewDisplayFallback = PreviewDisplayMode.square
      ..portraitColumns = kColumnCount
      ..landscapeColumns = kColumnCount;

    final SearchHandler searchHandler = SearchHandler.register();
    // A null booru type falls through BooruHandlerFactory's switch to
    // EmptyHandler, which can never hit the network.
    final SearchTab tab = SearchTab(
      Booru('test', null, '', 'https://example-booru.test', ''),
      null,
      '',
    );
    searchHandler.tabs.add(tab);
    searchHandler.index.value = 0;

    final List<BooruItem> items = makeItems(itemCount);
    tab.booruHandler.fetched.addAll(items);
    tab.booruHandler.filteredFetched.addAll(items);

    return TestEnv._(
      settings,
      searchHandler,
      tab,
      // Must be the identical list instance the grid builds from: the masonry
      // delegate keys its memo on identityHashCode of this list.
      tab.booruHandler.filteredFetched.value,
    );
  }

  final SettingsHandler settings;
  final SearchHandler searchHandler;
  final SearchTab tab;
  final List<BooruItem> items;

  void tearDown() {
    SearchHandler.unregister();
    SettingsHandler.unregister();
  }
}

AutoScrollController makeController() {
  return AutoScrollController(
    viewportBoundaryGetter: () => const Rect.fromLTRB(0, kTopInset, 0, kBottomInset),
  );
}

Widget buildGrid({
  required GlobalKey gridSliverKey,
  required AutoScrollController controller,
  required List<BooruItem> items,
  required bool staggered,
  List<double>? baseColumnOffsets,
  bool tickerEnabled = true,
  double childAspectRatio = 1,
}) {
  Widget tile(BuildContext context, int index) {
    return AutoScrollTag(
      key: ValueKey<int>(index),
      controller: controller,
      index: index,
      child: ColoredBox(
        key: ValueKey<String>('tile-$index'),
        color: Colors.blue,
      ),
    );
  }

  Widget sliver;
  if (staggered) {
    // Same arguments StaggeredBuilder passes, so the delegate's single-entry
    // memo is shared rather than thrashed.
    final MasonrySliverGridDelegate delegate = MasonrySliverGridDelegate(
      aspects: <MasonryTileAspect>[
        for (final BooruItem item in items) (width: item.fileWidth, height: item.fileHeight),
      ],
      listToken: Object.hash(identityHashCode(items), items.length),
      columnCount: kColumnCount,
      mainAxisSpacing: kSpacing,
      crossAxisSpacing: kSpacing,
      baseColumnOffsets: baseColumnOffsets,
    );
    sliver = SliverGrid(
      gridDelegate: delegate,
      delegate: MasonryChildBuilderDelegate(
        addAutomaticKeepAlives: false,
        addRepaintBoundaries: false,
        childCount: items.length,
        exactExtentFor: (_) => delegate.lastResolvedMaxScrollExtent,
        tile,
      ),
    );
  } else {
    sliver = SliverGrid(
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: kColumnCount,
        childAspectRatio: childAspectRatio,
        mainAxisSpacing: kSpacing,
        crossAxisSpacing: kSpacing,
      ),
      delegate: SliverChildBuilderDelegate(
        addAutomaticKeepAlives: false,
        addRepaintBoundaries: false,
        childCount: items.length,
        tile,
      ),
    );
  }

  return MaterialApp(
    home: Directionality(
      textDirection: TextDirection.ltr,
      child: SizedBox(
        width: kViewportWidth,
        height: kViewportHeight,
        child: TickerMode(
          enabled: tickerEnabled,
          child: CustomScrollView(
            controller: controller,
            slivers: <Widget>[
              const SliverToBoxAdapter(child: SizedBox(height: kLeadingExtent)),
              SliverPadding(
                padding: kGridPadding,
                sliver: Builder(
                  key: gridSliverKey,
                  builder: (_) => sliver,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

void sizeViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(kViewportWidth, kViewportHeight);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

double tileTop(WidgetTester tester, int index) =>
    tester.getTopLeft(find.byKey(ValueKey<String>('tile-$index'))).dy;

void main() {
  late TestEnv env;
  late AutoScrollController controller;
  late GlobalKey gridSliverKey;
  late GridScrollTargeter targeter;

  void register({
    required int itemCount,
    required PreviewDisplayMode previewDisplay,
    required bool staggered,
  }) {
    env = TestEnv.setUp(itemCount: itemCount, previewDisplay: previewDisplay);
    controller = makeController();
    env.searchHandler.gridScrollController = controller;
    gridSliverKey = GlobalKey();
    targeter = GridScrollTargeter(
      gridSliverKey: gridSliverKey,
      isStaggered: () => staggered,
      columnCountOf: () => kColumnCount,
    );
    addTearDown(() {
      controller.dispose();
      env.tearDown();
    });
  }

  group('fixed grid', () {
    // Row 0 sits above the top inset, so its target clamps to zero and would
    // not land at kTopInset. Every other index here is well clear of both ends.
    const List<int> indices = <int>[3, 12, 48, 99];

    testWidgets('estimated offset puts the tile under the app bar', (WidgetTester tester) async {
      sizeViewport(tester);
      register(itemCount: 240, previewDisplay: PreviewDisplayMode.square, staggered: false);

      await tester.pumpWidget(
        buildGrid(
          gridSliverKey: gridSliverKey,
          controller: controller,
          items: env.items,
          staggered: false,
        ),
      );

      for (final int index in indices) {
        final double? target = targeter.estimatedOffsetForIndex(index);
        expect(target, isNotNull, reason: 'index $index');
        expect(
          target,
          moreOrLessEquals(kGridOrigin + expectedFixedItemTop(index) - kTopInset, epsilon: 0.01),
          reason: 'index $index',
        );

        controller.jumpTo(target!);
        await tester.pump();

        expect(tileTop(tester, index), moreOrLessEquals(kTopInset, epsilon: 0.5), reason: 'index $index');
        expect(targeter.isIndexFullyVisible(index), isTrue, reason: 'index $index');
      }
    });

    testWidgets('estimate matches the exact offset once the tile is built', (WidgetTester tester) async {
      sizeViewport(tester);
      register(itemCount: 240, previewDisplay: PreviewDisplayMode.square, staggered: false);

      await tester.pumpWidget(
        buildGrid(
          gridSliverKey: gridSliverKey,
          controller: controller,
          items: env.items,
          staggered: false,
        ),
      );

      for (final int index in indices) {
        controller.jumpTo(targeter.estimatedOffsetForIndex(index)!);
        await tester.pump();
        expect(
          targeter.exactOffsetForBuiltIndex(index),
          moreOrLessEquals(targeter.estimatedOffsetForIndex(index)!, epsilon: 0.01),
          reason: 'index $index',
        );
      }
    });

    testWidgets('uses the fallback display mode when the handler has no size data', (WidgetTester tester) async {
      sizeViewport(tester);
      // EmptyHandler reports hasSizeData == false, so GridBuilder falls back --
      // and so must the targeter, or every row is the wrong height.
      register(itemCount: 240, previewDisplay: PreviewDisplayMode.staggered, staggered: false);
      env.settings.previewDisplayFallback = PreviewDisplayMode.rectangle;

      await tester.pumpWidget(
        buildGrid(
          gridSliverKey: gridSliverKey,
          controller: controller,
          items: env.items,
          staggered: false,
          childAspectRatio: 9 / 16,
        ),
      );

      for (final int index in indices) {
        controller.jumpTo(targeter.estimatedOffsetForIndex(index)!);
        await tester.pump();
        expect(tileTop(tester, index), moreOrLessEquals(kTopInset, epsilon: 0.5), reason: 'index $index');
      }
    });
  });

  group('masonry grid', () {
    const List<int> indices = <int>[3, 17, 64, 121];

    testWidgets('estimated offset puts the tile under the app bar', (WidgetTester tester) async {
      sizeViewport(tester);
      register(itemCount: 240, previewDisplay: PreviewDisplayMode.staggered, staggered: true);

      await tester.pumpWidget(
        buildGrid(
          gridSliverKey: gridSliverKey,
          controller: controller,
          items: env.items,
          staggered: true,
        ),
      );

      final MasonryLayoutData layout = expectedMasonryLayout(env.items);

      for (final int index in indices) {
        final double? target = targeter.estimatedOffsetForIndex(index);
        expect(target, isNotNull, reason: 'index $index');
        expect(
          target,
          moreOrLessEquals(kGridOrigin + layout.tops[index] - kTopInset, epsilon: 0.01),
          reason: 'index $index',
        );

        controller.jumpTo(target!);
        await tester.pump();

        expect(tileTop(tester, index), moreOrLessEquals(kTopInset, epsilon: 0.5), reason: 'index $index');
      }
    });

    testWidgets('honours the column frontier left by a trim', (WidgetTester tester) async {
      sizeViewport(tester);
      register(itemCount: 240, previewDisplay: PreviewDisplayMode.staggered, staggered: true);

      const List<double> bases = <double>[0, 40, 90];
      env.tab.gridTrim.baseColumnOffsets = bases;

      await tester.pumpWidget(
        buildGrid(
          gridSliverKey: gridSliverKey,
          controller: controller,
          items: env.items,
          staggered: true,
          baseColumnOffsets: bases,
        ),
      );

      final MasonryLayoutData layout = expectedMasonryLayout(env.items, baseColumnOffsets: bases);

      for (final int index in indices) {
        final double? target = targeter.estimatedOffsetForIndex(index);
        expect(
          target,
          moreOrLessEquals(kGridOrigin + layout.tops[index] - kTopInset, epsilon: 0.01),
          reason: 'index $index',
        );

        controller.jumpTo(target!);
        await tester.pump();

        expect(tileTop(tester, index), moreOrLessEquals(kTopInset, epsilon: 0.5), reason: 'index $index');
      }
    });
  });

  group('revealIndex', () {
    Future<void> pumpFixedGrid(WidgetTester tester, {bool tickerEnabled = true}) async {
      sizeViewport(tester);
      register(itemCount: 240, previewDisplay: PreviewDisplayMode.square, staggered: false);
      await tester.pumpWidget(
        buildGrid(
          gridSliverKey: gridSliverKey,
          controller: controller,
          items: env.items,
          staggered: false,
          tickerEnabled: tickerEnabled,
        ),
      );
    }

    testWidgets('does nothing for an item that never left the screen', (WidgetTester tester) async {
      await pumpFixedGrid(tester);

      controller.jumpTo(targeter.estimatedOffsetForIndex(12)!);
      await tester.pump();
      final double before = controller.offset;

      expect(targeter.revealIndex(12), GridRevealAction.alreadyVisible);
      await tester.pump();
      expect(controller.offset, before);
    });

    testWidgets('animates a nearby target', (WidgetTester tester) async {
      await pumpFixedGrid(tester);

      // Row 7, i.e. a bit over one viewport down: inside the animate threshold.
      const int index = 21;
      final double target = targeter.estimatedOffsetForIndex(index)!;
      expect(target, lessThan(kViewportHeight * GridScrollTargeter.defaultMaxAnimateViewports));

      expect(targeter.revealIndex(index), GridRevealAction.animated);

      // Actually animating, not teleporting.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(controller.offset, greaterThan(0));
      expect(controller.offset, lessThan(target));

      await tester.pumpAndSettle();
      expect(controller.offset, moreOrLessEquals(target, epsilon: 0.5));
      expect(tileTop(tester, index), moreOrLessEquals(kTopInset, epsilon: 0.5));
    });

    testWidgets('jumps a far target and lands exactly', (WidgetTester tester) async {
      await pumpFixedGrid(tester);

      // Row 40, far beyond the animate threshold and never built at offset 0.
      const int index = 120;
      final double target = targeter.estimatedOffsetForIndex(index)!;
      expect(
        target,
        greaterThan(kViewportHeight * GridScrollTargeter.defaultMaxAnimateViewports),
      );
      expect(targeter.exactOffsetForBuiltIndex(index), isNull, reason: 'tile should not be built yet');

      expect(targeter.revealIndex(index), GridRevealAction.jumped);

      // One frame lays the jump out; the post-frame correction then runs
      // against the tile that frame built.
      await tester.pump();
      await tester.pump();

      expect(controller.offset, moreOrLessEquals(target, epsilon: 0.5));
      expect(tileTop(tester, index), moreOrLessEquals(kTopInset, epsilon: 0.5));
      expect(targeter.isIndexFullyVisible(index), isTrue);
    });

    testWidgets('still lands while the subtree is ticker-muted', (WidgetTester tester) async {
      // The viewer is pushed with `opaque: false`, so the waterfall stays
      // mounted under it with its tickers muted. A muted ticker *suspends* a
      // scroll animation instead of cancelling it, which is what used to leave
      // a backlog of scrollToIndex runs to thaw all at once on the way out.
      // jumpTo needs no ticker, so the computed reposition is immune.
      await pumpFixedGrid(tester, tickerEnabled: false);

      const int index = 120;
      final double target = targeter.estimatedOffsetForIndex(index)!;

      expect(targeter.revealIndex(index), GridRevealAction.jumped);
      await tester.pump();
      await tester.pump();

      expect(controller.offset, moreOrLessEquals(target, epsilon: 0.5));
      expect(tileTop(tester, index), moreOrLessEquals(kTopInset, epsilon: 0.5));
    });

    testWidgets('scrollToIndex, by contrast, does not move at all while muted', (WidgetTester tester) async {
      await pumpFixedGrid(tester, tickerEnabled: false);

      // The old viewer-sync path. Left here as the characterisation of the bug:
      // it is not that the animation is slow, it is that it never runs.
      unawaited(
        controller.scrollToIndex(
          120,
          duration: const Duration(milliseconds: 10),
          preferPosition: AutoScrollPosition.begin,
        ),
      );

      for (int i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }

      expect(controller.offset, 0);
    });
  });
}
