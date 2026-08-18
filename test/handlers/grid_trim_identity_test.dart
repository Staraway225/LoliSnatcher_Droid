import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lolisnatcher/src/data/booru_item.dart';
import 'package:lolisnatcher/src/utils/grid_layout_math.dart';
import 'package:lolisnatcher/src/widgets/preview/grid_child_index.dart';

import '../support/booru_item_factory.dart';

/// Stands in for the real tile: a StatefulWidget whose State records whether it
/// was ever disposed. The real bug destroyed `_ThumbnailState`, which evicts the
/// decoded image and cancels the in-flight request in its `dispose`.
class ProbeTile extends StatefulWidget {
  const ProbeTile({required this.item, super.key});

  final BooruItem item;

  @override
  State<ProbeTile> createState() => ProbeTileState();
}

class ProbeTileState extends State<ProbeTile> {
  static int disposeCount = 0;
  static final Map<String, ProbeTileState> byUrl = <String, ProbeTileState>{};

  static void reset() {
    disposeCount = 0;
    byUrl.clear();
  }

  @override
  void initState() {
    super.initState();
    byUrl[widget.item.fileURL] = this;
  }

  @override
  void dispose() {
    disposeCount++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const ColoredBox(color: Colors.blue);
}

Widget buildGrid({
  required List<BooruItem> items,
  required ScrollController controller,
  required bool withFix,
}) {
  return MaterialApp(
    home: Directionality(
      textDirection: TextDirection.ltr,
      child: SizedBox(
        width: kWidth,
        height: kHeight,
        child: CustomScrollView(
          controller: controller,
          slivers: <Widget>[
            SliverGrid(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: kColumns,
                mainAxisSpacing: kSpacing,
                crossAxisSpacing: kSpacing,
              ),
              delegate: SliverChildBuilderDelegate(
                addAutomaticKeepAlives: false,
                addRepaintBoundaries: false,
                childCount: items.length,
                findChildIndexCallback: withFix ? GridChildIndexResolver.forList(items) : null,
                (BuildContext context, int index) {
                  if (index >= items.length) {
                    return null;
                  }
                  final BooruItem item = items[index];
                  return GridTile(
                    key: ValueKey<Key>(item.key),
                    child: ProbeTile(item: item),
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

const double kWidth = 400;
const double kHeight = 800;
const int kColumns = 2;
const double kSpacing = 4;

/// Same math the trimmer uses to compensate the scroll offset.
double trimDelta(int removedCount) => fixedGridRemovedExtent(
  removedCount: removedCount,
  crossAxisExtent: kWidth,
  columnCount: kColumns,
  crossAxisSpacing: kSpacing,
  mainAxisSpacing: kSpacing,
  childAspectRatio: 1,
);

void main() {
  setUp(() {
    ProbeTileState.reset();
    GridChildIndexResolver.invalidate();
  });

  testWidgets('trimming the front does NOT dispose surviving tiles', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(kWidth, kHeight);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final BooruItemFactory factory = BooruItemFactory();
    final List<BooruItem> all = factory.page(400);
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(buildGrid(items: all, controller: controller, withFix: true));
    // Scroll far enough that the 40 items about to be trimmed are well above the
    // built window -- the same precondition `_clampToBuiltChildren` enforces.
    const double startOffset = 8000;
    controller.jumpTo(startOffset);
    await tester.pump();

    final List<BooruItem> visible = all.where((BooruItem e) => ProbeTileState.byUrl.containsKey(e.fileURL)).toList();
    expect(visible, isNotEmpty, reason: 'nothing was built, test is meaningless');
    final Map<String, ProbeTileState> before = <String, ProbeTileState>{
      for (final BooruItem e in visible) e.fileURL: ProbeTileState.byUrl[e.fileURL]!,
    };
    ProbeTileState.disposeCount = 0;

    // Trim 40 items off the front and compensate the offset, exactly as
    // ScrollCacheTrimmer does, so the same items stay on screen.
    // Offset first, then the new list -- ScrollCacheTrimmer mutates the list and
    // calls jumpTo synchronously, so a single frame sees both. Pumping the new
    // list at the old offset would legitimately garbage-collect the relocated
    // children before the correction landed.
    const int removed = 40;
    final List<BooruItem> trimmed = all.sublist(removed);
    controller.jumpTo(startOffset - trimDelta(removed));
    await tester.pumpWidget(buildGrid(items: trimmed, controller: controller, withFix: true));
    await tester.pump();

    expect(
      ProbeTileState.disposeCount,
      0,
      reason: 'surviving tiles must be relocated, not destroyed and re-inflated',
    );

    // And they must be the very same State objects, not lookalikes.
    for (final MapEntry<String, ProbeTileState> entry in before.entries) {
      final ProbeTileState? now = ProbeTileState.byUrl[entry.key];
      if (now != null) {
        expect(
          identical(now, entry.value),
          isTrue,
          reason: 'tile ${entry.key} was rebuilt from scratch',
        );
      }
    }
  });

  testWidgets('without findChildIndexCallback the tiles ARE destroyed', (WidgetTester tester) async {
    // Documents the regression this guards against: if the callback is ever
    // dropped again, the test above fails and this one explains why.
    tester.view.physicalSize = const Size(kWidth, kHeight);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final BooruItemFactory factory = BooruItemFactory();
    final List<BooruItem> all = factory.page(400);
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(buildGrid(items: all, controller: controller, withFix: false));
    const double startOffset = 8000;
    controller.jumpTo(startOffset);
    await tester.pump();
    ProbeTileState.disposeCount = 0;

    const int removed = 40;
    controller.jumpTo(startOffset - trimDelta(removed));
    await tester.pumpWidget(
      buildGrid(items: all.sublist(removed), controller: controller, withFix: false),
    );
    await tester.pump();

    expect(
      ProbeTileState.disposeCount,
      greaterThan(0),
      reason: 'this is the bug: every built tile is destroyed on an index shift',
    );
  });
}
