import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'package:get/get.dart' hide ContextExt;

import 'package:lolisnatcher/src/data/booru_item.dart';
import 'package:lolisnatcher/src/handlers/grid_scroll_targeter.dart';
import 'package:lolisnatcher/src/handlers/navigation_handler.dart';
import 'package:lolisnatcher/src/handlers/scroll_cache_trimmer.dart';
import 'package:lolisnatcher/src/handlers/search_handler.dart';
import 'package:lolisnatcher/src/handlers/service_handler.dart';
import 'package:lolisnatcher/src/handlers/settings_handler.dart';
import 'package:lolisnatcher/src/handlers/viewer_handler.dart';
import 'package:lolisnatcher/src/pages/gallery_view_page.dart';
import 'package:lolisnatcher/src/utils/clipboard.dart';
import 'package:lolisnatcher/src/utils/extensions.dart';
import 'package:lolisnatcher/src/widgets/common/long_press_repeater.dart';
import 'package:lolisnatcher/src/widgets/preview/grid_builder.dart';
import 'package:lolisnatcher/src/widgets/preview/shimmer_builder.dart';
import 'package:lolisnatcher/src/widgets/preview/staggered_builder.dart';
import 'package:lolisnatcher/src/widgets/preview/waterfall_bottom_bar.dart';
import 'package:lolisnatcher/src/widgets/preview/waterfall_scroll_controller.dart';
import 'package:lolisnatcher/src/widgets/root/main_appbar.dart';

class WaterfallView extends StatefulWidget {
  const WaterfallView({super.key});

  @override
  State<WaterfallView> createState() => _WaterfallViewState();
}

class _WaterfallViewState extends State<WaterfallView> with RouteAware {
  static const int _floatingBarsDirectionDebounceMs = 120;

  final SettingsHandler settingsHandler = SettingsHandler.instance;

  final SearchHandler searchHandler = SearchHandler.instance;
  final ViewerHandler viewerHandler = ViewerHandler.instance;
  final NavigationHandler navigationHandler = NavigationHandler.instance;

  StreamSubscription? volumeListener;
  bool scrollDone = true;

  Orientation currentOrientation = Orientation.portrait;
  // Nested viewers replace ViewerHandler.current, so retain the page shown by
  // the root gallery for scroll restoration while they are open.
  int? _rootViewerIndex;

  bool isStaggered = false;

  bool get isMobile => settingsHandler.appMode.value.isMobile;

  final ValueNotifier<bool> isActive = ValueNotifier(true);
  ScrollDirection _lastFloatingBarsDirection = ScrollDirection.idle;
  ScrollDirection _pendingFloatingBarsDirection = ScrollDirection.idle;
  int _lastFloatingBarsDirectionChangedAt = 0;

  Timer? viewedItemCleanupTimer;
  int viewedItemCleanupCount = 0;
  final Set<BooruItem> viewedItems = {};

  /// Identifies the grid sliver so the trimmer can read its SliverConstraints
  /// directly (exact crossAxisExtent and cacheOrigin, correct in desktop mode
  /// where the grid does not span the window).
  final GlobalKey _gridSliverKey = GlobalKey();
  late final ScrollCacheTrimmer _trimmer;
  late final GridScrollTargeter _targeter;

  /// Index the viewer was left on, or null if it never moved off the tapped one.
  ///
  /// Nothing scrolls while the viewer is open. The route is pushed with
  /// `opaque: false`, so this subtree stays mounted but ticker-muted (see the
  /// TickerMode in [build]), and muting *suspends* a scroll animation rather
  /// than cancelling it -- one gets queued per swipe and they all thaw at once
  /// on the way out, which is what made the grid lurch. Record here, move once
  /// in [scrollToViewedIndexAfterViewer].
  int? pendingViewerIndex;

