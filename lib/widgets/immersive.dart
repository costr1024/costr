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
/// accidental drag doesn't yank the chrome away. Any UP scroll shows them
/// immediately (matches "向上滚动再显示").
const double _kHideThreshold = 40;

/// What a scroll notification means for bar visibility.
enum ImmersiveBarAction { show, hide, none }

/// Pure direction logic (testable without a widget tree). Consumes the
/// running [accumulated] down-delta and the current scroll deltas.
///
/// - At/near the top (pixels <= 0) → show.
/// - Programmatic / non-user scroll (no scrollDelta) → none (don't fight).
/// - User UP scroll (scrollDelta < 0) → show (immediately).
/// - User DOWN scroll → accumulate; hide once the accumulated delta reaches
///   [threshold]; otherwise none (keep accumulating).
ImmersiveBarAction immersiveBarActionFromPixels({
  required double pixels,
  required double? scrollDelta,
  required bool isUserUpdate,
  required double accumulated,
  required double threshold,
}) {
  if (pixels <= 0) return ImmersiveBarAction.show;
  if (!isUserUpdate || scrollDelta == null) return ImmersiveBarAction.none;
  if (scrollDelta < 0) return ImmersiveBarAction.show;
  if (accumulated + scrollDelta >= threshold) return ImmersiveBarAction.hide;
  return ImmersiveBarAction.none;
}

/// [ScrollNotification]-based adapter over [immersiveBarActionFromPixels] for
/// the detector. Returns the action to take for bar visibility.
ImmersiveBarAction immersiveBarAction(
  ScrollNotification n,
  double accumulated,
  double threshold,
) {
  final update =
      n is ScrollUpdateNotification ? n : null;
  return immersiveBarActionFromPixels(
    pixels: n.metrics.pixels,
    scrollDelta: update?.scrollDelta,
    isUserUpdate: update != null,
    accumulated: accumulated,
    threshold: threshold,
  );
}

/// Wraps [child] in a [NotificationListener] that drives the global
/// [appBarsVisibleProvider] from scroll direction. No-op (returns the bare
/// child) when [immersiveBrowseProvider] is off, so there's zero listener
/// overhead unless the user opted in.
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

  @override
  Widget build(BuildContext context) {
    // watch so the detector rewraps when the user toggles immersive on/off.
    if (!ref.watch(immersiveBrowseProvider)) return widget.child;
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (!mounted) return false;
        final action = immersiveBarAction(n, _accumulated, _kHideThreshold);
        switch (action) {
          case ImmersiveBarAction.show:
            _accumulated = 0;
            ref.read(appBarsVisibleProvider.notifier).setVisible(true);
          case ImmersiveBarAction.hide:
            _accumulated = 0;
            ref.read(appBarsVisibleProvider.notifier).setVisible(false);
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
  });

  /// The page's top bar (typically `AppBar(...)`). Treated as a
  /// [PreferredSizeWidget]; its rendered height is `viewPadding.top +
  /// kToolbarHeight` (AppBar handles the status-bar inset itself).
  final PreferredSizeWidget topBar;

  final Widget body;

  static const Duration _kDuration = Duration(milliseconds: 220);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // OFF → byte-identical to the prior Scaffold. No animated wrapper, no
    // Column restructure — guaranteed zero regression when the toggle is off.
    if (!ref.watch(immersiveBrowseProvider)) {
      return Scaffold(appBar: topBar, body: body);
    }
    final hide = !ref.watch(appBarsVisibleProvider);
    final mq = MediaQuery.of(context);
    // AppBar renders at viewPadding.top + kToolbarHeight. When hidden we
    // still reserve viewPadding.top so content never sits under the status
    // bar; the bar content slides up out of the clipped window.
    final expandedHeight = mq.viewPadding.top + kToolbarHeight;
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
              child: AnimatedSlide(
                duration: _kDuration,
                curve: Curves.easeOut,
                offset: hide ? const Offset(0, -1) : Offset.zero,
                child: topBar,
              ),
            ),
          ),
          Expanded(child: body),
        ],
      ),
    );
  }
}
