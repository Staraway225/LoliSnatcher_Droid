import 'dart:async';
import 'dart:collection';
import 'dart:math';

import 'package:flutter/foundation.dart';

/// Bounds how many image downloads run at once, and how hard a failing host is
/// retried.
///
/// Nothing in the stack capped concurrency: there was no semaphore anywhere, and
/// `maxConnectionsPerHost` is `null` (unlimited) on Dart's `HttpClient`, on the
/// socks_proxy client installed via `HttpOverrides`, and in Dio's IO adapter.
/// With a viewport of cache extent either side of the visible grid, and two
/// requests per tile (sample plus thumbnail underlay), a fling could put 50-120
/// requests in flight at once. The 200ms per-tile load debounce is a delay, not
/// a rate limiter -- once a fling settles, every live tile fires inside the same
/// 200ms window.
class RequestLimiter {
  const RequestLimiter._();

  /// Permits for concurrent image downloads.
  ///
  /// Small enough to keep the radio out of a sustained high-power state and to
  /// avoid head-of-line contention on one pipe; large enough that tiles still
  /// fill in visibly progressively.
  static const int maxConcurrentDownloads = 5;

  /// Ceiling on live connections to a single host, applied to the pooled clients.
  static const int maxConnectionsPerHost = 6;

  static int _active = 0;
  static final Queue<Completer<void>> _waiting = Queue<Completer<void>>();

  /// Runs [action] once a permit is free. The permit is always released.
  static Future<T> withPermit<T>(Future<T> Function() action) async {
    await _acquire();
    try {
      return await action();
    } finally {
      _release();
    }
  }

  static Future<void> _acquire() {
    if (_active < maxConcurrentDownloads) {
      _active++;
      return Future<void>.value();
    }
    final Completer<void> completer = Completer<void>();
    _waiting.add(completer);
    return completer.future;
  }

  static void _release() {
    if (_waiting.isNotEmpty) {
      // Hand the permit straight to the next waiter rather than decrementing,
      // so a burst cannot slip past the cap between release and acquire.
      _waiting.removeFirst().complete();
      return;
    }
    _active = max(0, _active - 1);
  }

  @visibleForTesting
  static int get activeCount => _active;

  @visibleForTesting
  static void resetForTests() {
    _active = 0;
    _waiting.clear();
    _hostPauses.clear();
  }

  // ---- retry policy -------------------------------------------------------

  /// Attempts per thumbnail, down from 8.
  ///
  /// The old policy was 8 retries at a flat 500ms with no jitter and a per-item
  /// debounce tag, so ~30 tiles retried in lockstep: up to 270 requests in 4.5s
  /// aimed at a host that had just rate-limited us.
  static const int maxAttempts = 4;

  static final Random _random = Random();

  /// Exponential backoff with +/-30% jitter, so tiles stop retrying in lockstep.
  static Duration backoffFor(int attempt) {
    final int clamped = attempt.clamp(0, 6);
    final int base = 500 * (1 << clamped);
    final double jitter = 0.7 + (_random.nextDouble() * 0.6);
    return Duration(milliseconds: (base * jitter).round());
  }

  // ---- per-host circuit breaker -------------------------------------------

  static final Map<String, DateTime> _hostPauses = <String, DateTime>{};

  /// Pause length applied to a host that answered 429 or 503.
  static const Duration hostPause = Duration(seconds: 10);

  static void reportRateLimited(String? host, {DateTime? now}) {
    if (host == null || host.isEmpty) {
      return;
    }
    _hostPauses[host] = (now ?? DateTime.now()).add(hostPause);
  }

  /// How long callers should wait before hitting [host] again, or null.
  static Duration? pauseRemaining(String? host, {DateTime? now}) {
    if (host == null || host.isEmpty) {
      return null;
    }
    final DateTime? until = _hostPauses[host];
    if (until == null) {
      return null;
    }
    final DateTime current = now ?? DateTime.now();
    if (!until.isAfter(current)) {
      _hostPauses.remove(host);
      return null;
    }
    return until.difference(current);
  }

  static bool isRateLimitStatus(int? statusCode) => statusCode == 429 || statusCode == 503;
}