  @override
  void initState() {
    super.initState();

    _trimmer = ScrollCacheTrimmer(
      gridSliverKey: _gridSliverKey,
      isStaggered: () => isStaggered,
      // Read the live orientation, not `currentOrientation`, which is only
      // refreshed on certain rebuilds. Matches what the grid builders use.
      columnCountOf: () => context.isPortrait ? settingsHandler.portraitColumns : settingsHandler.landscapeColumns,
    );

    _targeter = GridScrollTargeter(
      gridSliverKey: _gridSliverKey,
      isStaggered: () => isStaggered,
      columnCountOf: () => context.isPortrait ? settingsHandler.portraitColumns : settingsHandler.landscapeColumns,
    );

    // listen to current tab change to restore the scroll value
    searchHandler.index.addListener(tabIndexListener);

    searchHandler.tabId.addListener(tabIdListener);

    // listen to isLoading to select first loaded item for desktop
    searchHandler.isLoading.addListener(isLoadingListener);

    setVolumeListener();
    // reset the volume butons state
    ServiceHandler.setVolumeButtons(!settingsHandler.useVolumeButtonsForScroll);
    // tabChanged(0);
    // TODO reset the controller when appMode changes
    searchHandler.gridScrollController = WaterfallScrollController(
      initialScrollOffset: searchHandler.currentTabOrNull?.scrollPosition ?? 0,
      viewportBoundaryGetter: () => Rect.fromLTRB(
        0,
        isMobile ? (MediaQuery.paddingOf(context).top + kToolbarHeight + 4) : 0,
        0,
        MediaQuery.paddingOf(context).bottom,
      ),
    );

    isStaggered =
        settingsHandler.previewDisplay.isStaggered && (searchHandler.currentBooruHandlerOrNull?.hasSizeData ?? false);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    NavigationHandler.instance.routeObserver.subscribe(
      this,
      ModalRoute.of(context)! as PageRoute,
    );
  }

  @override
  void didPushNext() {
    isActive.value = false;
  }

  @override
  void didPush() {
    isActive.value = true;
  }

  @override
  void didPopNext() {
    isActive.value = true;
    scrollToViewedIndexAfterViewer();
  }

  void tabIdListener() {
    if (searchHandler.tabId.value != null) {
      tabIndexListener();
    }
  }

