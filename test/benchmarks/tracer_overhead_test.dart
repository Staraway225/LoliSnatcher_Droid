import 'package:flutter_test/flutter_test.dart';

import 'package:lolisnatcher/src/utils/perf_tracer.dart';

import '../support/bench.dart';

/// Proves the tracer costs nothing measurable when it is off.
///
/// Instrumentation that slows down the shipping build would defeat its own
/// purpose, so this is a regression test, not a one-off check.
void main() {
  setUp(PerfTracer.resetForTests);
  tearDown(PerfTracer.resetForTests);

  group('disabled tracer overhead', () {
    test('startWatch allocates nothing while tracing is off', () {
      expect(PerfTracer.isTracing, isFalse);
      // The hot paths (every download, every decode) keep a Stopwatch? and skip
      // the whole measurement when it is null.
      expect(PerfTracer.startWatch(), isNull);
    });

    test('every record hook is inert and buffers nothing', () {
      PerfTracer.recordDownload(bytes: 1024, millis: 5, fromCache: false);
      PerfTracer.recordDecode(3);
      PerfTracer.recordPageFetch(millis: 120, items: 20);
      PerfTracer.recordDbQuery(7);
      PerfTracer.recordTrim(removed: 40, extent: 4040);

      expect(PerfTracer.pendingLineCount, 0);
      expect(PerfTracer.frameCount, 0);
    });

    test('the disabled hot-path hook is far cheaper than the work it guards', () {
      const int reps = 200000;

      // What an instrumented download/decode pays when tracing is off.
      final BenchResult disabled = runBench(
        'disabled hook (startWatch + record)',
        body: () {
          for (int i = 0; i < reps; i++) {
            final Stopwatch? w = PerfTracer.startWatch();
            if (w != null) {
              PerfTracer.recordDecode(w.elapsedMilliseconds);
            }
          }
        },
        opCount: reps,
      );

      // The unconditional version this replaced, for scale.
      final BenchResult eager = runBench(
        'eager Stopwatch (what it replaced)',
        body: () {
          for (int i = 0; i < reps; i++) {
            final Stopwatch w = Stopwatch()..start();
            w.elapsedMilliseconds;
          }
        },
        opCount: reps,
      );

      // ignore: avoid_print
      print(disabled.format());
      // ignore: avoid_print
      print(eager.format());

      // Sub-nanosecond per call: a static bool read the JIT/AOT folds away.
      expect(
        disabled.bestMicrosPerOp,
        lessThan(0.01),
        reason: 'a disabled hook must be effectively free per call',
      );
      expect(
        disabled.best.inMicroseconds,
        lessThan(eager.best.inMicroseconds),
        reason: 'gating must be cheaper than allocating a Stopwatch every time',
      );
    });
  });
}
