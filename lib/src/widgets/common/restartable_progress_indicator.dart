import 'package:flutter/material.dart';

import 'package:lolisnatcher/src/utils/timed_progress_controller.dart';

// code from https://stackoverflow.com/questions/56853554/show-timer-progress-on-a-circularprogressindicator-in-flutter

/// Fills a circular indicator over the controller's duration.
///
/// Driven by an [AnimationController] inside an [AnimatedBuilder], so the fill
/// is vsync-paced and only repaints -- the previous implementation rebuilt the
/// widget from a ~16ms timer.
class RestartableProgressIndicator extends StatefulWidget {
  const RestartableProgressIndicator({
    required this.controller,
    this.onTimeout,
    super.key,
  });

  final TimedProgressController controller;
  final VoidCallback? onTimeout;

  @override
  State<RestartableProgressIndicator> createState() => _RestartableProgressIndicatorState();
}

class _RestartableProgressIndicatorState extends State<RestartableProgressIndicator>
    with SingleTickerProviderStateMixin {
  TimedProgressController get controller => widget.controller;

  late final AnimationController _fill = AnimationController(
    vsync: this,
    duration: controller.duration,
  );

  @override
  void initState() {
    super.initState();
    controller.runTick.addListener(_onRun);
    controller.isRunning.addListener(_onRunningChanged);
    if (controller.isRunning.value) {
      _fill.forward(from: 0);
    }
  }

  @override
  void didUpdateWidget(covariant RestartableProgressIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.runTick.removeListener(_onRun);
      oldWidget.controller.isRunning.removeListener(_onRunningChanged);
      controller.runTick.addListener(_onRun);
      controller.isRunning.addListener(_onRunningChanged);
      _fill.duration = controller.duration;
      if (controller.isRunning.value) {
        _fill.forward(from: 0);
      } else {
        _fill.value = 0;
      }
    }
  }

  void _onRun() {
    _fill
      ..duration = controller.duration
      ..forward(from: 0);
  }

  void _onRunningChanged() {
    if (!controller.isRunning.value) {
      _fill
        ..stop()
        ..value = 0;
      // onTimeout is intentionally not invoked: no caller passes it, and it was
      // never called before either. Firing it here would also mean "stopped",
      // not "timed out".
    }
  }

  @override
  void dispose() {
    controller.runTick.removeListener(_onRun);
    controller.isRunning.removeListener(_onRunningChanged);
    _fill.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _fill,
      builder: (BuildContext context, Widget? child) {
        return CircularProgressIndicator(value: _fill.value);
      },
    );
  }
}
