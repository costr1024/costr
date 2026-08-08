/// Immersive browsing support — hide the top app bar + bottom nav + FAB when
/// the user scrolls DOWN, restore on scroll UP (Amethyst pattern).
///
/// Two pieces:
/// - [ImmersiveScrollDetector]: wraps a scrollable, watches scroll direction,
///   and drives the global [appBarsVisibleProvider] (only when the
///   [immersiveBrowseProvider] toggle is on).
/// - [ImmersiveScaffold]: a drop-in replacement for `Scaffold(appBar:, body:)`
///   that, when the toggle is ON, collapses its top bar to the status-bar
///   height (animated) when bars are hidden; when OFF it renders the plain
///   `Scaffold(appBar:, body:)` byte-identically (zero regression).
///
/// The bottom nav + FAB live in `AppShell` (lib/app/router.dart) and animate
/// out by reading the same [appBarsVisibleProvider].
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';

/// Hide bars only after the user scrolls this many px DOWN, so a tiny
/// accidental drag doesn't yank the chrome away.
const double _kHideThreshold = 40;

/// NET UP scroll (px) needed to bring the bars back. Not a single negative
/// delta: real finger drags jitter — a downward scroll is interleaved with
/// momentary 2–10px upward micro-movements, and treating every one of those
/// as an intentional scroll-up made the chrome pop back in the middle of
/// browsing DOWN ("沉浸式…时不时会显示出来上下菜单栏"). A deliberate
/// scroll-back is far more than 20px net; a jitter burst never nets that
/// much. (Image loads that push content down were suspected, but resize
/// dispatches no ScrollNotification at all — verified by probe test — so the
/// jittering finger was the true trigger.)
const double _kShowThreshold = 20;

/// After a HIDE flip, ignore non-drag negative scroll updates for this long.
/// The hide animation GROWS the list's viewport (~200px over 220ms: top
/// chrome + bottom nav collapse). A ballistic fling near the list end then
/// lands out of range (RangeMaintainingScrollPhysics skips the silent clamp
/// for animating positions on purpose), and ClampingScrollPhysics pulls the
/// offset back with a spring — that pull-back arrives as
/// [ScrollUpdateNotification]s with NEGATIVE [ScrollUpdateNotification.scrollDelta]
/// and NO [ScrollUpdateNotification.dragDetails], which the show-hysteresis
/// logic misreads as "the user scrolled UP" → the chrome pops back while the
/// user is still scrolling DOWN → hide again → grow again → oscillation
/// ("关注 tab 快速下滑经常闪出上下菜单栏"; slow drags are unaffected because
/// DragScrollActivity clamps dimension changes silently via correctPixels,
/// which dispatches no notifications). 500ms covers the 220ms collapse
/// animation + the ballistic restart + the corrective spring. Real upward
/// DRAGS (dragDetails != null) are never suppressed.
const Duration immersivePostHideSuppress = Duration(milliseconds: 500);

/// True when the update is a corrective spring pull-back (or any non-drag
/// backward scroll): a [ScrollUpdateNotification] with no drag details and a
/// negative delta. While inside the post-hide suppression window these are
/// ignored ENTIRELY (neither shown for nor accumulated) by the detector.
bool immersiveIsCorrectivePullback({
  required bool isScrollUpdate,
  required DragUpdateDetails? dragDetails,
  required double scrollDelta,
}) => isScrollUpdate && dragDetails == null && scrollDelta < 0;

/// What a scroll notification means for bar visibility.
enum ImmersiveBarAction { show, hide, none }

/// Pure direction logic (testable without a widget tree). Consumes the
/// running [accumulated] net delta (positive = toward hide, negative = toward
/// show) and the current scroll delta.
///
/// - At/near the top (pixels <= 0) → show.
/// - Programmatic / non-user scroll (no scrollDelta) → none (don't fight).
/// - NET UP scroll reaching [showThreshold] → show. Tiny single-event
///   upward jitter stays accumulated (no chrome flip).
/// - NET DOWN scroll reaching [threshold] → hide.
ImmersiveBarAction immersiveBarActionFromPixels({
  required double pixels,
  required double? scrollDelta,
  required bool isUserUpdate,
  required double accumulated,
  required double threshold,
  required double showThreshold,
}) {
  if (pixels <= 0) return ImmersiveBarAction.show;
  if (!isUserUpdate || scrollDelta == null) return ImmersiveBarAction.none;
  final next = accumulated + scrollDelta;
  if (next <= -showThreshold) return ImmersiveBarAction.show;
  if (next >= threshold) return ImmersiveBarAction.hide;
  return ImmersiveBarAction.none;
}

