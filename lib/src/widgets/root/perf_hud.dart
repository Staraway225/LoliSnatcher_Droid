import 'package:flutter/material.dart';

import 'package:lolisnatcher/src/utils/perf_tracer.dart';
import 'package:lolisnatcher/src/utils/request_limiter.dart';
import 'package:lolisnatcher/src/widgets/common/loading_progress.dart';

/// Live readout of what the tracer is recording.
///
/// Deliberately **not** modelled on `ImageStats`' `Ticker`: `Ticker.scheduleTick`
/// calls `SchedulerBinding.scheduleFrame()` on every tick, so a Ticker-driven HUD
/// would hold the display pipeline awake and destroy exactly the idle-frame
/// measurement this exists to take. It listens to [PerfTracer]'s notifiers, which
/// the tracer's own `Timer.periodic` sampler updates, so the HUD adds no timer of
/// its own and schedules no frames while idle.
///
/// Wrapped in a `RepaintBoundary` so its repaints never dirty the grid beneath.
class PerfHud extends StatelessWidget {
  const PerfHud({super.key});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Align(
        alignment: Alignment.topRight,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.only(right: 8, top: 8),
            child: RepaintBoundary(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.7),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  child: ListenableBuilder(
                    listenable: Listenable.merge(<Listenable>[
                      PerfTracer.hudFps,
                      PerfTracer.hudBuildMs,
                      PerfTracer.hudRasterMs,
                      PerfTracer.hudFrames,
                      PerfTracer.hudRssMb,
                    ]),
                    builder: (BuildContext context, Widget? child) {
                      final double build = PerfTracer.hudBuildMs.value;
                      final double raster = PerfTracer.hudRasterMs.value;
                      // Raster above build is the signal that the GPU, not the
                      // Dart side, is the bottleneck.
                      final bool rasterBound = raster > build;

                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: <Widget>[
                          _line(
                            'fps ${PerfTracer.hudFps.value.toStringAsFixed(1)}',
                            Colors.white,
                          ),
                          _line(
                            'build ${build.toStringAsFixed(1)}ms',
                            rasterBound ? Colors.white70 : Colors.orangeAccent,
                          ),
                          _line(
                            'raster ${raster.toStringAsFixed(1)}ms',
                            rasterBound ? Colors.orangeAccent : Colors.white70,
                          ),
                          _line(
                            'net ${RequestLimiter.activeCount}/${RequestLimiter.queuedCount}',
                            Colors.white70,
                          ),
                          _line(
                            'tiles ${LoadingProgressTracker.activeTrackerCount}',
                            Colors.white70,
                          ),
                          _line('rss ${PerfTracer.hudRssMb.value}MB', Colors.white70),
                          _line(
                            PerfTracer.isTracing ? 'REC ${PerfTracer.hudFrames.value}' : 'idle',
                            PerfTracer.isTracing ? Colors.redAccent : Colors.white38,
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _line(String text, Color color) {
    return Text(
      text,
      style: TextStyle(
        color: color,
        fontSize: 10,
        height: 1.3,
        fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
      ),
    );
  }
}
