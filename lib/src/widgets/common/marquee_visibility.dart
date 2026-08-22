import 'package:flutter/widgets.dart';

/// Controls whether descendant `MarqueeText`s may animate, and when they should
/// replay their single scrolling pass.
///
/// A device trace showed the app producing frames 99.9% of a 15-minute session,
/// pinned at 120Hz, because `fast_marquee`'s `AnimationController` restarts
/// forever and a running controller calls `SchedulerBinding.scheduleFrame()` on
/// every vsync. Two of the four permanently-mounted marquees were not even
/// visible: the app bar keeps its subtree mounted while scrolled off (it is a
/// floating, non-pinned sliver header) and `InnerDrawer` builds both drawer
/// children into an `IndexedStack` while closed.
///
/// [generation] is bumped only on a hidden -> visible transition. Marquees key
/// their inner widget on it, which is what makes a pass replay when the header
/// comes back: `fast_marquee` sets its `_roundsComplete` flag once and never
/// resets it, so only a fresh `State` can scroll again.
// ignore_for_file: prefer_initializing_formals

class MarqueeVisibilityController extends ChangeNotifier {
  MarqueeVisibilityController({bool visible = true}) : _visible = visible;

  bool _visible;
  bool get visible => _visible;

  int _generation = 0;
  int get generation => _generation;

  /// Transition-guarded on purpose.
  ///
  /// `MainAppBar.onHeaderVisiblityChanged` fires on every shrink-offset change
  /// while scrolling, not just on transitions, so acting on repeats would bump
  /// [generation] continuously and restart the marquee forever -- reintroducing
  /// the very bug this exists to fix.
  void setVisible(bool value) {
    if (_visible == value) {
      return;
    }
    _visible = value;
    if (value) {
      _generation++;
    }
    notifyListeners();
  }
}

/// Provides a [MarqueeVisibilityController] to descendant `MarqueeText`s.
class MarqueeVisibility extends InheritedNotifier<MarqueeVisibilityController> {
  const MarqueeVisibility({
    required MarqueeVisibilityController super.notifier,
    required super.child,
    super.key,
  });

  /// Resolves the nearest controller's state.
  ///
  /// Defaults to visible with generation 0 when there is no ancestor, so the
  /// many transient call sites (settings app bars, dialogs, tag lists) keep
  /// working unchanged and simply gain the single-pass behaviour.
  static ({bool visible, int generation}) of(BuildContext context) {
    final MarqueeVisibilityController? controller = context
        .dependOnInheritedWidgetOfExactType<MarqueeVisibility>()
        ?.notifier;
    if (controller == null) {
      return (visible: true, generation: 0);
    }
    return (visible: controller.visible, generation: controller.generation);
  }
}
