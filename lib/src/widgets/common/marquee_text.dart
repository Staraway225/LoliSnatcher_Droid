import 'package:flutter/material.dart';

import 'package:auto_size_text_plus/auto_size_text_plus.dart';
import 'package:fast_marquee/fast_marquee.dart';

import 'package:lolisnatcher/src/widgets/common/marquee_visibility.dart';

// Based on code from: https://github.com/nt4f04uNd/nt4f04unds_widgets/blob/f14e448d23d347f17c05549972e638d61cf300b4/lib/src/widgets/marquee.dart

class MarqueeText extends StatelessWidget {
  const MarqueeText({
    required this.text,
    this.style,
    this.velocity = 45.0,
    this.curve = Curves.linear,
    this.blankSpace = 50.0,
    this.startPadding = 0.0,
    this.startAfter = const Duration(milliseconds: 1000),
    this.pauseAfterRound = const Duration(milliseconds: 1500),
    this.isExpanded = true,
    this.reverse = false,
    this.allowDownscale = true,
    this.fadingEdgeStartFraction = 0,
    this.fadingEdgeEndFraction = 0.15,
    super.key,
  }) : textSpan = null;

  const MarqueeText.rich({
    required this.textSpan,
    this.style,
    this.velocity = 45.0,
    this.curve = Curves.linear,
    this.blankSpace = 50.0,
    this.startPadding = 0.0,
    this.startAfter = const Duration(milliseconds: 1000),
    this.pauseAfterRound = const Duration(milliseconds: 1500),
    this.isExpanded = true,
    this.reverse = false,
    this.allowDownscale = true,
    this.fadingEdgeStartFraction = 0,
    this.fadingEdgeEndFraction = 0.15,
    super.key,
  }) : text = null;

  final String? text;
  final TextStyle? style;
  final TextSpan? textSpan;
  final double velocity;
  final Curve curve;
  final double blankSpace;
  final double startPadding;
  final Duration startAfter;
  final Duration pauseAfterRound;
  final bool isExpanded;
  final bool reverse;
  final bool allowDownscale;
  final double fadingEdgeStartFraction;
  final double fadingEdgeEndFraction;

  @override
  Widget build(BuildContext context) {
    final ({bool visible, int generation}) visibility = MarqueeVisibility.of(context);

    // TickerMode mutes the marquee's AnimationController when this widget is not
    // actually on screen. That genuinely stops frame scheduling rather than just
    // freezing the pixels: Ticker.shouldScheduleTick is `!muted && isActive &&
    // !scheduled`, and only scheduleTick() calls SchedulerBinding.scheduleFrame().
    //
    // Without it the app bar's marquees keep running while the header is scrolled
    // off (a floating sliver header keeps its subtree mounted), and the drawer's
    // keep running while the drawer is closed (InnerDrawer builds both children
    // into an IndexedStack) -- which pinned the whole app at 120Hz permanently.
    final child = TickerMode(
      enabled: visibility.visible,
      child: RepaintBoundary(child: innerBox(context, visibility.generation)),
    );

    if (isExpanded) {
      return Expanded(child: child);
    }

    return child;
  }

  Widget innerBox(BuildContext context, int generation) {
    final defaultStyle = DefaultTextStyle.of(context).style;
    final usedStyle = (style ?? defaultStyle).copyWith(
      height: 1,
    );
    final double fontSize = usedStyle.fontSize ?? 16;

    // allow text to shrink a bit, so that strings can exceed a few symbols in length before starting to scroll
    const double stepGranularity = 0.1;
    double minFontSize = double.parse((fontSize * 0.85).toStringAsFixed(1));
    // make sure that minFontSize is dividable by stepGranularity
    minFontSize = (minFontSize / stepGranularity).ceil() * stepGranularity;

    if (textSpan != null) {
      return Container(
        alignment: Alignment.centerLeft,
        child: AutoSizeText.rich(
          textSpan!,
          minFontSize: allowDownscale ? minFontSize : fontSize,
          maxFontSize: fontSize,
          maxLines: 1,
          stepGranularity: stepGranularity,
          style: usedStyle,
          overflowReplacement: Marquee.rich(
            // Keyed on the text and the visibility generation. fast_marquee sets
            // its `_roundsComplete` flag once and never resets it, so only a
            // fresh State can scroll again -- this is what replays a single pass
            // when the header comes back into view or the tab changes.
            key: ValueKey<(String, int)>((textSpan!.toPlainText(), generation)),
            textSpan: textSpan,
            // One pass, then rest. A completed animation ends at horizontal
            // offset 0, i.e. the natural start of the string, so stopping looks
            // deliberate rather than frozen mid-scroll.
            numberOfRounds: 1,
            blankSpace: blankSpace,
            curve: curve,
            velocity: velocity,
            startPadding: startPadding,
            fadingEdgeStartFraction: fadingEdgeStartFraction,
            fadingEdgeEndFraction: fadingEdgeEndFraction,
            reverse: reverse,
            showFadingOnlyWhenScrolling: false,
            startAfter: startAfter,
            pauseAfterRound: pauseAfterRound,
          ),
        ),
      );
    }

    return Container(
      alignment: Alignment.centerLeft,
      child: AutoSizeText(
        text!,
        minFontSize: allowDownscale ? minFontSize : fontSize,
        maxFontSize: fontSize,
        maxLines: 1,
        stepGranularity: stepGranularity,
        style: usedStyle,
        overflowReplacement: Marquee(
          key: ValueKey<(String, int)>((text!, generation)),
          text: text,
          numberOfRounds: 1,
          blankSpace: blankSpace,
          curve: curve,
          velocity: velocity,
          startPadding: startPadding,
          fadingEdgeStartFraction: fadingEdgeStartFraction,
          fadingEdgeEndFraction: fadingEdgeEndFraction,
          reverse: reverse,
          showFadingOnlyWhenScrolling: false,
          startAfter: startAfter,
          pauseAfterRound: pauseAfterRound,
          style: usedStyle,
        ),
      ),
    );
  }
}
