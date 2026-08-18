import 'package:flutter/material.dart';

class PulseWidget extends StatefulWidget {
  const PulseWidget({
    required this.child,
    this.duration,
    this.enabled = true,
    super.key,
  });

  final Widget child;
  final Duration? duration;
  final bool enabled;

  @override
  State<PulseWidget> createState() => _PulseWidgetState();
}

class _PulseWidgetState extends State<PulseWidget> with SingleTickerProviderStateMixin {
  late AnimationController _fadeController;
  late Animation<double> _fadeAnimation;

  final double _initialOpacity = 1;
  final double _finalOpacity = 0.4;

  @override
  void initState() {
    super.initState();

    _configurePulseAnimation();
  }

  void _configurePulseAnimation() {
    _fadeController = AnimationController(
      vsync: this,
      duration: widget.duration ?? const Duration(seconds: 1),
    );

    _fadeAnimation = Tween(begin: _initialOpacity, end: _finalOpacity).animate(
      CurvedAnimation(
        parent: _fadeController,
        curve: Curves.linear,
      ),
    );

    _fadeController.addStatusListener(_statusListener);

    // Previously started unconditionally (and twice). `build` returns the bare
    // child when disabled, so the ticker kept scheduling frames forever behind a
    // widget that never showed the animation -- e.g. the viewer's snatch icon,
    // which passes `enabled: running` and is almost always false.
    if (widget.enabled) {
      _fadeController.forward();
    }
  }

  @override
  void didUpdateWidget(covariant PulseWidget oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.duration != oldWidget.duration) {
      _fadeController.duration = widget.duration ?? const Duration(seconds: 1);
    }

    if (widget.enabled != oldWidget.enabled) {
      if (widget.enabled) {
        _fadeController.forward();
      } else {
        // Reset so a later re-enable starts from full opacity, exactly as a
        // fresh mount would. Safe because _statusListener bails when disabled;
        // otherwise landing on `dismissed` would immediately call forward().
        _fadeController
          ..stop()
          ..value = 0;
      }
    }
  }

  void _statusListener(AnimationStatus status) {
    if (!widget.enabled) {
      return;
    }
    if (status == AnimationStatus.completed) {
      _fadeController.reverse();
    }
    if (status == AnimationStatus.dismissed) {
      _fadeController.forward();
    }
  }

  @override
  void dispose() {
    _fadeController.removeStatusListener(_statusListener);
    _fadeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) {
      return widget.child;
    }

    return FadeTransition(
      opacity: _fadeAnimation,
      child: widget.child,
    );
  }
}
