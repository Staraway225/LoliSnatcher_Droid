import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lolisnatcher/src/data/booru.dart';
import 'package:lolisnatcher/src/handlers/search_handler.dart';
import 'package:lolisnatcher/src/handlers/settings_handler.dart';
import 'package:lolisnatcher/src/handlers/tag_handler.dart';
import 'package:lolisnatcher/src/widgets/preview/main_search_bar.dart';
import 'package:lolisnatcher/src/widgets/preview/main_search_tag_chip.dart';

const double kBarWidth = 320;

/// Enough tags to overflow [MainSearchBar.maxLines] rows at [kBarWidth].
final String kLongQuery = List<String>.generate(40, (i) => 'tag_$i').join(' ');

/// A null booru type falls through BooruHandlerFactory's switch to
/// EmptyHandler, which can never hit the network.
SearchTab makeTab(String tags) => SearchTab(
  Booru('test', null, '', 'https://example-booru.test', ''),
  null,
  tags,
);

Widget buildBar() {
  return const MaterialApp(
    home: Scaffold(
      body: Align(
        alignment: Alignment.topCenter,
        child: SizedBox(
          width: kBarWidth,
          child: MainSearchBarWithActions('test'),
        ),
      ),
    ),
  );
}

Finder get barFinder => find.byType(MainSearchBar);

double barHeight(WidgetTester tester) => tester.getSize(barFinder).height;

ScrollPosition barScroll(WidgetTester tester) =>
    tester.state<ScrollableState>(find.descendant(of: barFinder, matching: find.byType(Scrollable))).position;

void main() {
  late SearchHandler searchHandler;

  setUp(() {
    SettingsHandler.register();
    TagHandler.register();
    searchHandler = SearchHandler.register();
    searchHandler.tabs.addAll([makeTab(kLongQuery), makeTab('other')]);
    searchHandler.index.value = 0;
    searchHandler.tabId.value = searchHandler.tabs[0].id;
  });

  tearDown(() {
    SearchHandler.unregister();
    TagHandler.unregister();
    SettingsHandler.unregister();
  });

  testWidgets('a single tag keeps the one-line height', (WidgetTester tester) async {
    searchHandler.searchTextController.text = 'tag_0';
    await tester.pumpWidget(buildBar());

    expect(barHeight(tester), MainSearchBar.height);
  });

  testWidgets('a long query grows to maxLines and then scrolls', (WidgetTester tester) async {
    searchHandler.searchTextController.text = kLongQuery;
    await tester.pumpWidget(buildBar());

    expect(barHeight(tester), MainSearchBar.maxHeight);
    expect(barScroll(tester).maxScrollExtent, greaterThan(0));
  });

  testWidgets('deleting a chip after a search keeps the scroll offset', (WidgetTester tester) async {
    searchHandler.searchTextController.text = kLongQuery;
    await tester.pumpWidget(buildBar());

    barScroll(tester).jumpTo(barScroll(tester).maxScrollExtent);
    await tester.pump();
    final double offset = barScroll(tester).pixels;
    expect(offset, greaterThan(0));

    // What searchAction does: the tab is replaced by one with a new id, which
    // is published late and without any change to the search text.
    searchHandler.tabs[0] = makeTab(kLongQuery);
    searchHandler.tabId.value = searchHandler.tabs[0].id;
    await tester.pumpAndSettle();

    final Finder lastChipDelete = find
        .descendant(of: find.byType(MainSearchTagChip), matching: find.byIcon(Icons.close_rounded))
        .last;
    await tester.tap(lastChipDelete);
    await tester.pumpAndSettle();

    expect(searchHandler.searchTextControllerTags, hasLength(39));
    // Removing the last chip may only pull the offset back to the new end,
    // never to the start.
    expect(barScroll(tester).pixels, greaterThan(0));
    expect(barScroll(tester).pixels, barScroll(tester).maxScrollExtent);
  });

  testWidgets('switching tabs scrolls the bar back to the start', (WidgetTester tester) async {
    searchHandler.searchTextController.text = kLongQuery;
    await tester.pumpWidget(buildBar());

    barScroll(tester).jumpTo(barScroll(tester).maxScrollExtent);
    await tester.pump();
    expect(barScroll(tester).pixels, greaterThan(0));

    // The order changeTabIndex uses for a real switch.
    searchHandler.tabs[1] = makeTab(kLongQuery);
    searchHandler.index.value = 1;
    searchHandler.tabId.value = searchHandler.tabs[1].id;
    searchHandler.searchTextController.text = '$kLongQuery extra';
    await tester.pumpAndSettle();

    expect(barScroll(tester).pixels, 0);
  });
}
