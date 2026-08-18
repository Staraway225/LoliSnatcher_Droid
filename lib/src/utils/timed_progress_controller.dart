import 'dart:async';

import 'package:flutter/foundation.dart';

// code from https://stackoverflow.com/questions/56853554/show-timer-progress-on-a-circularprogressindicator-in-flutter

/// Schedules a timed run and reports when it starts and stops.
///
/// It used to also drive the *animation*, ticking a `Timer.periodic` at
/// `duration / 250` -- about 16ms, or 62 setState calls a second, for the entire
/// time a slideshow was running. The fill is now driven by an
/// `AnimationController` in `RestartableProgressIndicator`, which is vsync-paced
/// and repaints without rebuilding.
class TimedProgressController {
  TimedProgressController({
    required this.duration,
  });

  final Duration duration;

  Timer? _timer;

  /// Bumped every time a new run begins. Listeners restart their animation.
  final ValueNotifier<int> runTick = ValueNotifier<int>(0);

  /// Whether a run is currently in progress.
  final ValueNotifier<bool> isRunning = ValueNotifier<bool>(false);

  void start() {
    _cancelTimers();
    isRunning.value = true;
    runTick.value++;
    _timer = Timer(duration, () {
      _cancelTimers();
      isRunning.value = false;
    });
  }

  void stop() {
    _cancelTimers();
    isRunning.value = false;
  }

  void restart() {
    start();
  }

  Future<void> dispose() async {
    _cancelTimers();
    runTick.dispose();
    isRunning.dispose();
  }

  void _cancelTimers() {
    if (_timer?.isActive == true) {
      _timer?.cancel();
    }
    _timer = null;
  }
}
