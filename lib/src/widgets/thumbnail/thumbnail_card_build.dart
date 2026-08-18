import 'dart:math';

import 'package:flutter/material.dart';

import 'package:get/get.dart';
import 'package:scroll_to_index/scroll_to_index.dart';

import 'package:lolisnatcher/src/data/booru_item.dart';
import 'package:lolisnatcher/src/handlers/booru_handler.dart';
import 'package:lolisnatcher/src/handlers/snatch_handler.dart';
import 'package:lolisnatcher/src/widgets/common/animated_progress_indicator.dart';
import 'package:lolisnatcher/src/widgets/thumbnail/thumbnail_build.dart';

class ThumbnailCardBuild extends StatelessWidget {
  const ThumbnailCardBuild({
    required this.index,
    required this.item,
    required this.handler,
    required this.scrollController,
    this.selectionOf,
    this.isHighlighted = false,
    this.selectable = true,
    this.selectedIndex,
    this.onSelected,
    this.onTap,
    this.onDoubleTap,
    this.onLongPress,
    this.onSecondaryTap,
    super.key,
  });

  final int index;
  final BooruItem item;
  final BooruHandler handler;
  final AutoScrollController scrollController;

  /// Observes this tile's selection index and highlight state.
  ///
  /// When provided, the reactive read happens *inside* this widget and wraps
  /// only the card itself, so a selection change or a viewer page change no
  /// longer rebuilds the AutoScrollTag, Material, Stack and snatch-progress
  /// overlay of every visible tile.
  final ({int? selectedIndex, bool isHighlighted, bool hasSelected}) Function()? selectionOf;

  final bool isHighlighted;
  final bool selectable;
  final int? selectedIndex;
  final void Function(int)? onSelected;
  final void Function(int)? onTap;
  final void Function(int)? onDoubleTap;
  final void Function(int)? onLongPress;
  final void Function(int)? onSecondaryTap;

  @override
  Widget build(BuildContext context) {
    final snatchHandler = SnatchHandler.instance;

    final double defaultBorderWidth = max(2, MediaQuery.devicePixelRatioOf(context));

    return AutoScrollTag(
      highlightColor: Colors.red,
      key: ValueKey(index),
      controller: scrollController,
      index: index,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(4),
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (selectionOf != null)
              Obx(() {
                final selection = selectionOf!();
                return _buildCard(
                  context,
                  defaultBorderWidth: defaultBorderWidth,
                  selectedIndex: selection.selectedIndex,
                  isHighlighted: selection.isHighlighted,
                  hasSelected: selection.hasSelected,
                );
              })
            else
              _buildCard(
                context,
                defaultBorderWidth: defaultBorderWidth,
                selectedIndex: selectedIndex,
                isHighlighted: isHighlighted,
                // Legacy call sites already gate onSelected themselves.
                hasSelected: true,
              ),
            //
            Positioned.fill(
              child: Obx(() {
                if (snatchHandler.activeItem.value != item) {
                  return const SizedBox.shrink();
                }

                return ListenableBuilder(
                  listenable: Listenable.merge([
                    snatchHandler.total,
                    snatchHandler.received,
                  ]),
                  builder: (context, _) => AnimatedProgressIndicator(
                    value: snatchHandler.currentProgress,
                    animationDuration: const Duration(milliseconds: 50),
                    indicatorStyle: IndicatorStyle.square,
                    valueColor: Theme.of(context).progressIndicatorTheme.color,
                    strokeWidth: defaultBorderWidth * 3,
                    borderRadius: 10,
                  ),
                );
              }),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCard(
    BuildContext context, {
    required double defaultBorderWidth,
    required int? selectedIndex,
    required bool isHighlighted,
    required bool hasSelected,
  }) {
    final bool isSelected = selectable && selectedIndex != null;
    final bool showHighlightBorder = isHighlighted || isSelected;

    return DecoratedBox(
      position: DecorationPosition.foreground,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(4),
        border: showHighlightBorder
            ? Border.all(
                color: Theme.of(context).colorScheme.secondary,
                width: defaultBorderWidth,
              )
            : null,
      ),
      child: InkWell(
        enableFeedback: true,
        borderRadius: BorderRadius.circular(4),
        highlightColor: Theme.of(context).colorScheme.secondary.withValues(alpha: 0.4),
        splashColor: Theme.of(context).colorScheme.secondary.withValues(alpha: 0.2),
        onTap: onTap == null ? null : () => onTap?.call(index),
        onDoubleTap: onDoubleTap == null ? null : () => onDoubleTap?.call(index),
        onLongPress: onLongPress == null ? null : () => onLongPress?.call(index),
        onSecondaryTap: onSecondaryTap == null ? null : () => onSecondaryTap?.call(index),
        child: ThumbnailBuild(
          item: item,
          handler: handler,
          selectable: selectable,
          selectedIndex: isSelected ? selectedIndex : null,
          // Preserves the original behaviour: the select affordance only shows
          // once selection mode is active.
          onSelected: (onSelected == null || !hasSelected) ? null : () => onSelected!(index),
        ),
      ),
    );
  }
}
