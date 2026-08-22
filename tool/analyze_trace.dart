// Offline analyser for the traces PerfTracer writes on device.
//
// Usage: fvm dart run tool/analyze_trace.dart <trace.jsonl>
//
// The question this exists to answer first is "raster or build?" -- i.e. whether
// the remaining battery cost is GPU-side or Dart-side. Everything else is
// supporting evidence.
//
// Deliberately dependency-free so it runs with plain `dart run`.

import 'dart:convert';
import 'dart:io';

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run tool/analyze_trace.dart <trace.jsonl>');
    exitCode = 64;
    return;
  }

  final File file = File(args.first);
  if (!file.existsSync()) {
    stderr.writeln('no such file: ${args.first}');
    exitCode = 66;
    return;
  }

  final Trace trace = Trace.parse(file.readAsLinesSync());
  stdout.write(trace.report());
}

class Trace {
  Trace(this.meta, this.frames, this.samples, this.events, this.widgets, this.end, this.malformed);

  factory Trace.parse(List<String> lines) {
    Map<String, dynamic> meta = <String, dynamic>{};
    Map<String, dynamic> end = <String, dynamic>{};
    final List<FrameRow> frames = <FrameRow>[];
    final List<Map<String, dynamic>> samples = <Map<String, dynamic>>[];
    final List<Map<String, dynamic>> events = <Map<String, dynamic>>[];
    final Map<String, ({int us, int count})> widgets = <String, ({int us, int count})>{};
    int malformed = 0;

    for (final String line in lines) {
      if (line.trim().isEmpty) continue;
      Map<String, dynamic> record;
      try {
        record = jsonDecode(line) as Map<String, dynamic>;
      } catch (_) {
        // A trace can be truncated if the app was killed mid-flush; that is
        // expected and must not abort the analysis.
        malformed++;
        continue;
      }

      switch (record['t']) {
        case 'meta':
          meta = record;
        case 'end':
          end = record;
        case 'sample':
          samples.add(record);
        case 'event':
          events.add(record);
        case 'frame':
          for (final dynamic row in (record['d'] as List<dynamic>? ?? <dynamic>[])) {
            final List<dynamic> r = row as List<dynamic>;
            if (r.length < 6) {
              malformed++;
              continue;
            }
            frames.add(
              FrameRow(
                number: r[0] as int,
                buildUs: r[1] as int,
                rasterUs: r[2] as int,
                vsyncUs: r[3] as int,
                totalUs: r[4] as int,
                wallUs: r[5] as int,
              ),
            );
          }
        case 'widgets':
          for (final dynamic b in (record['blocks'] as List<dynamic>? ?? <dynamic>[])) {
            final Map<String, dynamic> block = b as Map<String, dynamic>;
            final String name = block['name'] as String;
            final ({int us, int count}) prev = widgets[name] ?? (us: 0, count: 0);
            widgets[name] = (
              us: prev.us + (block['us'] as int),
              count: prev.count + (block['n'] as int),
            );
          }
      }
    }

    return Trace(meta, frames, samples, events, widgets, end, malformed);
  }

  final Map<String, dynamic> meta;
  final List<FrameRow> frames;
  final List<Map<String, dynamic>> samples;
  final List<Map<String, dynamic>> events;
  final Map<String, ({int us, int count})> widgets;
  final Map<String, dynamic> end;
  final int malformed;

  static double percentile(List<int> sorted, double p) {
    if (sorted.isEmpty) return 0;
    final int i = ((sorted.length - 1) * p).round().clamp(0, sorted.length - 1);
    return sorted[i] / 1000;
  }

