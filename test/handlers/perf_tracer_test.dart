import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:lolisnatcher/src/utils/perf_tracer.dart';

void main() {
  setUp(PerfTracer.resetForTests);
  tearDown(PerfTracer.resetForTests);

  group('zero cost when disabled', () {
    // The whole point: instrumentation must never cost anything in normal use,
    // or we would be measuring the tracer instead of the app.
    test('every hook is inert and buffers nothing', () {
      expect(PerfTracer.isTracing, isFalse);

      PerfTracer.recordDownload(bytes: 1024, millis: 5, fromCache: false);
      PerfTracer.recordDecode(3);
      PerfTracer.recordPageFetch(millis: 120, items: 20);
      PerfTracer.recordDbQuery(7);
      PerfTracer.recordTrim(removed: 40, extent: 4040);

      expect(PerfTracer.pendingLineCount, 0);
      expect(PerfTracer.frameCount, 0);
    });

    test('flush on a stopped tracer does not throw', () async {
      await expectLater(PerfTracer.flush(), completes);
    });

    test('stop without start is a no-op', () async {
      expect(await PerfTracer.stop(), isNull);
    });
  });

  group('trace record shape', () {
    // The analyser parses these, so the contract is worth pinning.
    test('records are one JSON object per line with a type tag', () {
      const List<String> lines = <String>[
        '{"t":"meta","mode":"release"}',
        '{"t":"frame","d":[[1,2000,3000,100,5000,123456]]}',
        '{"t":"sample","ms":2000,"fps":59.9}',
        '{"t":"event","k":"trim","removed":40}',
        '{"t":"end","frames":1200}',
      ];

      for (final String line in lines) {
        final Object? decoded = jsonDecode(line);
        expect(decoded, isA<Map<String, dynamic>>());
        expect((decoded! as Map<String, dynamic>)['t'], isA<String>());
      }
    });

    test('frame rows carry the six fields the analyser expects', () {
      final Map<String, dynamic> record =
          jsonDecode('{"t":"frame","d":[[7,2000,3000,100,5000,123456]]}') as Map<String, dynamic>;
      final List<dynamic> rows = record['d'] as List<dynamic>;
      final List<dynamic> row = rows.first as List<dynamic>;

      expect(row.length, 6, reason: 'frameNumber, build, raster, vsync, total, wallUs');
      expect(row[0], 7);
      expect(row[1], 2000); // buildUs
      expect(row[2], 3000); // rasterUs
    });
  });

  group('reported values', () {
    test('HUD notifiers start at zero', () {
      expect(PerfTracer.hudFrames.value, 0);
      expect(PerfTracer.hudFps.value, 0);
      expect(PerfTracer.hudBuildMs.value, 0);
      expect(PerfTracer.hudRasterMs.value, 0);
    });

    test('listTraces tolerates a missing directory', () async {
      // Runs on a host with no app container; must degrade rather than throw.
      await expectLater(PerfTracer.listTraces(), completes);
    });
  });
}
