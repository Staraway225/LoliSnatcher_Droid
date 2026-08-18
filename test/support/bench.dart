import 'dart:io';

/// Minimal benchmark harness. No dependencies beyond `dart:core` on purpose --
/// `benchmark_harness` is not in `dev_dependencies` and is not worth adding for
/// this.
class BenchResult {
  const BenchResult({
    required this.name,
    required this.best,
    required this.median,
    required this.opCount,
  });

  final String name;

  /// The minimum across reps. Least noise-prone summary for a JIT'd VM.
  final Duration best;
  final Duration median;
  final int opCount;

  double get bestMicrosPerOp => opCount == 0 ? 0 : best.inMicroseconds / opCount;

  String format() {
    final StringBuffer buffer = StringBuffer()
      ..write(name.padRight(46))
      ..write('best ${best.inMicroseconds.toString().padLeft(9)}us')
      ..write('  median ${median.inMicroseconds.toString().padLeft(9)}us');
    if (opCount > 0) {
      buffer.write('  ops ${opCount.toString().padLeft(9)}');
      buffer.write('  ${bestMicrosPerOp.toStringAsFixed(3)}us/op');
    }
    return buffer.toString();
  }
}

/// Runs [body] [reps] times after [warmups] untimed runs, returning the best and
/// median elapsed time.
///
/// [setup] runs before every rep and is **not** timed -- use it to rebuild any
/// state the body mutates. Building the corpus inside [body] would swamp the
/// measurement: `BooruItem`'s constructor allocates a `GlobalKey`, three `Rx`
/// objects and walks the tag list, which dwarfs the filtering being measured.
BenchResult runBench(
  String name, {
  required void Function() body,
  void Function()? setup,
  int warmups = 3,
  int reps = 7,
  int opCount = 0,
}) {
  for (int i = 0; i < warmups; i++) {
    setup?.call();
    body();
  }

  final List<int> samples = <int>[];
  for (int i = 0; i < reps; i++) {
    setup?.call();
    final Stopwatch sw = Stopwatch()..start();
    body();
    sw.stop();
    samples.add(sw.elapsedMicroseconds);
  }
  samples.sort();

  return BenchResult(
    name: name,
    best: Duration(microseconds: samples.first),
    median: Duration(microseconds: samples[samples.length ~/ 2]),
    opCount: opCount,
  );
}

/// Timing assertions are opt-in: under `flutter test`'s default parallelism the
/// numbers are noise. Run with `--concurrency=1` and `LS_BENCH=timing`.
bool get timingEnabled => Platform.environment['LS_BENCH'] == 'timing';
