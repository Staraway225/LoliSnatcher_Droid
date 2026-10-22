import 'dart:ui';

import 'package:flutter/material.dart';

import 'package:fading_edge_scrollview/fading_edge_scrollview.dart';
import 'package:get/get.dart' hide ContextExt, FirstWhereOrNullExt;
import 'package:scroll_to_index/scroll_to_index.dart';

import 'package:lolisnatcher/src/handlers/search_handler.dart';
import 'package:lolisnatcher/src/handlers/tag_handler.dart';
import 'package:lolisnatcher/src/handlers/service_handler.dart';
import 'package:lolisnatcher/src/handlers/settings_handler.dart';
import 'package:lolisnatcher/src/utils/extensions.dart';
import 'package:lolisnatcher/src/widgets/common/transparent_pointer.dart';
import 'package:lolisnatcher/src/widgets/preview/main_search_query_editor_page.dart';
import 'package:lolisnatcher/src/widgets/preview/main_search_tag_chip.dart';

class MainSearchBarWithActions extends StatelessWidget {
  const MainSearchBarWithActions(
    this.subTag, {
    super.key,
  });

  final String subTag;

  SearchHandler get searchHandler => SearchHandler.instance;
  SettingsHandler get settingsHandler => SettingsHandler.instance;

  void onChipTap(
    BuildContext context,
    String tag,
    int tagIndex,
  ) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => MainSearchQueryEditorPage(subTag: subTag)),
    );
  }

  void onChipLongTap(
    BuildContext context,
    String tag,
    int tagIndex,
  ) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MainSearchQueryEditorPage(
          subTag: subTag,
          tagToEditIndex: tagIndex,
        ),
      ),
    );
  }

  void onChipDeleteTap(
    String tag,
    int tagIndex,
  ) {
    final List<String> tempTags = searchHandler.searchTextControllerTags..removeAt(tagIndex);
    searchHandler.searchTextController.text = tempTags.join(' ');
  }

  void onSearchBackgroundTap(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MainSearchQueryEditorPage(
          subTag: subTag,
          autoFocus: settingsHandler.autofocusSearchbar,
        ),
      ),
    );
  }

  void onResetTap() {
    searchHandler.searchTextController.text = searchHandler.currentTabOrNull?.tags.trim() ?? '';
  }

  void onSearchTap() {
    searchHandler.searchTextController.clearComposing();
    searchHandler.searchAction(searchHandler.searchTextController.text, null);
  }

  void onSearchLongTap() {
    ServiceHandler.vibrate();
    searchHandler.searchTextController.clearComposing();
    searchHandler.addTabByString(searchHandler.searchTextController.text, switchToNew: true);
  }

  @override
  Widget build(BuildContext context) {
    return Hero(
      tag: 'mainSearchBar-$subTag',
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(
          physics: const BouncingScrollPhysics(),
        ),
        child: MainSearchBar(
          onChipTap: (tag, index) => onChipTap(context, tag, index),
          onChipLongTap: (tag, index) => onChipLongTap(context, tag, index),
          onChipDeleteTap: onChipDeleteTap,
          onSearchBackgroundTap: () => onSearchBackgroundTap(context),
          onResetTap: onResetTap,
          onClearTap: () {},
          onSearchTap: onSearchTap,
          onSearchLongTap: onSearchLongTap,
          subTag: subTag,
        ),
      ),
    );
  }
}

class MainSearchBar extends StatefulWidget {
  const MainSearchBar({
    required this.onChipTap,
    required this.onChipLongTap,
    required this.onChipDeleteTap,
    required this.onResetTap,
    required this.onClearTap,
    required this.onSearchTap,
    required this.onSearchLongTap,
    this.onSearchBackgroundTap,
    this.scrollController,
    this.selectedTag,
    this.selectedTagIndex,
    this.subTag,
    super.key,
  });