/// [ScrollNotification]-based adapter over [immersiveBarActionFromPixels] for
/// the detector. Returns the action to take for bar visibility.
ImmersiveBarAction immersiveBarAction(
  ScrollNotification n,
  double accumulated,
  double threshold,
  double showThreshold,
) {
  final update = n is ScrollUpdateNotification ? n : null;
  return immersiveBarActionFromPixels(
    pixels: n.metrics.pixels,
    scrollDelta: update?.scrollDelta,
    isUserUpdate: update != null,
    accumulated: accumulated,
    threshold: threshold,
    showThreshold: showThreshold,
  );
}

/// Wraps [child] in a [NotificationListener] that drives the global
/// [appBarsVisibleProvider] from scroll direction. No-op (returns the bare
/// child) when [immersiveBrowseProvider] is off, so there's zero listener
/// overhead unless the user opted in.
///
/// Only VERTICAL scroll notifications are honored. The listener sees
/// notifications from EVERY scrollable in the subtree — including nested
/// HORIZONTAL ones (a post card's author-status line is a horizontal
/// SingleChildScrollView). Their horizontal metrics used to drive this
/// vertical show/hide logic — swiping a status line sideways hid or
/// re-showed the chrome ("菜单偶尔隐藏偶尔不隐藏" on the 关注 tab, whose
/// followees' statuses render that line). Axis-filtering them out fixes it
/// while keeping legit vertical nested scrollables (the profile page's
/// NestedScrollView inner list) in charge.
class ImmersiveScrollDetector extends ConsumerStatefulWidget {
  const ImmersiveScrollDetector({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<ImmersiveScrollDetector> createState() =>
      _ImmersiveScrollDetectorState();
}

class _ImmersiveScrollDetectorState
    extends ConsumerState<ImmersiveScrollDetector> {
  double _accumulated = 0;

  /// Corrective pull-backs are ignored until this instant (set on every HIDE
  /// flip — see [immersivePostHideSuppress]).
  DateTime _suppressCorrectiveUntil = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  Widget build(BuildContext context) {
    // watch so the detector rewraps when the user toggles immersive on/off.
    if (!ref.watch(immersiveBrowseProvider)) return widget.child;
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (!mounted) return false;
        // Ignore non-vertical scrollables nested inside the page (see class
        // doc) — their pixels/deltas have nothing to do with the vertical
        // chrome.
        final axis = n.metrics.axisDirection;
        if (axis != AxisDirection.down && axis != AxisDirection.up) {
          return false;
        }
        final now = DateTime.now();
        final update = n is ScrollUpdateNotification ? n : null;
        // While the chrome is collapsing (viewport growing), a fling near the
        // list end is pulled back by a corrective spring; its negative
        // drag-less deltas must not count as a user scroll-up, or the bars
        // oscillate back into view during a fast DOWN scroll. Ignore them
        // entirely — no show, no accumulation. Real finger drags carry
        // dragDetails and are never suppressed.
        if (now.isBefore(_suppressCorrectiveUntil) &&
            immersiveIsCorrectivePullback(
              isScrollUpdate: update != null,
              dragDetails: update?.dragDetails,
              scrollDelta: update?.scrollDelta ?? 0,
            )) {
          return false;
        }
        final action = immersiveBarAction(
          n,
          _accumulated,
          _kHideThreshold,
          _kShowThreshold,
        );
        switch (action) {
          case ImmersiveBarAction.show:
            _accumulated = 0;
            ref.read(appBarsVisibleProvider.notifier).setVisible(true);
          case ImmersiveBarAction.hide:
            _accumulated = 0;
            ref.read(appBarsVisibleProvider.notifier).setVisible(false);
            _suppressCorrectiveUntil = now.add(immersivePostHideSuppress);
          case ImmersiveBarAction.none:
            if (n is ScrollUpdateNotification && n.scrollDelta != null) {
              _accumulated = _accumulated + n.scrollDelta!;
            }
        }
        return false; // never consume — feed freeze/load-more must still fire
      },
      child: widget.child,
    );
  }
}

