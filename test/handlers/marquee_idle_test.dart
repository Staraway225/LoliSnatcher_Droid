import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lolisnatcher/src/widgets/common/marquee_text.dart';
import 'package:lolisnatcher/src/widgets/common/marquee_visibility.dart';

const String kLongText = 'a very long tag string that will definitely overflow the box';

/// Narrow enough that the text cannot fit even at minFontSize, which is what
/// makes AutoSizeText fall back to the Marquee.
Widget wrap(Widget child, {MarqueeVisibilityController? controller}) {
  final Widget body = SizedBox(width: 120, height: 40, child: child);
  return MaterialApp(
    home: Directionality(
      textDirection: TextDirection.ltr,
      child: Scaffold(
        body: Center(
          child: controller == null ? body : MarqueeVisibility(notifier: controller, child: body),
        ),
      ),
    ),
  );
}

/// fast_marquee waits `startAfter` (1000ms) inside a post-frame callback before
/// starting. Asserting before that reports "settled" even when broken, which
/// would be a false green.
Future<void> pumpPastStartDelay(WidgetTester tester) => tester.pump(const Duration(milliseconds: 1200));

/// fast_marquee's `dispose` only disposes its AnimationController -- its
/// `numberOfRounds` Timer and its `Future.delayed`s are left pending, which the
/// test binding reports as a leak. Elapse enough fake time for them to fire
/// before the tree is torn down.
Future<void> drainMarqueeTimers(WidgetTester tester) => tester.pump(const Duration(seconds: 60));

void main() {
  group('the app can reach idle', () {
    testWidgets('an overflowing marquee eventually stops scheduling frames', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(wrap(const MarqueeText(text: kLongText, isExpanded: false)));
      await pumpPastStartDelay(tester);

      expect(
        tester.binding.hasScheduledFrame,
        isTrue,
        reason: 'the marquee should be mid-pass at this point',
      );

      // Before the fix this never returned: the controller restarted forever and
      // pumpAndSettle timed out.
      await tester.pumpAndSettle();

      expect(tester.binding.hasScheduledFrame, isFalse);
      expect(
        tester.binding.transientCallbackCount,
        0,
        reason: 'a live ticker means the app is still pinned awake',
      );
      expect(tester.takeException(), isNull);
      await drainMarqueeTimers(tester);
    });

    testWidgets('a hidden marquee never schedules a frame at all', (
      WidgetTester tester,
    ) async {
      final MarqueeVisibilityController controller = MarqueeVisibilityController(
        visible: false,
      );
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        wrap(
          const MarqueeText(text: kLongText, isExpanded: false),
          controller: controller,
        ),
      );
      await pumpPastStartDelay(tester);

      expect(
        tester.binding.transientCallbackCount,
        0,
        reason: 'TickerMode should have muted it before it ever started',
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await drainMarqueeTimers(tester);
    });

    testWidgets('becoming visible replays exactly one pass, then settles again', (
      WidgetTester tester,
    ) async {
      final MarqueeVisibilityController controller = MarqueeVisibilityController(
        visible: false,
      );
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        wrap(
          const MarqueeText(text: kLongText, isExpanded: false),
          controller: controller,
        ),
      );
      await tester.pumpAndSettle();
      final int generationWhileHidden = controller.generation;

      // Header comes back into view.
      controller.setVisible(true);
      await tester.pump();
      expect(
        controller.generation,
        generationWhileHidden + 1,
        reason: 'a hidden -> visible edge must bump the generation so the pass replays',
      );

      await pumpPastStartDelay(tester);
      expect(tester.binding.hasScheduledFrame, isTrue, reason: 'it should be scrolling again');

      await tester.pumpAndSettle();
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.takeException(), isNull);
      await drainMarqueeTimers(tester);
    });
  });

  group('visibility controller', () {
    test('ignores repeats, so a scroll-driven callback cannot restart it forever', () {
      final MarqueeVisibilityController controller = MarqueeVisibilityController();
      addTearDown(controller.dispose);

      int notifications = 0;
      controller.addListener(() => notifications++);

      // onHeaderVisiblityChanged fires on every shrink-offset change, not just
      // on transitions.
      controller
        ..setVisible(true)
        ..setVisible(true)
        ..setVisible(true);
      expect(notifications, 0);
      expect(controller.generation, 0);

      controller.setVisible(false);
      expect(notifications, 1);
      expect(controller.generation, 0, reason: 'hiding must not bump the generation');

      controller.setVisible(true);
      expect(notifications, 2);
      expect(controller.generation, 1);
    });
  });
}