  final void Function(String, int) onChipTap;
  final void Function(String, int)? onChipLongTap;
  final void Function(String, int)? onChipDeleteTap;
  final VoidCallback onResetTap;
  final VoidCallback onClearTap;
  final VoidCallback onSearchTap;
  final VoidCallback onSearchLongTap;
  final VoidCallback? onSearchBackgroundTap;
  final AutoScrollController? scrollController;
  final String? selectedTag;
  final int? selectedTagIndex;
  final String? subTag;

  static const double _borderWidth = 1;
  static const double _verticalPadding = 6;
  static const double _chipHeight = 30;
  static const double _runSpacing = 6;

  /// The bar grows by one chip row at a time up to this many rows, then scrolls.
  static const int maxLines = 4;

  /// Height of a one-line bar, which is also its minimum.
  static double get height => 2 * _borderWidth + 2 * _verticalPadding + _chipHeight;

  static double get maxHeight =>
      2 * _borderWidth + 2 * _verticalPadding + maxLines * _chipHeight + (maxLines - 1) * _runSpacing;

  @override
  State<MainSearchBar> createState() => _MainSearchBarState();
}

class _MainSearchBarState extends State<MainSearchBar> {
  final SettingsHandler settingsHandler = SettingsHandler.instance;
  final SearchHandler searchHandler = SearchHandler.instance;

  late final AutoScrollController scrollController;

  List<String> tags = [];
  String _lastTagsSignature = '';

  final TagHandler tagHandler = TagHandler.instance;

  @override
  void initState() {
    super.initState();

    scrollController = widget.scrollController ?? AutoScrollController();

    parseTags();
    searchHandler.searchTextController.addListener(onTextChanged);
    // Tab switches are detected through the index rather than tabId: a search
    // replaces the current tab with a new id only once its first page lands,
    // which is long after the text changed and would read as a switch.
    searchHandler.index.addListener(onTabIndexChanged);

    // Chips need to re-render when a tag's type data arrives, which happens
    // asynchronously. This used to be a 3s Timer.periodic firing an
    // unconditional setState forever; now it reacts to the actual event and
    // only rebuilds when the rendered content would differ.
    tagHandler.tagsRevision.addListener(onTagsRevisionChanged);
  }

  void onTextChanged() {
    parseTags();
    setState(() {});
  }

  void onTabIndexChanged() {
    scrollToStart();
    if (mounted) {
      setState(() {});
    }
  }

  /// Rebuild only when a tag type that is actually on screen has changed.
  void onTagsRevisionChanged() {
    final String signature = _tagsSignature();
    if (signature == _lastTagsSignature) {
      return;
    }
    _lastTagsSignature = signature;
    if (mounted) {
      setState(() {});
    }
  }

  /// Everything the chip row's appearance depends on: the tags themselves and
  /// the type of each (which drives the chip colour).
  String _tagsSignature() {
    final StringBuffer buffer = StringBuffer();
    for (final String tag in tags) {
      buffer
        ..write(tag)
        ..write(':')
        ..write(tagHandler.getTag(tag).tagType.name)
        ..write('|');
    }
    return buffer.toString();
  }

  void parseTags() {
    tags = searchHandler.searchTextControllerTags;
    _lastTagsSignature = _tagsSignature();
  }

