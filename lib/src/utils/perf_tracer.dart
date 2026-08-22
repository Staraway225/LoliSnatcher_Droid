import 'dart:async';
import 'dart:convert';
import 'dart:developer' show NativeRuntime;
import 'dart:io';
import 'dart:ui' show FramePhase, FrameTiming;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/scheduler.dart';

import 'package:lolisnatcher/src/handlers/service_handler.dart';

/// In-app performance tracer.
///
/// Exists because the remaining battery question ("is this GPU draw?") cannot be
/// answered by inspection, and DevTools cannot be attached: the app is sideloaded
/// onto an iPhone with no Mac and no USB debugging. So the measurement has to be
/// self-contained and exported as a file the user can retrieve via the Files app.
///
/// Design constraints, all verified against the pinned Flutter 3.44.6 SDK and its
/// vendored engine sources. Each of these would silently corrupt the results:
///
/// * **Sampling uses [Timer.periodic], never a `Ticker`.** `Ticker.scheduleTick`
///   calls `SchedulerBinding.scheduleFrame()` on every tick, which would hold the
///   display pipeline awake and make any idle-power reading meaningless. (The
///   existing `ImageStats` HUD is Ticker-based -- do not copy that part of it.)
/// * **`FrameTiming.toString()` is never called.** `--delete-tostring-package-uri`
///   strips `dart:ui` and `package:flutter` `toString` bodies in *both* profile and
///   release, so it would emit `Instance of '...'`. Getters are read individually.
/// * **`dart:developer`'s `Timeline` is not used.** Release AOT is a Dart PRODUCT
///   build with the timeline subsystem compiled out; events would go nowhere.
/// * **The raster-cache fields are not exported.** iOS uses Impeller, whose surface
///   returns `EnableRasterCache() == false`, so `layerCacheCount`, `layerCacheBytes`,
///   `pictureCacheCount` and `pictureCacheBytes` are hard zero on every frame.
///
/// [FrameTiming.rasterDuration] is therefore the only GPU signal available; there is
/// no draw-call count reachable from Dart on any platform.
///
/// Everything is static and every public hook returns immediately unless [isTracing],
/// so instrumentation costs one predictable branch when tracing is off.
class PerfTracer {
  const PerfTracer._();

  /// Frame data arrives batched from the engine -- up to ~100 frames, and up to 1s
  /// late in release (100ms in profile). Never do I/O in the timings callback.
  static const int _flushThresholdLines = 256;
  static const Duration _sampleInterval = Duration(seconds: 2);
  static const Duration _flushInterval = Duration(seconds: 5);

  static bool _tracing = false;
  static bool get isTracing => _tracing;

  static File? _file;
  static IOSink? _sink;
  static final List<String> _pending = <String>[];
  static Timer? _sampleTimer;
  static Timer? _flushTimer;
  static Future<void> _writeChain = Future<void>.value();

  static int _startedAtMs = 0;
  static int _frameCount = 0;
  static int _droppedLines = 0;

  /// Live values for the HUD. Updated by the sampler only, so the HUD never has to
  /// poll anything itself.
  static final ValueNotifier<int> hudFrames = ValueNotifier<int>(0);
  static final ValueNotifier<double> hudBuildMs = ValueNotifier<double>(0);
  static final ValueNotifier<double> hudRasterMs = ValueNotifier<double>(0);
  static final ValueNotifier<double> hudFps = ValueNotifier<double>(0);
  static final ValueNotifier<int> hudRssMb = ValueNotifier<int>(0);

  // Rolling accumulators between samples, so the HUD shows recent behaviour rather
  // than a lifetime average.
  static int _windowFrames = 0;
  static int _windowBuildUs = 0;
  static int _windowRasterUs = 0;
  static int _lastSampleMs = 0;

  /// Counters fed by the instrumentation hooks. Reset per trace.
  static int _downloads = 0;
  static int _downloadBytes = 0;
  static int _downloadMs = 0;
  static int _cacheHits = 0;
  static int _decodes = 0;
  static int _decodeMs = 0;
  static int _pageFetches = 0;
  static int _pageFetchMs = 0;
  static int _dbQueries = 0;
  static int _dbQueryMs = 0;
  static int _trims = 0;

  /// Extra key/value pairs merged into every `sample` record. Set by the app so
  /// this file needs no imports of the handlers it reports on.
  static Map<String, Object?> Function()? sampleProvider;

  /// Extra key/value pairs merged into the `meta` record.
  static Map<String, Object?> Function()? metaProvider;

  /// Profile-only widget attribution. Null in release.
  static Map<String, Object?>? Function()? widgetStatsProvider;

