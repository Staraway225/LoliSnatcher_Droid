import 'package:flutter/material.dart';

import 'package:lolisnatcher/src/handlers/settings_handler.dart';
import 'package:lolisnatcher/src/utils/extensions.dart';

class ShimmerWrap extends StatelessWidget {
  const ShimmerWrap({
    required this.child,
    this.enabled = true,
    super.key,
  });

  final Widget child;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Shimmer(
      enabled: enabled,
      linearGradient: _shimmerGradient(
        Color.lerp(colorScheme.surface, colorScheme.onSurface, 0.15)!,
        Color.lerp(colorScheme.onSurface, colorScheme.surface, 0.75)!,
        Color.lerp(colorScheme.surface, colorScheme.onSurface, 0.15)!,
      ),
      child: child,
    );
  }
}

class ThumbnailsShimmerList extends StatelessWidget {
  const ThumbnailsShimmerList({
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final SettingsHandler settingsHandler = SettingsHandler.instance;
    final displayType = settingsHandler.previewDisplay;
    final int previewCount = settingsHandler.itemLimit;
    final int columnCount = context.isPortrait ? settingsHandler.portraitColumns : settingsHandler.landscapeColumns;

    return SliverGrid.builder(
      addAutomaticKeepAlives: false,
      itemCount: previewCount,
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columnCount,
        childAspectRatio: displayType.isSquare ? 1 : 9 / 16,
        mainAxisSpacing: 4,
        crossAxisSpacing: 4,
      ),
      itemBuilder: (context, index) {
        return GridTile(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: const ShimmerCard(),
          ),
        );
      },
    );
  }
}

class ShimmerCard extends StatelessWidget {
  const ShimmerCard({
    this.isLoading = true,
    this.child,
    super.key,
  });

  final bool isLoading;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return ShimmerLoading(
      isLoading: isLoading,
      child:
          child ??
          Container(
            width: double.maxFinite,
            height: double.maxFinite,
            color: Theme.of(context).colorScheme.surface,
          ),
    );
  }
}

LinearGradient _shimmerGradient(Color c1, Color c2, Color c3) => LinearGradient(
  colors: [c1, c2, c3],
  stops: const [
    0.1,
    0.3,
    0.4,
  ],
  begin: const Alignment(-1, -0.3),
  end: const Alignment(1, 0.3),
  tileMode: TileMode.clamp,
);

//>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

class Shimmer extends StatefulWidget {
  const Shimmer({
    required this.linearGradient,
    this.enabled = true,
    this.child,
    super.key,
  });

  static ShimmerState? of(BuildContext context) {
    return context.findAncestorStateOfType<ShimmerState>();
  }

  final LinearGradient linearGradient;
  final bool enabled;
  final Widget? child;

  @override
  ShimmerState createState() => ShimmerState();
}

class ShimmerState extends State<Shimmer> with SingleTickerProviderStateMixin {
  late AnimationController _shimmerController;

  /// Registered shimmering children, tracked by identity.
  ///
  /// This used to be a plain `int` incremented from a descendant's
  /// [State.didChangeDependencies], which fires on every inherited-widget change
  /// (theme, MediaQuery, orientation, keyboard insets) with no matching
  /// decrement. The count therefore only ever climbed, `stop()` could never
  /// fire, and the controller repeated for the life of the app -- forcing a
  /// frame every vsync plus a `ShaderMask` (a `saveLayer`) per shimmering tile.
  /// Set membership makes registration idempotent, so that drift is impossible.
  final Set<State<ShimmerLoading>> _activeChildren = Set<State<ShimmerLoading>>.identity();

  int get activeChildren => _activeChildren.length;

  @override
  void initState() {
    super.initState();

    _shimmerController = AnimationController.unbounded(vsync: this);
    _syncController();
  }

  @override
  void didUpdateWidget(Shimmer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.enabled != oldWidget.enabled) {
      _syncController();
    }
  }

  void registerChild(State<ShimmerLoading> child) {
    if (_activeChildren.add(child)) {
      _syncController();
    }
  }

  void unregisterChild(State<ShimmerLoading> child) {
    if (_activeChildren.remove(child)) {
      _syncController();
    }
  }

  /// The single place the ticker starts or stops. Both conditions must hold:
  /// the widget is enabled, and something is actually shimmering.
  void _syncController() {
    final bool shouldAnimate = widget.enabled && _activeChildren.isNotEmpty;
    if (shouldAnimate) {
      if (!_shimmerController.isAnimating) {
        _shimmerController.repeat(
          min: -0.5,
          max: 1.5,
          period: const Duration(milliseconds: 1000),
        );
      }
    } else if (_shimmerController.isAnimating) {
      _shimmerController.stop();
    }
  }

  @override
  void dispose() {
    _shimmerController.dispose();
    super.dispose();
  }

  LinearGradient get gradient => LinearGradient(
    colors: widget.linearGradient.colors,
    stops: widget.linearGradient.stops,
    begin: widget.linearGradient.begin,
    end: widget.linearGradient.end,
    transform: _SlidingGradientTransform(slidePercent: _shimmerController.value),
  );

  bool get isSized {
    final RenderObject? renderObj = context.findRenderObject();
    final RenderBox? box = renderObj != null ? renderObj as RenderBox : null;
    return box?.hasSize ?? false;
  }

  Size get size {
    final RenderObject? renderObj = context.findRenderObject();
    final RenderBox? box = renderObj != null ? renderObj as RenderBox : null;
    return box?.size ?? Size.zero;
  }

  Offset getDescendantOffset({
    required RenderBox descendant,
    Offset offset = Offset.zero,
  }) {
    try {
      final shimmerBox = context.findRenderObject() as RenderBox?;
      return descendant.localToGlobal(offset, ancestor: shimmerBox);
    } catch (_) {
      return Offset.zero;
    }
  }

  Listenable get shimmerChanges => _shimmerController;

  @override
  Widget build(BuildContext context) {
    return widget.child ?? const SizedBox.shrink();
  }
}