  void tabIndexListener() {
    // print('tabChanged: ${searchHandler.currentTabOrNull?.scrollPosition} ${searchHandler.gridScrollController.hasClients}');

    // postpone scroll updates until the current render is done, since this is called after the global restate after exiting settings
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final currentTab = searchHandler.currentTabOrNull;
      if (currentTab == null) {
        return;
      }

      // restore scroll position on tab change
      if (searchHandler.gridScrollController.hasClients) {
        searchHandler.gridScrollController.jumpTo(currentTab.scrollPosition);
      } else {
        // if (currentTab.scrollPosition != 0) {
        // TODO reset the controller when appMode changes
        searchHandler.gridScrollController = WaterfallScrollController(
          initialScrollOffset: currentTab.scrollPosition,
          viewportBoundaryGetter: () => Rect.fromLTRB(
            0,
            isMobile ? (MediaQuery.paddingOf(context).top + kToolbarHeight + 4) : 0,
            0,
            MediaQuery.paddingOf(context).bottom,
          ),
        );
      }

      _showFloatingBars();
    });

    // check if grid type changed when changing tab
    final bool newIsStaggered =
        settingsHandler.previewDisplay.isStaggered && (searchHandler.currentBooruHandlerOrNull?.hasSizeData ?? false);
    if (isStaggered != newIsStaggered) {
      isStaggered = newIsStaggered;
      setState(() {});
    }
  }

  void isLoadingListener() {
    if (!searchHandler.isLoading.value) {
      afterSearch();
      // A page can land after the scroll already settled, in which case no
      // further ScrollEndNotification is coming.
      if (searchHandler.gridScrollController.hasClients &&
          !searchHandler.gridScrollController.position.isScrollingNotifier.value) {
        _trimmer.maybeTrim(nowMs: DateTime.now().millisecondsSinceEpoch);
      }
    }
  }

  void setVolumeListener() {
    volumeListener?.cancel();
    volumeListener = searchHandler.volumeStream?.listen(volumeCallback);
  }

  Future<void> volumeCallback(String event) async {
    if (isActive.value) {
      int dir = 0;
      if (event == 'up') {
        dir = -1;
      } else if (event == 'down') {
        dir = 1;
      }

      if (dir != 0 && scrollDone == true) {
        scrollDone = false;
        final double offset = max(
          searchHandler.gridScrollController.offset + (settingsHandler.volumeButtonsScrollSpeed * dir),
          -20,
        );
        await searchHandler.gridScrollController.animateTo(
          offset,
          duration: const Duration(milliseconds: 200),
          curve: Curves.linear,
        );
        scrollDone = true;
      }
    }
  }

  @override
  void dispose() {
    viewedItemCleanupTimer?.cancel();
    NavigationHandler.instance.routeObserver.unsubscribe(this);
    searchHandler.index.removeListener(tabIndexListener);
    searchHandler.tabId.removeListener(tabIdListener);
    searchHandler.isLoading.removeListener(isLoadingListener);
    volumeListener?.cancel();
    ServiceHandler.setVolumeButtons(true);
    super.dispose();
  }

  /// Brings the grid to the item the viewer was closed on, in a single move.
  ///
  /// The destination is computed rather than searched for: `scrollToIndex` has
  /// to hunt for an index whose tile was never built, and that hunt is several
  /// animations in alternating directions.
  void scrollToViewedIndexAfterViewer() {
    final int? index = pendingViewerIndex;
    pendingViewerIndex = null;
    if (index == null || index < 0 || !isMobile) {
      return;
    }

    // Post-frame so the TickerMode above has rebuilt with isActive == true
    // before any animation ticker is created: createTicker takes its muted
    // state from the inherited value at creation time.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !searchHandler.gridScrollController.hasClients) {
        return;
      }

      _targeter.revealIndex(index);
    });
  }

  void afterSearch() {
    if (isMobile) {
      return;
    }

    final currentFetched = searchHandler.currentFetchedOrNull;
    if (viewerHandler.current.value == null &&
        currentFetched != null &&
        currentFetched.isNotEmpty &&
        currentFetched.length < (settingsHandler.itemLimit + 1)) {
      viewerHandler.setCurrent(currentFetched.first);
    }
  }

  void syncFloatingBarsWithScroll(ScrollNotification notification) {
    if (notification.depth != 0 ||
        notification.metrics.axis != Axis.vertical ||
        !searchHandler.gridScrollController.hasClients) {
      return;
    }

    if (_isAtScrollStart(notification.metrics)) {
      _showFloatingBars();
      return;
    }

    final controller = searchHandler.gridScrollController;
    if (!isActive.value || controller.isAutoScrolling) {
      return;
    }

    // Driven user paging has an idle (or interrupted drag's stale) direction.
    // Only use its deltas; jumps, layout corrections and ballistic bounce-back
    // must not be interpreted as a new user direction.
    if (controller is WaterfallScrollController && controller.isPaging) {
      final delta = notification is ScrollUpdateNotification ? notification.scrollDelta : null;
      if (delta != null && delta != 0) {
        _updateFloatingBars(delta > 0 ? ScrollDirection.reverse : ScrollDirection.forward, debounce: false);
      }
    } else {
      _updateFloatingBars(controller.position.userScrollDirection);
    }
  }

  void _updateFloatingBars(
    ScrollDirection direction, {
    bool debounce = true,
  }) {
    if (direction == ScrollDirection.idle) {
      return;
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    final directionChanged = _lastFloatingBarsDirection != direction;
    if (debounce && directionChanged && now - _lastFloatingBarsDirectionChangedAt < _floatingBarsDirectionDebounceMs) {
      _pendingFloatingBarsDirection = direction;
      return;
    }

    _pendingFloatingBarsDirection = ScrollDirection.idle;
    _lastFloatingBarsDirection = direction;
    if (directionChanged) {
      _lastFloatingBarsDirectionChangedAt = now;
    }
    navigationHandler.floatingHeaderKey.currentState?.handleUserScrollDirection(direction);
  }

  bool _isAtScrollStart(ScrollMetrics metrics) {
    return metrics.pixels <= metrics.minScrollExtent + 0.5;
  }

  void _showFloatingBars() {
    _pendingFloatingBarsDirection = ScrollDirection.idle;
    if (_lastFloatingBarsDirection != ScrollDirection.forward) {
      _lastFloatingBarsDirectionChangedAt = DateTime.now().millisecondsSinceEpoch;
    }
    _lastFloatingBarsDirection = ScrollDirection.forward;
    navigationHandler.floatingHeaderKey.currentState?.show();
  }

  void settleFloatingBarsAfterScroll(ScrollNotification notification) {
    if (notification.depth != 0 || notification.metrics.axis != Axis.vertical) {
      return;
    }

    if (_isAtScrollStart(notification.metrics)) {
      _showFloatingBars();
      final controller = searchHandler.gridScrollController;
      // jumpTo emits scroll-end while already idle; show() has snapped it.
      if (!controller.hasClients || !controller.position.isScrollingNotifier.value) {
        return;
      }
    } else if (_pendingFloatingBarsDirection != ScrollDirection.idle) {
      // A short reversal may end before the debounce window expires.
      _updateFloatingBars(_pendingFloatingBarsDirection, debounce: false);
    }

    navigationHandler.floatingHeaderKey.currentState?.settleUserScrollDirection();
  }

  void viewerCallback() {
    // do cleanup after a delay to avoid animation stutter when leaving the viewer (especially when there are thousands of items)
    Future.delayed(const Duration(milliseconds: 500), () {
      for (final item in viewedItems) {
        if (item.toggleQuality.value) {
          item.toggleQuality.value = false;
        }
      }
      viewedItems.clear();
    });
  }

  void onViewerPageChanged(int index) {
    _rootViewerIndex = index;

    final currentFetched = searchHandler.currentFetchedOrNull;
    if (currentFetched == null || index >= currentFetched.length) return;
    viewedItems.add(currentFetched[index]);
    if (isMobile) {
      // Only recorded: see [pendingViewerIndex]. The grid moves once, when the
      // viewer route pops.
      pendingViewerIndex = index;
    } else {
      // don't auto scroll on viewed index change on desktop
      // the desktop viewer is inline, so there is no route pop to scroll on
    }
  }

  Future<void> onTap(int index) async {
    if (isMobile) {
      // protection from opening multiple viewers at once
      if (!isActive.value) {
        return;
      }

      viewedItemCleanupTimer?.cancel();
      viewedItemCleanupCount = 0;
      final currentFetched = searchHandler.currentFetchedOrNull;
      final currentTab = searchHandler.currentTabOrNull;
      if (currentFetched == null || currentTab == null || index >= currentFetched.length) return;

      viewedItems
        ..clear()
        ..add(currentFetched[index]);
      viewerHandler.setCurrent(currentFetched[index]);

      isActive.value = false;
      viewerHandler.showNotes.value = !settingsHandler.hideNotes;
      _rootViewerIndex = index;

      final viewerKey = GlobalKey(debugLabel: 'viewer-main');
      ViewerHandler.instance.addViewer(viewerKey);
      await Navigator.of(context).push(
        PageRouteBuilder(
          pageBuilder: (_, _, _) => GalleryViewPage(
            key: viewerKey,
            tab: currentTab,
            initialIndex: index,
            onPageChanged: onViewerPageChanged,
          ),
          opaque: false,
          transitionDuration: const Duration(milliseconds: 300),
          barrierColor: Colors.black26,
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            return const ZoomPageTransitionsBuilder().buildTransitions(
              MaterialPageRoute(
                builder: (_) => const SizedBox.shrink(),
              ), // is not used anywhere, but function requires it to get allowSnapshotting from it
              context,
              animation,
              secondaryAnimation,
              child,
            );
          },
        ),
      );

      _rootViewerIndex = null;
      viewerHandler.dropCurrent();

      viewedItemCleanupTimer = Timer.periodic(
        const Duration(milliseconds: 200),
        (_) {
          // workaround to forcefully clear the viewed item if it got set after we left the viewer (i.e. check after favouriting)
          if (viewerHandler.current.value != null) {
            viewerHandler.dropCurrent();
          }

          // run for 5s with 200ms interval
          if (viewedItemCleanupCount < 25) {
            viewedItemCleanupCount++;
          } else {
            viewedItemCleanupTimer?.cancel();
          }
        },
      );

      isActive.value = true;

      // reset notes to default state, defined in settings
      viewerHandler.showNotes.value = !settingsHandler.hideNotes;

      viewerCallback();

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showFloatingBars();
      });
    } else {
      final currentFetched = searchHandler.currentFetchedOrNull;
      if (currentFetched == null || index >= currentFetched.length) return;
      viewerHandler.setCurrent(currentFetched[index]);
    }
  }

  Future<void> onDoubleTap(int index) async {
    await searchHandler.currentTabOrNull?.toggleItemFavourite(index);
  }

  Future<void> onLongPress(int index) async {
    final currentFetched = searchHandler.currentFetchedOrNull;
    final currentTab = searchHandler.currentTabOrNull;
    final currentSelected = searchHandler.currentSelectedOrNull;
    if (currentFetched == null || currentTab == null || currentSelected == null || index >= currentFetched.length) {
      return;
    }

    final BooruItem item = currentFetched[index];
    await ServiceHandler.vibrate();

    if (currentSelected.contains(item)) {
      currentTab.selected.remove(item);
    } else {
      currentTab.selected.add(item);
    }
  }

  Future<void> onSecondaryTap(int index, BuildContext context) async {
    final currentFetched = searchHandler.currentFetchedOrNull;
    if (currentFetched == null || index >= currentFetched.length) return;
    final BooruItem item = currentFetched[index];
    await ClipboardUtils.copyImageToClipboard(item);
  }

  @override
  Widget build(BuildContext context) {
    // check if grid type changed when rebuilding the widget (must happen only on start and when saving settings)
    final bool newIsStaggered =
        settingsHandler.previewDisplay.isStaggered && (searchHandler.currentBooruHandlerOrNull?.hasSizeData ?? false);
    if (isStaggered != newIsStaggered) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        isStaggered = newIsStaggered;
        setState(() {});
      });
    }

    final bool changedOrientation = context.orientation != currentOrientation;
    if (changedOrientation && !isActive.value) {
      // try to keep the scroll position at currently viewed item when screen orientation changes
      currentOrientation = context.orientation;

      WidgetsBinding.instance.addPostFrameCallback((_) {
        final currentFetched = searchHandler.currentFetchedOrNull;
        if (currentFetched == null) return;

        final rootViewerIndex = _rootViewerIndex;
        final itemIndex = rootViewerIndex != null && rootViewerIndex >= 0 && rootViewerIndex < currentFetched.length
            ? rootViewerIndex
            : currentFetched.indexWhere(
                (item) => item.key == viewerHandler.current.value?.key,
              );
        if (itemIndex != -1) {
          // Jump rather than animate: this runs behind the viewer, where the
          // subtree is ticker-muted and an animation would only thaw on exit.
          final double? target = _targeter.estimatedOffsetForIndex(itemIndex);
          if (target != null && searchHandler.gridScrollController.hasClients) {
            searchHandler.gridScrollController.jumpTo(target);
          }
        }
      });
    }

    // One backdrop capture shared by the app bar, the bottom bar and the search
    // bar. Without this each BackdropFilter snapshots and blurs the scrolling
    // grid beneath it separately, every frame it moves. The filters do not
    // overlap each other (top bar vs. a non-overlapping bottom Column), which is
    // the condition for sharing a backdrop key.
    return BackdropGroup(
      child: Stack(
        alignment: Alignment.bottomCenter,
        children: [
          NotificationListener<ScrollNotification>(
            child: Scrollbar(
              controller: searchHandler.gridScrollController,
              interactive: true,
              thickness: 8,
              thumbVisibility: true,
              scrollbarOrientation: settingsHandler.handSide.value.isLeft
                  ? ScrollbarOrientation.left
                  : ScrollbarOrientation.right,
              child: RefreshIndicator(
                triggerMode: RefreshIndicatorTriggerMode.anywhere,
                displacement: 40,
                edgeOffset: MediaQuery.paddingOf(context).top + MainAppBar.height,
                strokeWidth: 4,
                color: Theme.of(context).colorScheme.secondary,
                onRefresh: () => searchHandler.searchAction(
                  searchHandler.currentTabOrNull?.tags ?? '',
                  null,
                ),
                child: Stack(
                  children: [
                    ValueListenableBuilder(
                      valueListenable: isActive,
                      builder: (context, isActive, child) {
                        // The viewer is pushed with `opaque: false`, so this whole
                        // route stays mounted underneath it -- and its animations
                        // kept running behind the viewer. `isActive` is the
                        // RouteAware signal for "something is on top of me"
                        // (didPushNext / didPopNext).
                        //
                        // TickerMode nests with AND semantics: an ancestor set to
                        // false mutes the subtree regardless of any inner
                        // TickerMode, so this covers the app bar's marquee and
                        // anything else here in one place.
                        return TickerMode(
                          enabled: isActive,
                          child: ShimmerWrap(
                            enabled: isActive && !SettingsHandler.instance.shitDevice,
                            child: child ?? const SizedBox.shrink(),
                          ),
                        );
                      },
                      child: Obx(() {
                        final currentFetched = searchHandler.currentFetchedOrNull;
                        final currentTab = searchHandler.currentTabOrNull;
                        final bool isLoadingAndNoItems =
                            searchHandler.isLoading.value && (currentFetched?.isEmpty ?? true);

                        if (isLoadingAndNoItems) {
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            // reset scroll position if in loading state
                            searchHandler.gridScrollController.jumpTo(0);
                          });
                        }

                        // If loading just finished but content doesn't fill the viewport,
                        // the NotificationListener won't fire (no scroll possible), so trigger next page here with a small delay.
                        if (!searchHandler.isLoading.value && (currentFetched?.isNotEmpty ?? false)) {
                          WidgetsBinding.instance.addPostFrameCallback((_) async {
                            if (searchHandler.gridScrollController.hasClients && !searchHandler.isLoading.value) {
                              final pos = searchHandler.gridScrollController.position;
                              final bool screenNotFilled = pos.extentBefore == 0 && pos.extentAfter == 0;
                              if (screenNotFilled) {
                                await Future.delayed(const Duration(milliseconds: 500));
                                unawaited(searchHandler.runSearch());
                              }
                            }
                          });
                        }

                        return CustomScrollView(
                          key: ValueKey('CustomScrollView-${searchHandler.currentTabId}'),
                          controller: searchHandler.gridScrollController,
                          physics: isLoadingAndNoItems
                              ? const NeverScrollableScrollPhysics()
                              : AlwaysScrollableScrollPhysics(
                                  parent: ScrollConfiguration.of(context).getScrollPhysics(context),
                                ),
                          shrinkWrap: false,
                          scrollCacheExtent: settingsHandler.shitDevice ? const .viewport(0.5) : const .viewport(1),
                          slivers: [
                            const MainAppBar(),
                            SliverPadding(
                              padding: const EdgeInsets.fromLTRB(10, 16, 10, 180),
                              sliver: Builder(
                                key: _gridSliverKey,
                                builder: (context) {
                                  if (isLoadingAndNoItems) {
                                    if (settingsHandler.shitDevice) {
                                      return const SliverToBoxAdapter(
                                        child: Center(
                                          child: CircularProgressIndicator(),
                                        ),
                                      );
                                    }

                                    return const ThumbnailsShimmerList();
                                  }

                                  if (currentTab == null) {
                                    return const SliverToBoxAdapter(child: SizedBox.shrink());
                                  }

                                  if (isStaggered) {
                                    return Obx(
                                      () => StaggeredBuilder(
                                        key: ValueKey('StaggeredBuilder-${searchHandler.currentTabId}'),
                                        tab: currentTab,
                                        scrollController: searchHandler.gridScrollController,
                                        onTap: onTap,
                                        onDoubleTap: onDoubleTap,
                                        onLongPress: onLongPress,
                                        onSecondaryTap: (i) => onSecondaryTap(i, context),
                                        onSelected: onLongPress,
                                      ),
                                    );
                                  }

                                  return Obx(
                                    () => GridBuilder(
                                      key: ValueKey('GridBuilder-${searchHandler.currentTabId}'),
                                      tab: currentTab,
                                      scrollController: searchHandler.gridScrollController,
                                      onTap: onTap,
                                      onDoubleTap: onDoubleTap,
                                      onLongPress: onLongPress,
                                      onSecondaryTap: (i) => onSecondaryTap(i, context),
                                      onSelected: onLongPress,
                                    ),
                                  );
                                },
                              ),
                            ),
                          ],
                        );
                      }),
                    ),
                    Positioned(
                      bottom: MediaQuery.viewPaddingOf(context).bottom + 120,
                      right: settingsHandler.scrollGridButtonsPosition.isRight
                          ? MediaQuery.sizeOf(context).width * 0.07
                          : null,
                      left: settingsHandler.scrollGridButtonsPosition.isLeft
                          ? MediaQuery.sizeOf(context).width * 0.07
                          : null,
                      child: Obx(() {
                        final bool isLoadingAndNoItems =
                            searchHandler.isLoading.value && (searchHandler.currentFetchedOrNull?.isEmpty ?? true);

                        return AnimatedSwitcher(
                          duration: const Duration(milliseconds: 300),
                          child:
                              (isLoadingAndNoItems ||
                                  settingsHandler.scrollGridButtonsPosition.isDisabled ||
                                  settingsHandler.appMode.value.isDesktop == true)
                              ? const SizedBox.shrink()
                              : const WaterfallScrollButtons(),
                        );
                      }),
                    ),
                  ],
                ),
              ),
            ),
            onNotification: (notif) {
              if (notif.depth != 0 || notif.metrics.axis != Axis.vertical) {
                return false;
              }
              if (notif is ScrollStartNotification) {
                navigationHandler.floatingHeaderKey.currentState?.handleScrollStart();
              }
              if (notif is ScrollUpdateNotification || notif is OverscrollNotification) {
                syncFloatingBarsWithScroll(notif);
                searchHandler.recordScrollPosition();

                // print('SCROLL NOTIFICATION');
                // print(searchHandler.gridScrollController.position.maxScrollExtent);
                // print(notif.metrics); // pixels before viewport, in viewport, after viewport

                final bool isNotAtStart = notif.metrics.pixels > 0;
                final bool isAtOrNearEdge =
                    notif.metrics.atEdge ||
                    notif.metrics.pixels >
                        (notif.metrics.maxScrollExtent -
                            (notif.metrics.extentInside *
                                2)); // trigger new page when at edge or scroll position is less than 2 viewports
                final bool isScreenFilled =
                    notif.metrics.extentBefore != 0 ||
                    notif.metrics.extentAfter != 0; // for cases when first page doesn't fill the screen

                if (!searchHandler.isLoading.value) {
                  if (!isScreenFilled || (isNotAtStart && isAtOrNearEdge)) {
                    searchHandler.runSearch();
                  }
                }
              }
              if (notif is ScrollEndNotification) {
                settleFloatingBarsAfterScroll(notif);
                searchHandler.recordScrollPosition();
                // Only on settle: jumpTo() calls goIdle(), which would kill an
                // in-flight drag or fling. With the finger off the screen there is
                // by definition nothing under it to move.
                _trimmer.maybeTrim(nowMs: DateTime.now().millisecondsSinceEpoch);
              }
              return true;
            },
          ),
          //
          RepaintBoundary(
            child: WaterfallBottomBar(
              key: navigationHandler.bottomBarKey,
            ),
          ),
        ],
      ),
    );
  }
}