  String report() {
    final StringBuffer out = StringBuffer();
    void h(String title) => out.writeln('\n=== $title ===');

    h('trace');
    out.writeln('file mode      : ${meta['mode'] ?? 'unknown'}');
    out.writeln('app            : ${meta['appVersion'] ?? '?'}  build ${meta['buildId'] ?? '?'}');
    out.writeln('platform       : ${meta['platform'] ?? '?'} ${meta['osVersion'] ?? ''}');
    final Object? settings = meta['settings'];
    if (settings is Map) {
      out.writeln('settings       : ${jsonEncode(settings)}');
    }
    if (malformed > 0) {
      out.writeln('malformed rows : $malformed (truncated trace is normal if the app was killed)');
    }

    if (frames.isEmpty) {
      out.writeln('\nNo frame data. Either tracing never started, or the app produced no frames.');
      return out.toString();
    }

    // Wall clock comes only from rasterFinishWallTime; every other phase is on an
    // arbitrary monotonic epoch.
    final int firstWall = frames.first.wallUs;
    final int lastWall = frames.last.wallUs;
    final double elapsedS = (lastWall - firstWall) / 1e6;

    final List<int> build = frames.map((FrameRow f) => f.buildUs).toList()..sort();
    final List<int> raster = frames.map((FrameRow f) => f.rasterUs).toList()..sort();
    final List<int> total = frames.map((FrameRow f) => f.totalUs).toList()..sort();

    final int sumBuild = build.fold(0, (int a, int b) => a + b);
    final int sumRaster = raster.fold(0, (int a, int b) => a + b);

    h('frames');
    out.writeln('count          : ${frames.length}');
    out.writeln('elapsed        : ${elapsedS.toStringAsFixed(1)}s');
    out.writeln('achieved fps   : ${(frames.length / (elapsedS == 0 ? 1 : elapsedS)).toStringAsFixed(1)}');
    out.writeln('');
    out.writeln('                    p50      p90      p99      max');
    out.writeln('build ms      : ${_row(build)}');
    out.writeln('raster ms     : ${_row(raster)}');
    out.writeln('total ms      : ${_row(total)}');

    h('where the time goes');
    final double buildMs = sumBuild / 1000;
    final double rasterMs = sumRaster / 1000;
    out.writeln('total build    : ${buildMs.toStringAsFixed(0)} ms');
    out.writeln('total raster   : ${rasterMs.toStringAsFixed(0)} ms');
    final double ratio = buildMs == 0 ? double.infinity : rasterMs / buildMs;
    out.writeln('raster / build : ${ratio.isFinite ? ratio.toStringAsFixed(2) : 'inf'}');
    out.writeln(
      ratio > 1.5
          ? '  => GPU-bound. Raster dominates; look at layers, blurs, saveLayer, overdraw.'
          : ratio < 0.67
          ? '  => CPU-bound. Build dominates; look at widget rebuilds (run the profile IPA).'
          : '  => Balanced. Neither side clearly dominates.',
    );

    // Budgets: 120Hz ProMotion is 8.33ms, 60Hz is 16.67ms.
    final int over8 = total.where((int t) => t > 8333).length;
    final int over16 = total.where((int t) => t > 16667).length;
    h('jank');
    out.writeln('> 8.33ms (120Hz): $over8  (${_pct(over8, frames.length)})');
    out.writeln('> 16.67ms (60Hz): $over16  (${_pct(over16, frames.length)})');

    if (samples.isNotEmpty) {
      h('memory and caches');
      final Map<String, dynamic> first = samples.first;
      final Map<String, dynamic> last = samples.last;
      out.writeln('rss     start/end/peak : ${_mb(first['rss'])} / ${_mb(last['rss'])} / ${_mb(last['maxRss'])}');
      out.writeln('img cache count start/end: ${first['imgCount']} / ${last['imgCount']}');
      out.writeln('img cache bytes start/end: ${_mb(first['imgBytes'])} / ${_mb(last['imgBytes'])}');
      out.writeln('img live       start/end : ${first['imgLive']} / ${last['imgLive']}');

      h('work totals');
      final int downloads = _i(last['downloads']);
      final int hits = _i(last['cacheHits']);
      out.writeln('downloads      : $downloads  (${_mb(last['downloadBytes'])}, ${_i(last['downloadMs'])} ms)');
      out.writeln('cache hits     : $hits  (${_pct(hits, downloads)})');
      out.writeln('decodes        : ${_i(last['decodes'])}  (${_i(last['decodeMs'])} ms)');
      out.writeln('page fetches   : ${_i(last['pageFetches'])}  (${_i(last['pageFetchMs'])} ms)');
      out.writeln('db queries     : ${_i(last['dbQueries'])}  (${_i(last['dbQueryMs'])} ms)');
      out.writeln('trims          : ${_i(last['trims'])}');
      out.writeln('pages reached  : ${_i(last['pageNum'])}');
      out.writeln(
        'peak net queue : ${samples.map((Map<String, dynamic> s) => _i(s['netQueued'])).fold(0, (int a, int b) => a > b ? a : b)}',
      );
      out.writeln(
        'rate-limit hits: ${samples.map((Map<String, dynamic> s) => _i(s['netPausedHosts'])).fold(0, (int a, int b) => a > b ? a : b)}',
      );

      // An idle tail that still produces frames is the clearest battery smell.
      h('idle behaviour');
      final List<Map<String, dynamic>> tail = samples.length > 5 ? samples.sublist(samples.length - 5) : samples;
      for (final Map<String, dynamic> s in tail) {
        out.writeln(
          '  t=${_i(s['ms']) ~/ 1000}s  fps=${s['fps']}  build=${s['buildMs']}ms  raster=${s['rasterMs']}ms',
        );
      }
      out.writeln('  (fps ~0 at rest is correct; sustained fps while idle is a bug)');
    }

    if (widgets.isNotEmpty) {
      h('widget attribution (profile build only)');
      final List<MapEntry<String, ({int us, int count})>> sorted = widgets.entries.toList()
        ..sort(
          (MapEntry<String, ({int us, int count})> a, MapEntry<String, ({int us, int count})> b) =>
              b.value.us.compareTo(a.value.us),
        );
      out.writeln('  ms      count   name');
      for (final MapEntry<String, ({int us, int count})> e in sorted.take(20)) {
        out.writeln(
          '  ${(e.value.us / 1000).toStringAsFixed(1).padLeft(8)} ${e.value.count.toString().padLeft(7)}   ${e.key}',
        );
      }
    }

    final List<Map<String, dynamic>> pageEvents = events.where((Map<String, dynamic> e) => e['k'] == 'page').toList();
    if (pageEvents.isNotEmpty) {
      final List<int> durs = pageEvents.map((Map<String, dynamic> e) => _i(e['durMs'])).toList()..sort();
      h('page appends');
      out.writeln('count          : ${pageEvents.length}');
      out.writeln(
        'ms p50/p90/max : ${durs[durs.length ~/ 2]} / ${durs[(durs.length * 0.9).floor().clamp(0, durs.length - 1)]} / ${durs.last}',
      );
    }

    return out.toString();
  }

  String _row(List<int> sorted) =>
      '${percentile(sorted, 0.5).toStringAsFixed(2).padLeft(8)} '
      '${percentile(sorted, 0.9).toStringAsFixed(2).padLeft(8)} '
      '${percentile(sorted, 0.99).toStringAsFixed(2).padLeft(8)} '
      '${(sorted.last / 1000).toStringAsFixed(2).padLeft(8)}';

  static int _i(Object? v) => v is int ? v : 0;

  static String _mb(Object? v) => '${(_i(v) / 1024 / 1024).toStringAsFixed(1)}MB';

  static String _pct(int part, int whole) => whole == 0 ? '0%' : '${(part * 100 / whole).toStringAsFixed(1)}%';
}

class FrameRow {
  const FrameRow({
    required this.number,
    required this.buildUs,
    required this.rasterUs,
    required this.vsyncUs,
    required this.totalUs,
    required this.wallUs,
  });

  final int number;
  final int buildUs;
  final int rasterUs;
  final int vsyncUs;
  final int totalUs;
  final int wallUs;
}