class _SlidingGradientTransform extends GradientTransform {
  const _SlidingGradientTransform({
    required this.slidePercent,
  });

  final double slidePercent;

  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) {
    return Matrix4.translationValues(bounds.width * slidePercent, 0, 0);
  }
}

//>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

class ShimmerLoading extends StatefulWidget {
  const ShimmerLoading({
    required this.isLoading,
    required this.child,
    super.key,
  });

  final bool isLoading;
  final Widget child;

  @override
  State<ShimmerLoading> createState() => _ShimmerLoadingState();
}

class _ShimmerLoadingState extends State<ShimmerLoading> {
  Listenable? _shimmerChanges;
  final ValueNotifier<int> _shimmerUpdateIndex = ValueNotifier(0);

  ShimmerState? _shimmerState;
  bool _registered = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final ShimmerState? newState = Shimmer.of(context);
    final bool isChanged = !identical(_shimmerState, newState);

    // Only tear down and re-subscribe when the ancestor actually changed.
    // This runs on every inherited-widget change, so doing it unconditionally
    // is what used to leak a registration per theme/orientation/inset change.
    if (isChanged) {
      if (_registered) {
        _shimmerState?.unregisterChild(this);
        _registered = false;
      }
      _shimmerChanges?.removeListener(_onShimmerChange);
      _shimmerState = newState;
      _shimmerChanges = _shimmerState?.shimmerChanges;
      _shimmerChanges?.addListener(_onShimmerChange);
    }

    _syncRegistration();

    if (isChanged) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _shimmerUpdateIndex.value++;
        }
      });
    }
  }

  @override
  void didUpdateWidget(covariant ShimmerLoading oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isLoading != oldWidget.isLoading) {
      _syncRegistration();
      _shimmerUpdateIndex.value++;
    }
  }

  /// Registration tracks [ShimmerLoading.isLoading] exactly, and is idempotent.
  void _syncRegistration() {
    if (widget.isLoading == _registered) {
      return;
    }
    if (widget.isLoading) {
      _shimmerState?.registerChild(this);
    } else {
      _shimmerState?.unregisterChild(this);
    }
    _registered = widget.isLoading;
  }

  @override
  void dispose() {
    if (_registered) {
      _shimmerState?.unregisterChild(this);
      _registered = false;
    }
    _shimmerChanges?.removeListener(_onShimmerChange);
    _shimmerUpdateIndex.dispose();
    super.dispose();
  }

  /// Whether this tile currently overlaps the shimmer's box (i.e. the viewport).
  ///
  /// Lazy slivers lay out a viewport of cache extent either side of the visible
  /// area, so roughly two thirds of registered tiles are laid out but never
  /// painted. Rebuilding and re-shading those every tick is pure waste: each
  /// rebuild allocates a ShaderMask, which is a saveLayer / offscreen render
  /// target, plus a localToGlobal ancestor walk.
  bool get _isWithinViewport {
    final ShimmerState? shimmer = _shimmerState;
    if (shimmer == null || !shimmer.isSized) {
      return false;
    }
    final RenderObject? renderObj = context.findRenderObject();
    if (renderObj is! RenderBox || !renderObj.attached || !renderObj.hasSize) {
      return false;
    }
    final Offset offset = shimmer.getDescendantOffset(descendant: renderObj);
    final Size shimmerSize = shimmer.size;
    final Size selfSize = renderObj.size;
    return offset.dy + selfSize.height >= 0 &&
        offset.dy <= shimmerSize.height &&
        offset.dx + selfSize.width >= 0 &&
        offset.dx <= shimmerSize.width;
  }

  void _onShimmerChange() {
    if (!_isWithinViewport) {
      return;
    }
    if (widget.isLoading) {
      // update the shimmer painting.
      if (_shimmerUpdateIndex.value >= 100_000) {
        _shimmerUpdateIndex.value = 0;
      } else {
        _shimmerUpdateIndex.value++;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: _shimmerUpdateIndex,
      builder: (context, _, child) {
        final RenderObject? renderObj = context.findRenderObject();
        if (_shimmerState == null || !_shimmerState!.isSized || renderObj == null || !renderObj.attached) {
          // The ancestor Shimmer widget has not laid
          // itself out yet. Return an empty box.
          return child ?? const SizedBox.shrink();
        }

        return ShaderMask(
          blendMode: BlendMode.srcATop,
          shaderCallback: (bounds) {
            final shimmerSize = _shimmerState!.size;
            final gradient = _shimmerState!.gradient;
            final offsetWithinShimmer = _shimmerState!.getDescendantOffset(
              descendant: renderObj as RenderBox,
            );
            return gradient.createShader(
              Rect.fromLTWH(
                -offsetWithinShimmer.dx,
                -offsetWithinShimmer.dy,
                shimmerSize.width,
                shimmerSize.height,
              ),
            );
          },
          child: child,
        );
      },
      child: widget.child,
    );
  }
}
