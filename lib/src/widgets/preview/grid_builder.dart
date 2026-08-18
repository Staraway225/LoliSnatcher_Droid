import 'package:flutter/material.dart';

import 'package:get/get.dart';
import 'package:scroll_to_index/scroll_to_index.dart';

import 'package:lolisnatcher/src/data/booru_item.dart';
import 'package:lolisnatcher/src/handlers/search_handler.dart';
import 'package:lolisnatcher/src/handlers/settings_handler.dart';
import 'package:lolisnatcher/src/handlers/viewer_handler.dart';
import 'package:lolisnatcher/src/widgets/thumbnail/thumbnail_card_build.dart';

class GridBuilder extends StatelessWidget {
  const GridBuilder({
    required this.tab,
    required this.scrollController,
    this.onTap,
    this.onDoubleTap,
    this.onLongPress,
    this.onSecondaryTap,
    this.onSelected,
    super.key,
  });

  final SearchTab tab;
  final AutoScrollController scrollController;
  final void Function(int)? onTap;
  final void Function(int)? onDoubleTap;
  final void Function(int)? onLongPress;
  final void Function(int)? onSecondaryTap;
  final void Function(int)? onSelected;

  @override
  Widget build(BuildContext context) {
    final SettingsHandler settingsHandler = SettingsHandler.instance;

    final previewDisplay = (settingsHandler.previewDisplay.isStaggered && !tab.booruHandler.hasSizeData)
        ? settingsHandler.previewDisplayFallback
        : settingsHandler.previewDisplay;

    final int columnCount = context.isPortrait ? settingsHandler.portraitColumns : settingsHandler.landscapeColumns;

    return ValueListenableBuilder(
      valueListenable: tab.booruHandler.filteredFetched,
      builder: (context, currentFetched, child) => SliverGrid.builder(
        addAutomaticKeepAlives: false,
        addRepaintBoundaries: false, // ThumbnailCardBuild has its own RepaintBoundary
        itemCount: currentFetched.length,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columnCount,
          childAspectRatio: previewDisplay.isSquare ? 1 : 9 / 16,
          mainAxisSpacing: 4,
          crossAxisSpacing: 4,
        ),
        itemBuilder: (BuildContext context, int index) {
          final BooruItem item = currentFetched[index];

          return GridTile(
            key: ValueKey(item.key),
            // The reactive read lives inside ThumbnailCardBuild now, wrapping
            // only the card. Previously this Obx rebuilt the whole tile -- tag,
            // Material, Stack and progress overlay included -- for every visible
            // item whenever anything was selected or the viewer changed page.
            child: ThumbnailCardBuild(
              index: index,
              item: item,
              handler: tab.booruHandler,
              scrollController: scrollController,
              selectionOf: () => (
                selectedIndex: tab.selectedIndexOf(item),
                isHighlighted: ViewerHandler.instance.current.value?.key == item.key,
                hasSelected: tab.selected.isNotEmpty && tab.hasSelectedItems,
              ),
              selectable: true,
              onSelected: onSelected,
              onTap: onTap,
              onDoubleTap: onDoubleTap,
              onLongPress: onLongPress,
              onSecondaryTap: onSecondaryTap,
            ),
          );
        },
      ),
    );
  }
}