  static Future<Directory> _traceDir() async {
    final String root = await ServiceHandler.getExtDir();
    // Documents/ is the only container iOS exposes to the Files app
    // (UIFileSharingEnabled + LSSupportsOpeningDocumentsInPlace), and the app's
    // config already lives beside this. The log directory is NOT usable: it sits
    // under Library/Application Support, which is invisible to the user.
    final Directory dir = Directory('$root/LoliSnatcher/traces');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// Existing trace files, newest first.
  static Future<List<File>> listTraces() async {
    try {
      final Directory dir = await _traceDir();
      final List<File> files = await dir
          .list()
          .where((FileSystemEntity e) => e is File && e.path.endsWith('.jsonl'))
          .cast<File>()
          .toList();
      files.sort((File a, File b) => b.path.compareTo(a.path));
      return files;
    } catch (_) {
      return <File>[];
    }
  }

  static Future<File?> start() async {
    if (_tracing) {
      return _file;
    }

    try {
      final Directory dir = await _traceDir();
      final String stamp = DateTime.now().toIso8601String().replaceAll(':', '-').replaceAll('.', '-');
      _file = File('${dir.path}/losn-trace-$stamp.jsonl');
      _sink = _file!.openWrite(mode: FileMode.writeOnly);
    } catch (_) {
      _file = null;
      _sink = null;
      return null;
    }

    _resetCounters();
    _startedAtMs = DateTime.now().millisecondsSinceEpoch;
    _lastSampleMs = _startedAtMs;
    _tracing = true;

    _writeLine(<String, Object?>{
      't': 'meta',
      'startedAt': DateTime.now().toIso8601String(),
      'mode': kReleaseMode
          ? 'release'
          : kProfileMode
          ? 'profile'
          : 'debug',
      'buildId': _buildId(),
      'platform': Platform.operatingSystem,
      'osVersion': Platform.operatingSystemVersion,
      'dartVersion': Platform.version,
      ...?metaProvider?.call(),
    });

    // Registered only while tracing, so there is genuinely no callback in the
    // engine's report path when tracing is off.
    SchedulerBinding.instance.addTimingsCallback(_onTimings);

    _sampleTimer = Timer.periodic(_sampleInterval, (_) => _sample());
    _flushTimer = Timer.periodic(_flushInterval, (_) => unawaited(flush()));

    return _file;
  }

  static Future<File?> stop() async {
    if (!_tracing) {
      return _file;
    }
    _tracing = false;

    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    _sampleTimer?.cancel();
    _sampleTimer = null;
    _flushTimer?.cancel();
    _flushTimer = null;

    _sample();
    _writeLine(<String, Object?>{
      't': 'end',
      'endedAt': DateTime.now().toIso8601String(),
      'durationMs': DateTime.now().millisecondsSinceEpoch - _startedAtMs,
      'frames': _frameCount,
      'droppedLines': _droppedLines,
    });

    await flush();
    try {
      await _sink?.flush();
      await _sink?.close();
    } catch (_) {}
    _sink = null;
    return _file;
  }

  static String? _buildId() {
    try {
      // Available for AOT builds; null in JIT. Ties a trace to a specific IPA.
      return NativeRuntime.buildId;
    } catch (_) {
      return null;
    }
  }

  static void _resetCounters() {
    _frameCount = 0;
    _droppedLines = 0;
    _windowFrames = 0;
    _windowBuildUs = 0;
    _windowRasterUs = 0;
    _downloads = 0;
    _downloadBytes = 0;
    _downloadMs = 0;
    _cacheHits = 0;
    _decodes = 0;
    _decodeMs = 0;
    _pageFetches = 0;
    _pageFetchMs = 0;
    _dbQueries = 0;
    _dbQueryMs = 0;
    _trims = 0;
  }

  static void _onTimings(List<FrameTiming> timings) {
    if (!_tracing || timings.isEmpty) {
      return;
    }

    final List<List<int>> rows = <List<int>>[];
    for (final FrameTiming t in timings) {
      // Read getters individually; toString() is stripped from dart:ui in AOT.
      final int build = t.buildDuration.inMicroseconds;
      final int raster = t.rasterDuration.inMicroseconds;
      _windowFrames++;
      _windowBuildUs += build;
      _windowRasterUs += raster;
      _frameCount++;
      rows.add(<int>[
        t.frameNumber,
        build,
        raster,
        t.vsyncOverhead.inMicroseconds,
        t.totalSpan.inMicroseconds,
        // The only phase on a real-time epoch; everything else is an arbitrary
        // monotonic clock that cannot be correlated with DateTime.
        t.timestampInMicroseconds(FramePhase.rasterFinishWallTime),
      ]);
    }

    _writeLine(<String, Object?>{'t': 'frame', 'd': rows});
  }

  static void _sample() {
    if (!_tracing) {
      return;
    }

    final int now = DateTime.now().millisecondsSinceEpoch;
    final int elapsed = now - _lastSampleMs;
    final double fps = elapsed > 0 ? (_windowFrames * 1000) / elapsed : 0;
    final double avgBuild = _windowFrames > 0 ? _windowBuildUs / _windowFrames / 1000 : 0;
    final double avgRaster = _windowFrames > 0 ? _windowRasterUs / _windowFrames / 1000 : 0;

    int rss = 0;
    int maxRss = 0;
    try {
      // On iOS this is Mach resident_size, not the phys_footprint jetsam uses.
      // Trend and peak only -- never an absolute headroom claim.
      rss = ProcessInfo.currentRss;
      maxRss = ProcessInfo.maxRss;
    } catch (_) {}

    final ImageCache cache = PaintingBinding.instance.imageCache;

    _writeLine(<String, Object?>{
      't': 'sample',
      'ms': now - _startedAtMs,
      'fps': double.parse(fps.toStringAsFixed(2)),
      'buildMs': double.parse(avgBuild.toStringAsFixed(3)),
      'rasterMs': double.parse(avgRaster.toStringAsFixed(3)),
      'frames': _frameCount,
      'rss': rss,
      'maxRss': maxRss,
      'imgCount': cache.currentSize,
      'imgBytes': cache.currentSizeBytes,
      'imgLive': cache.liveImageCount,
      'imgPending': cache.pendingImageCount,
      'downloads': _downloads,
      'downloadBytes': _downloadBytes,
      'downloadMs': _downloadMs,
      'cacheHits': _cacheHits,
      'decodes': _decodes,
      'decodeMs': _decodeMs,
      'pageFetches': _pageFetches,
      'pageFetchMs': _pageFetchMs,
      'dbQueries': _dbQueries,
      'dbQueryMs': _dbQueryMs,
      'trims': _trims,
      ...?sampleProvider?.call(),
    });

    final Map<String, Object?>? widgets = widgetStatsProvider?.call();
    if (widgets != null && widgets.isNotEmpty) {
      _writeLine(<String, Object?>{'t': 'widgets', 'ms': now - _startedAtMs, ...widgets});
    }

    hudFrames.value = _frameCount;
    hudFps.value = double.parse(fps.toStringAsFixed(1));
    hudBuildMs.value = double.parse(avgBuild.toStringAsFixed(2));
    hudRasterMs.value = double.parse(avgRaster.toStringAsFixed(2));
    hudRssMb.value = rss ~/ (1024 * 1024);

    _windowFrames = 0;
    _windowBuildUs = 0;
    _windowRasterUs = 0;
    _lastSampleMs = now;
  }

  static void _writeLine(Map<String, Object?> record) {
    if (_sink == null) {
      return;
    }
    // Hard cap so a runaway trace cannot fill the device.
    if (_pending.length > 20000) {
      _droppedLines++;
      return;
    }
    _pending.add(jsonEncode(record));
    if (_pending.length >= _flushThresholdLines) {
      unawaited(flush());
    }
  }

  /// Serialised so concurrent flushes cannot interleave partial lines.
  static Future<void> flush() {
    final IOSink? sink = _sink;
    if (sink == null || _pending.isEmpty) {
      return _writeChain;
    }
    final List<String> batch = List<String>.of(_pending);
    _pending.clear();
    return _writeChain = _writeChain
        .then((_) async {
          sink.write('${batch.join('\n')}\n');
          await sink.flush();
        })
        .catchError((Object _) {});
  }

  // ---- instrumentation hooks ------------------------------------------------
  // Each returns immediately when tracing is off.

  static void recordDownload({
    required int bytes,
    required int millis,
    required bool fromCache,
  }) {
    if (!_tracing) {
      return;
    }
    _downloads++;
    _downloadBytes += bytes;
    _downloadMs += millis;
    if (fromCache) {
      _cacheHits++;
    }
  }

  static void recordDecode(int millis) {
    if (!_tracing) {
      return;
    }
    _decodes++;
    _decodeMs += millis;
  }

  static void recordPageFetch({required int millis, required int items}) {
    if (!_tracing) {
      return;
    }
    _pageFetches++;
    _pageFetchMs += millis;
    _writeLine(<String, Object?>{
      't': 'event',
      'k': 'page',
      'ms': DateTime.now().millisecondsSinceEpoch - _startedAtMs,
      'durMs': millis,
      'items': items,
    });
  }

  static void recordDbQuery(int millis) {
    if (!_tracing) {
      return;
    }
    _dbQueries++;
    _dbQueryMs += millis;
  }

  static void recordTrim({required int removed, required double extent}) {
    if (!_tracing) {
      return;
    }
    _trims++;
    _writeLine(<String, Object?>{
      't': 'event',
      'k': 'trim',
      'ms': DateTime.now().millisecondsSinceEpoch - _startedAtMs,
      'removed': removed,
      'extent': double.parse(extent.toStringAsFixed(1)),
    });
  }

  @visibleForTesting
  static void resetForTests() {
    _tracing = false;
    _sink = null;
    _file = null;
    _pending.clear();
    _sampleTimer?.cancel();
    _sampleTimer = null;
    _flushTimer?.cancel();
    _flushTimer = null;
    _resetCounters();
  }

  @visibleForTesting
  static int get pendingLineCount => _pending.length;

  @visibleForTesting
  static int get frameCount => _frameCount;
}