class WaterfallScrollButtons extends StatelessWidget {
  const WaterfallScrollButtons({super.key});

  Future<void> pageScroll(bool forward) async {
    final scrollController = SearchHandler.instance.gridScrollController;

    if (scrollController.hasClients && scrollController.position.hasContentDimensions) {
      double nextOffset = 0;
      final double viewportHeight = scrollController.position.viewportDimension;
      final double leftTillClosestEdge = max(
        0,
        min(
          scrollController.position.maxScrollExtent - scrollController.offset,
          scrollController.offset,
        ),
      );
      final bool closestEdgeIsTop =
          scrollController.offset < scrollController.position.maxScrollExtent - scrollController.offset;
      if (leftTillClosestEdge < viewportHeight / 2 &&
          ((forward && !closestEdgeIsTop) || (!forward && closestEdgeIsTop))) {
        nextOffset = (forward ? 1 : -1) * (leftTillClosestEdge * 1.2);
      } else {
        nextOffset = (scrollController.position.viewportDimension * 0.9) * (forward ? 1 : -1);
      }

      await scrollController.animateTo(
        scrollController.offset + nextOffset,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.33),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          children: [
            LongPressRepeater(
              onStart: () async => pageScroll(false),
              startDelay: 300,
              child: InkWell(
                borderRadius: const BorderRadius.vertical(top: Radius.circular(10)),
                onTap: () => pageScroll(false),
                child: SizedBox(
                  width: kMinInteractiveDimension,
                  height: kMinInteractiveDimension,
                  child: Icon(
                    Icons.arrow_upward,
                    size: 30,
                    color: Theme.of(context).colorScheme.onPrimaryContainer.withValues(alpha: 0.5),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            LongPressRepeater(
              onStart: () async => pageScroll(true),
              startDelay: 300,
              child: InkWell(
                borderRadius: const BorderRadius.vertical(bottom: Radius.circular(10)),
                onTap: () => pageScroll(true),
                child: SizedBox(
                  width: kMinInteractiveDimension,
                  height: kMinInteractiveDimension,
                  child: Icon(
                    Icons.arrow_downward,
                    size: 30,
                    color: Theme.of(context).colorScheme.onPrimaryContainer.withValues(alpha: 0.5),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
