import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:lolisnatcher/src/utils/request_limiter.dart';

void main() {
  setUp(RequestLimiter.resetForTests);
  tearDown(RequestLimiter.resetForTests);

  group('concurrency cap', () {
    test('never runs more than maxConcurrentDownloads at once', () async {
      int running = 0;
      int peak = 0;
      final List<Completer<void>> gates = <Completer<void>>[];

      final List<Future<void>> tasks = <Future<void>>[];
      for (int i = 0; i < 40; i++) {
        final Completer<void> gate = Completer<void>();
        gates.add(gate);
        tasks.add(
          RequestLimiter.withPermit(() async {
            running++;
            peak = running > peak ? running : peak;
            await gate.future;
            running--;
          }),
        );
      }

      // Let the first wave acquire permits.
      await Future<void>.delayed(Duration.zero);
      expect(peak, RequestLimiter.maxConcurrentDownloads);

      for (final Completer<void> gate in gates) {
        gate.complete();
        await Future<void>.delayed(Duration.zero);
      }
      await Future.wait(tasks);

      expect(peak, RequestLimiter.maxConcurrentDownloads);
      expect(running, 0);
      expect(RequestLimiter.activeCount, 0);
    });

    test('a throwing task still releases its permit', () async {
      for (int i = 0; i < RequestLimiter.maxConcurrentDownloads * 3; i++) {
        await expectLater(
          RequestLimiter.withPermit(() async => throw StateError('boom')),
          throwsStateError,
        );
      }
      expect(RequestLimiter.activeCount, 0);

      // The pool must still be usable.
      final bool ran = await RequestLimiter.withPermit(() async => true);
      expect(ran, isTrue);
    });
  });

  group('backoff', () {
    test('grows exponentially and stays within the jitter band', () {
      for (int attempt = 0; attempt < 5; attempt++) {
        final int base = 500 * (1 << attempt);
        final Duration d = RequestLimiter.backoffFor(attempt);
        expect(d.inMilliseconds, greaterThanOrEqualTo((base * 0.7).floor()));
        expect(d.inMilliseconds, lessThanOrEqualTo((base * 1.3).ceil()));
      }
    });

    test('jitter actually varies, so tiles do not retry in lockstep', () {
      final Set<int> seen = <int>{
        for (int i = 0; i < 40; i++) RequestLimiter.backoffFor(2).inMilliseconds,
      };
      expect(seen.length, greaterThan(1));
    });

    test('attempts are capped well below the old 8', () {
      expect(RequestLimiter.maxAttempts, lessThanOrEqualTo(4));
    });
  });

  group('per-host circuit breaker', () {
    test('pauses a host that rate limited us, then expires', () {
      final DateTime now = DateTime(2026);
      expect(RequestLimiter.pauseRemaining('cdn.example.test', now: now), isNull);

      RequestLimiter.reportRateLimited('cdn.example.test', now: now);
      expect(RequestLimiter.pauseRemaining('cdn.example.test', now: now), isNotNull);

      // A different host is unaffected.
      expect(RequestLimiter.pauseRemaining('other.example.test', now: now), isNull);

      final DateTime later = now.add(RequestLimiter.hostPause).add(const Duration(seconds: 1));
      expect(RequestLimiter.pauseRemaining('cdn.example.test', now: later), isNull);
    });

    test('recognises the rate-limit statuses and nothing else', () {
      expect(RequestLimiter.isRateLimitStatus(429), isTrue);
      expect(RequestLimiter.isRateLimitStatus(503), isTrue);
      expect(RequestLimiter.isRateLimitStatus(200), isFalse);
      expect(RequestLimiter.isRateLimitStatus(404), isFalse);
      expect(RequestLimiter.isRateLimitStatus(null), isFalse);
    });

    test('null or empty hosts are ignored', () {
      RequestLimiter.reportRateLimited(null);
      RequestLimiter.reportRateLimited('');
      expect(RequestLimiter.pauseRemaining(null), isNull);
      expect(RequestLimiter.pauseRemaining(''), isNull);
    });
  });
}
