import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lolisnatcher/src/utils/grid_layout_math.dart';
import 'package:lolisnatcher/src/widgets/preview/masonry_grid_delegate.dart';

const double kViewportWidth = 400;
const double kViewportHeight = 800;

List<MasonryTileAspect> aspectsFor(int count) {
  return List<MasonryTileAspect>.generate(count, (int i) {
    switch (i % 4) {
      case 0:
        return (width: 1000.0, height: 1000.0);
      case 1:
        return (width: 1000.0, height: 1500.0);
      case 2:
        return (width: 1920.0, height: 1080.0);
      default:
        return (width: null, height: null);
    }
  });
}

Widget buildGrid({
  required ScrollController controller,
  int? itemCount,
  List<MasonryTileAspect>? aspects,
  List<double>? baseColumnOffsets,
  int columnCount = 3,
}) {
  final List<MasonryTileAspect> tiles = aspects ?? aspectsFor(itemCount!);
  final MasonrySliverGridDelegate delegate = MasonrySliverGridDelegate(
    aspects: tiles,
    listToken: Object.hash('test', tiles.length, baseColumnOffsets?.length ?? -1, aspects != null),
    columnCount: columnCount,
    mainAxisSpacing: 4,
    crossAxisSpacing: 4,
    baseColumnOffsets: baseColumnOffsets,
  );

  return MaterialApp(
    home: Directionality(
      textDirection: TextDirection.ltr,
      child: SizedBox(
        width: kViewportWidth,
        height: kViewportHeight,
        child: CustomScrollView(
          controller: controller,
          slivers: <Widget>[
            SliverGrid(
              gridDelegate: delegate,
              delegate: MasonryChildBuilderDelegate(
                addAutomaticKeepAlives: false,
                addRepaintBoundaries: false,
                childCount: tiles.length,
                exactExtentFor: (_) => delegate.lastResolvedMaxScrollExtent,
                (BuildContext context, int index) {
                  if (index >= tiles.length) {
                    return null;
                  }
                  return ColoredBox(
                    key: ValueKey<int>(index),
                    color: Colors.blue,
                    child: Text('$index'),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('masonry grid lays out without errors', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(kViewportWidth, kViewportHeight);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(buildGrid(itemCount: 300, controller: controller));
    expect(tester.takeException(), isNull);

    // Only a viewport-ish slice is built, not all 300.
    expect(find.byType(ColoredBox), findsWidgets);
    expect(tester.widgetList(find.byType(ColoredBox)).length, lessThan(60));
  });

  testWidgets('masonry grid scrolls to the end without errors', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(kViewportWidth, kViewportHeight);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(buildGrid(itemCount: 300, controller: controller));

    final double max = controller.position.maxScrollExtent;
    expect(max, greaterThan(0));

    for (double offset = 0; offset <= max; offset += kViewportHeight / 2) {
      controller.jumpTo(offset);
      await tester.pump();
      expect(tester.takeException(), isNull, reason: 'exception at offset $offset');
    }

    controller.jumpTo(max);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('reported max scroll extent matches the pure math', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(kViewportWidth, kViewportHeight);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);

    const int itemCount = 120;
    await tester.pumpWidget(buildGrid(itemCount: itemCount, controller: controller));

    final double tileWidth = tileCrossAxisExtent(
      crossAxisExtent: kViewportWidth,
      columnCount: 3,
      crossAxisSpacing: 4,
    );
    final MasonryLayoutData expected = computeMasonryLayout(
      heights: <double>[
        for (final MasonryTileAspect a in aspectsFor(itemCount))
          staggeredTileHeight(tileWidth: tileWidth, fileWidth: a.width, fileHeight: a.height),
      ],
      columnCount: 3,
      mainAxisSpacing: 4,
    );

    // The viewport eats one screen height of the scrollable extent.
    expect(
      controller.position.maxScrollExtent,
      closeTo(expected.maxScrollExtent - kViewportHeight, 0.5),
    );
  });

  testWidgets('a seeded column frontier shifts every tile up by delta', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(kViewportWidth, kViewportHeight);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    const int total = 200;
    const int cut = 30;

    final double tileWidth = tileCrossAxisExtent(
      crossAxisExtent: kViewportWidth,
      columnCount: 3,
      crossAxisSpacing: 4,
    );
    final List<double> heights = <double>[
      for (final MasonryTileAspect a in aspectsFor(total))
        staggeredTileHeight(tileWidth: tileWidth, fileWidth: a.width, fileHeight: a.height),
    ];
    final MasonryLayoutData full = computeMasonryLayout(
      heights: heights,
      columnCount: 3,
      mainAxisSpacing: 4,
    );
    final MasonryTrimResult trim = masonryTrimResult(full, cut);
    expect(trim.canCompensate, isTrue);

    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      buildGrid(
        // The survivors are the ORIGINAL items cut..total-1, so their aspects
        // must be sliced, not regenerated from index 0.
        aspects: aspectsFor(total).sublist(cut),
        controller: controller,
        baseColumnOffsets: trim.baseColumnOffsets,
      ),
    );
    expect(tester.takeException(), isNull);

    // The trimmed grid must be exactly delta shorter than the full one.
    expect(
      controller.position.maxScrollExtent,
      closeTo(full.maxScrollExtent - trim.scrollDelta - kViewportHeight, 0.5),
    );
  });
}
