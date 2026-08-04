/// Double-tap shortcut that never fights its children in the gesture arena.
///
/// A `GestureDetector(onDoubleTap: …)` wrapped around tappable children
/// (SegmentedButton, tab buttons) NEVER fires: on the first tap the child's
/// own tap recognizer accepts and rejects the parent's double-tap
/// recognizer. So this widget watches raw pointer events with a [Listener]
/// instead — it participates in no arena, and the children keep handling
/// every tap exactly as before (both taps of the double-tap still reach
/// them; the shortcut simply ADDITIONALLY fires on the second tap-down,
/// which is also when the platform's own double-tap recognizers fire).
///
/// Used for the "double-tap the page tab row to jump back to the newest
/// post/notification" shortcut (首页 全球/关注、通知 全部/提及).
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

class DoubleTapShortcut extends StatefulWidget {
  const DoubleTapShortcut({
    super.key,
    required this.child,
    required this.onDoubleTap,
    this.now,
  });

  final Widget child;
  final VoidCallback onDoubleTap;

  /// Test seam: widget tests synthesize pointer events with a zero
  /// [PointerEvent.timeStamp] (the fake clock doesn't stamp them), so tests
  /// inject a controllable clock to exercise the double-tap window/timeout.
  /// Production uses the event timestamps (null here).
  @visibleForTesting
  final Duration Function()? now;

  @override
  State<DoubleTapShortcut> createState() => _DoubleTapShortcutState();
}

class _DoubleTapShortcutState extends State<DoubleTapShortcut> {
  /// Down position of every active pointer (usually just one).
  final Map<int, Offset> _downs = <int, Offset>{};

  /// The last completed tap (time + position at pointer-up).
  Duration? _lastTapAt;
  Offset? _lastTapPos;

  /// Pointer whose down already fired [DoubleTapShortcut.onDoubleTap] — its
  /// up must NOT seed a new candidate (a triple-tap fires once, like the
  /// platform recognizers: tap3 starts a fresh sequence needing a tap4).
  int? _firedPointer;

  void _onPointerDown(PointerDownEvent e) {
    _downs[e.pointer] = e.localPosition;
    if (_downs.length > 1) {
      // A second finger went down while the first is still touching —
      // that's a multi-touch gesture, never a double-tap.
      _lastTapAt = null;
      _lastTapPos = null;
      return;
    }
    final t = widget.now?.call() ?? e.timeStamp;
    final prev = _lastTapAt;
    final prevPos = _lastTapPos;
    _lastTapAt = null;
    _lastTapPos = null;
    if (prev != null &&
        prevPos != null &&
        t >= prev &&
        t - prev <= kDoubleTapTimeout &&
        (e.localPosition - prevPos).distance <= kDoubleTapSlop) {
      _firedPointer = e.pointer;
      widget.onDoubleTap();
    }
  }

  void _onPointerUp(PointerUpEvent e) {
    final down = _downs.remove(e.pointer);
    if (down == null || _downs.isNotEmpty) return;
    if (e.pointer == _firedPointer) {
      _firedPointer = null;
      return;
    }
    // A tap (not a drag) becomes the candidate for a second tap.
    if ((e.localPosition - down).distance <= kDoubleTapTouchSlop) {
      _lastTapAt = widget.now?.call() ?? e.timeStamp;
      _lastTapPos = e.localPosition;
    }
  }

  void _onPointerCancel(PointerCancelEvent e) {
    _downs.remove(e.pointer);
    if (e.pointer == _firedPointer) _firedPointer = null;
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onPointerDown,
      onPointerUp: _onPointerUp,
      onPointerCancel: _onPointerCancel,
      child: widget.child,
    );
  }
}
