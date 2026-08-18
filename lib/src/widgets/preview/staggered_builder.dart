import 'package:flutter/material.dart';

import 'package:get/get.dart';
import 'package:scroll_to_index/scroll_to_index.dart';

import 'package:lolisnatcher/src/data/booru_item.dart';
import 'package:lolisnatcher/src/handlers/search_handler.dart';
import 'package:lolisnatcher/src/handlers/settings_handler.dart';
import 'package:lolisnatcher/src/handlers/viewer_handler.dart';
import 'package:lolisnatcher/src/widgets/preview/grid_child_index.dart';
import 'package:lolisnatcher/src/widgets/preview/masonry_grid_delegate.dart';
import 'package:lolisnatcher/src/widgets/thumbnail/thumbnail_card_build.dart';

class StaggeredBuilder extends StatelessWidget {
  const StaggeredBuilder({
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

    final int columnCount = context.isPortrait ? settingsHandler.portraitColumns : settingsHandler.landscapeColumns;

    return ValueListenableBuilder(
      valueListenable: tab.booruHandler.filteredFetched,
      builder: (context, currentFetched, child) {
        // Tile heights come from the layout now, so each cell no longer needs its
        // own LayoutBuilder (one relayout boundary per tile) or a SizedBox.
        final MasonrySliverGridDelegate gridDelegate = MasonrySliverGridDelegate(
          aspects: <MasonryTileAspect>[
            for (final BooruItem item in currentFetched) (width: item.fileWidth, height: item.fileHeight),
          ],
          listToken: Object.hash(identityHashCode(currentFetched), currentFetched.length),
          columnCount: columnCount,
          mainAxisSpacing: 4,
          crossAxisSpacing: 4,
          baseColumnOffsets: tab.gridTrim.baseColumnOffsets,
        );

        return SliverGrid(
          gridDelegate: gridDelegate,
          delegate: MasonryChildBuilderDelegate(
            addAutomaticKeepAlives: false,
            addRepaintBoundaries: false, // ThumbnailCardBuild has its own RepaintBoundary
            childCount: currentFetched.length,
            // See GridChildIndexResolver: without this a trim tears down and
            // re-inflates every visible tile.
            findChildIndexCallback: GridChildIndexResolver.forList(currentFetched),
            exactExtentFor: (_) => gridDelegate.lastResolvedMaxScrollExtent,
            (context, index) {
              if (index >= currentFetched.length) {
                return null;
              }
              final BooruItem item = currentFetched[index];

              return KeyedSubtree(
                key: ValueKey(item.key),
                // The reactive read lives inside ThumbnailCardBuild now, wrapping
                // only the card, instead of rebuilding the whole tile for every
                // visible item on any selection or viewer page change.
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
      },
    );
  }
}
