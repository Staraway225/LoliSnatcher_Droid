import 'dart:ui' show FlutterView;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'package:lolisnatcher/src/data/constants.dart';
import 'package:lolisnatcher/src/handlers/search_handler.dart';
import 'package:lolisnatcher/src/handlers/settings_handler.dart';
import 'package:lolisnatcher/src/utils/perf_tracer.dart';
import 'package:lolisnatcher/src/utils/request_limiter.dart';
import 'package:lolisnatcher/src/widgets/common/loading_progress.dart';

/// Connects [PerfTracer] to the app's existing state.
///
/// Kept out of `perf_tracer.dart` so the tracer itself stays dependency-free and
/// unit-testable, and so the counters it reports are read from wherever they
/// already live rather than duplicated.
class PerfTracerBindings {
  const PerfTracerBindings._();

  static void install() {
    PerfTracer.metaProvider = _meta;
    PerfTracer.sampleProvider = _sample;
    if (kProfileMode) {
      _enableProfileInstrumentation();
      PerfTracer.widgetStatsProvider = _widgetStats;
    }
  }

  static Map<String, Object?> _meta() {
    final SettingsHandler settings = SettingsHandler.instance;
    final FlutterView? view = WidgetsBinding.instance.platformDispatcher.views.firstOrNull;

    return <String, Object?>{
      'appVersion': '${Constants.updateInfo.versionName}+${Constants.updateInfo.buildNumber}',
      'dpr': view?.devicePixelRatio,
      'screenW': view == null ? null : view.physicalSize.width / view.devicePixelRatio,
      'screenH': view == null ? null : view.physicalSize.height / view.devicePixelRatio,
      // Everything below changes the workload, so a trace is only comparable to
      // another trace with the same values.
      'settings': <String, Object?>{
        'previewMode': settings.previewMode.toJson(),
        'previewDisplay': settings.previewDisplay.toJson(),
        'portraitColumns': settings.portraitColumns,
        'landscapeColumns': settings.landscapeColumns,
        'itemLimit': settings.itemLimit,
        'scrollCachePageLimit': settings.scrollCachePageLimit,
        'shitDevice': settings.shitDevice,
        'thumbnailCache': settings.thumbnailCache,
        'blurImages': settings.blurImages,
        'disableImageScaling': settings.disableImageScaling,
        'perfTraceHud': settings.perfTraceHud,
      },
    };
  }

  static Map<String, Object?> _sample() {
    final SearchHandler search = SearchHandler.instance;
    final SearchTab? tab = search.currentTabOrNull;

    return <String, Object?>{
      'netActive': RequestLimiter.activeCount,
      'netQueued': RequestLimiter.queuedCount,
      'netPausedHosts': RequestLimiter.pausedHostCount,
      'loadingTiles': LoadingProgressTracker.activeTrackerCount,
      'pageNum': search.pageNum.value,
      'isLoading': search.isLoading.value,
      'fetched': tab?.booruHandler.fetched.length ?? 0,
      'filtered': tab?.booruHandler.filteredFetched.length ?? 0,
      'appended': tab?.booruHandler.appendedItemsCount ?? 0,
      'trimmedItems': tab?.gridTrim.trimmedItems ?? 0,
      'trimmedExtent': tab?.gridTrim.trimmedExtent.round() ?? 0,
      'scrollPx': search.gridScrollController.hasClients ? search.gridScrollController.offset.round() : 0,
    };
  }

  /// Tier 2: per-widget build/layout/paint attribution.
  ///
  /// These flags are `!kReleaseMode`-gated in the framework, and
  /// `FlutterTimeline.debugCollectionEnabled` throws a `StateError` in release --
  /// hence the `kProfileMode` guard at the call site.
  ///
  /// Uses `debugProfileBuildsEnabled`, **not**
  /// `debugProfileBuildsEnabledUserWidgets`, which depends on
  /// `--track-widget-creation` and so does nothing in an AOT profile build.
  static void _enableProfileInstrumentation() {
    try {
      FlutterTimeline.debugCollectionEnabled = true;
      debugProfileBuildsEnabled = true;
      debugProfileLayoutsEnabled = true;
      debugProfilePaintsEnabled = true;
    } catch (_) {
      // Release, or a build where these are unavailable: Tier 2 is simply absent.
    }
  }

  static Map<String, Object?>? _widgetStats() {
    if (!kProfileMode) {
      return null;
    }
    try {
      final AggregatedTimings timings = FlutterTimeline.debugCollect();
      FlutterTimeline.debugReset();

      final List<AggregatedTimedBlock> blocks = List<AggregatedTimedBlock>.of(
        timings.aggregatedBlocks,
      )..sort((AggregatedTimedBlock a, AggregatedTimedBlock b) => b.duration.compareTo(a.duration));

      if (blocks.isEmpty) {
        return null;
      }

      return <String, Object?>{
        // Top 25 only: the tail is noise and this is written every sample.
        'blocks': <Map<String, Object?>>[
          for (final AggregatedTimedBlock b in blocks.take(25))
            <String, Object?>{
              'name': b.name,
              'us': b.duration.round(),
              'n': b.count,
            },
        ],
      };
    } catch (_) {
      return null;
    }
  }
}