/// Drop-in replacement for `Scaffold(appBar: topBar, body: body)` that
/// collapses the top bar (animated) when immersive browse is on AND bars are
/// hidden. When immersive is OFF, renders the plain Scaffold unchanged.
class ImmersiveScaffold extends ConsumerWidget {
  const ImmersiveScaffold({
    super.key,
    required this.topBar,
    required this.body,
    this.belowBar,
    this.belowBarHeight = 0,
  });

  /// The page's top bar (typically `AppBar(...)`). Treated as a
  /// [PreferredSizeWidget]; its rendered height is `viewPadding.top +
  /// kToolbarHeight` (AppBar handles the status-bar inset itself).
  final PreferredSizeWidget topBar;

  /// Optional page tab row (全球/关注, 全部/提及…) rendered directly under
  /// [topBar] and collapsed TOGETHER with it when immersive hides the chrome.
  /// Previously these lived in the body, so scrolling down hid the AppBar but
  /// left the tab row pinned ("沉浸式不会隐藏 topbar" — the tabs ARE part of
  /// the top bar to the user). Fixed-height ([belowBarHeight]) so the
  /// collapse math stays exact.
  final Widget? belowBar;
  final double belowBarHeight;

  final Widget body;

  static const Duration _kDuration = Duration(milliseconds: 220);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // OFF → byte-identical to the prior Scaffold (plus the tab row in the
    // body where it used to live). No animated wrapper, no Column
    // restructure — guaranteed zero regression when the toggle is off.
    if (!ref.watch(immersiveBrowseProvider)) {
      return Scaffold(
        appBar: topBar,
        body: belowBar == null
            ? body
            : Column(
                children: <Widget>[
                  belowBar!,
                  Expanded(child: body),
                ],
              ),
      );
    }
    final hide = !ref.watch(appBarsVisibleProvider);
    final mq = MediaQuery.of(context);
    // AppBar renders at viewPadding.top + kToolbarHeight; the tab row adds
    // belowBarHeight. When hidden we still reserve viewPadding.top so
    // content never sits under the status bar; the bar content slides up
    // out of the clipped window.
    final expandedHeight = mq.viewPadding.top + kToolbarHeight + belowBarHeight;
    final collapsedHeight = mq.viewPadding.top;
    return Scaffold(
      // No appBar slot — we render the bar in the body so its height change
      // ANIMATES (Scaffold's appBar preferredSize relayouts instantly, not
      // animated). Putting it in a Column + AnimatedContainer lets the body
      // top edge slide together with the bar.
      body: Column(
        children: <Widget>[
          ClipRect(
            child: AnimatedContainer(
              duration: _kDuration,
              curve: Curves.easeOut,
              height: hide ? collapsedHeight : expandedHeight,
              width: double.infinity,
              child: OverflowBox(
                // The outer AnimatedContainer hands down its ANIMATED height
                // as a tight constraint (down to collapsedHeight when hidden).
                // The bar column must instead lay out at its fixed natural
                // height and just slide/clip — otherwise it overflows the
                // shrunken window on every intermediate animation frame
                // (RenderFlex overflow errors in debug). OverflowBox breaks
                // the constraint and lays the child out at expandedHeight
                // regardless; the outer ClipRect clips the excess.
                alignment: Alignment.topCenter,
                minHeight: expandedHeight,
                maxHeight: expandedHeight,
                child: AnimatedSlide(
                  duration: _kDuration,
                  curve: Curves.easeOut,
                  offset: hide ? const Offset(0, -1) : Offset.zero,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[topBar, ?belowBar],
                  ),
                ),
              ),
            ),
          ),
          Expanded(child: body),
        ],
      ),
    );
  }
}