  void scrollToStart() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (scrollController.hasClients) {
        scrollController.animateTo(
          0,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _onClearTap() {
    widget.onClearTap();
    searchHandler.searchTextController.clear();
  }

  @override
  void dispose() {
    tagHandler.tagsRevision.removeListener(onTagsRevisionChanged);
    searchHandler.searchTextController.removeListener(onTextChanged);
    searchHandler.index.removeListener(onTabIndexChanged);
    super.dispose();
  }

  Widget _buildChip(int i) {
    final bool isSelected = widget.selectedTag == tags[i] || widget.selectedTagIndex == i;

    return AutoScrollTag(
      key: Key('${tags[i]}-$i-${searchHandler.currentTabId}'),
      controller: scrollController,
      index: i,
      // A Wrap lays its children out with unbounded height, and the chip
      // stretches its contents vertically, so it needs an explicit height.
      child: SizedBox(
        height: MainSearchBar._chipHeight,
        child: Stack(
          children: [
            MainSearchTagChip(
              tag: tags[i],
              tab: searchHandler.currentTabOrNull,
              onTap: () => widget.onChipTap(tags[i], i),
              onLongTap: widget.onChipLongTap == null ? null : () => widget.onChipLongTap!(tags[i], i),
              onDeleteTap: widget.onChipDeleteTap == null ? null : () => widget.onChipDeleteTap!(tags[i], i),
              canDelete: widget.selectedTagIndex != i,
              isSelected: isSelected,
            ),
            if (isSelected)
              Positioned.fill(
                child: TransparentPointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.transparent,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: context.theme.colorScheme.secondary,
                        width: 2,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildButton({
    required Key key,
    required IconData icon,
    required VoidCallback onTap,
    VoidCallback? onLongPress,
  }) {
    // One row tall, so the buttons sit on the last line as the bar grows.
    return SizedBox(
      key: key,
      height: MainSearchBar.height - 2 * MainSearchBar._borderWidth,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Icon(icon, size: 24),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MainSearchBar.maxHeight),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: _maybeBlur(
          enabled: !settingsHandler.shitDevice,
          sigma: 6,
          child: Material(
            color: context.theme.colorScheme.surface.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(16),
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: widget.onSearchBackgroundTap,
              child: Container(
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: context.theme.colorScheme.onSurface.withValues(alpha: 0.5),
                    width: MainSearchBar._borderWidth,
                  ),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: FadingEdgeScrollView.fromSingleChildScrollView(
                          child: SingleChildScrollView(
                            controller: scrollController,
                            // scrollconfig allows to control physics outside of the widget
                            physics: tags.isEmpty
                                ? const NeverScrollableScrollPhysics()
                                : ScrollConfiguration.of(context).getScrollPhysics(context),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: MainSearchBar._verticalPadding,
                            ),
                            child: tags.isEmpty
                                ? SizedBox(
                                    height: MainSearchBar._chipHeight,
                                    child: Align(
                                      alignment: Alignment.centerLeft,
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(horizontal: 8),
                                        child: Text(
                                          context.loc.search,
                                          style: context.theme.textTheme.bodyLarge?.copyWith(
                                            color: context.theme.colorScheme.onSurface.withValues(alpha: 0.5),
                                            fontSize: 16,
                                            height: 1,
                                          ),
                                        ),
                                      ),
                                    ),
                                  )
                                : Wrap(
                                    spacing: 8,
                                    runSpacing: MainSearchBar._runSpacing,
                                    children: [
                                      for (int i = 0; i < tags.length; i++) _buildChip(i),
                                    ],
                                  ),
                          ),
                        ),
                      ),
                      //
                      if (searchHandler.searchTextController.text.isNotEmpty)
                        Obx(
                          () {
                            if (searchHandler.currentTabOrNull?.tags.trim() == tags.join(' ')) {
                              return _buildButton(
                                key: const Key('clear-button'),
                                icon: Icons.close_rounded,
                                onTap: _onClearTap,
                              );
                            }

                            return const SizedBox.shrink();
                          },
                        ),
                      //
                      Obx(
                        () {
                          if (searchHandler.currentTabOrNull?.tags.trim() != tags.join(' ')) {
                            return _buildButton(
                              key: const Key('reset-button'),
                              icon: Icons.refresh,
                              onTap: widget.onResetTap,
                            );
                          }

                          return const SizedBox.shrink();
                        },
                      ),
                      //
                      _buildButton(
                        key: const Key('search-button'),
                        icon: Icons.search_rounded,
                        onTap: widget.onSearchTap,
                        onLongPress: widget.onSearchLongTap,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A grouped backdrop blur, or nothing at all when disabled.
///
/// `BackdropFilter(enabled: false)` still reports `alwaysNeedsCompositing`, so
/// it keeps a layer boundary even though it performs no blur.
Widget _maybeBlur({
  required bool enabled,
  required double sigma,
  required Widget child,
}) {
  if (!enabled) {
    return child;
  }
  return BackdropFilter.grouped(
    filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
    child: child,
  );
}
