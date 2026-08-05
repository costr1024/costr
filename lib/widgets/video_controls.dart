/// Shared video-player controls overlay (X/Bilibili-style), used by both the
/// inline [NetworkVideo] (compact) and the fullscreen page (full). Owns no
/// [VideoPlayerController] — it attaches a listener to the one it is given
/// and disposes the listener only. Controls auto-hide 3s into playback,
/// stay visible while paused, and the surface is always dark-styled
/// (white-on-black38) regardless of the app theme.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';

import '../utils/format.dart';

/// Playback speed choices (common players).
const List<double> kPlaybackSpeeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

/// Clamps a ±[deltaSeconds] seek step into [0, total] so the ±10s buttons
/// never seek past the ends.
Duration clampSeek(Duration current, int deltaSeconds, Duration total) {
  final next = current + Duration(seconds: deltaSeconds);
  if (next < Duration.zero) return Duration.zero;
  if (next > total) return total;
  return next;
}

/// Shares a raw video URL through the native share sheet; on desktop
/// platforms where share_plus is unavailable, falls back to copying the
/// link (same pattern as the post share action).
Future<void> shareVideoUrl(BuildContext context, String url) async {
  try {
    await SharePlus.instance.share(ShareParams(text: url, subject: 'Costr 视频'));
  } catch (_) {
    try {
      await Clipboard.setData(ClipboardData(text: url));
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('已复制视频链接'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('分享失败'), duration: Duration(seconds: 2)),
        );
      }
    }
  }
}

/// Bottom-sheet speed picker (app sheet pattern). Returns the chosen speed,
/// null when dismissed without picking.
Future<double?> showSpeedPickerSheet(BuildContext context, double current) {
  // Fullscreen playback is usually landscape, where six tiles + title are
  // taller than the screen — the sheet content must scroll. Full-screen
  // width is also far too wide for a short option list, so in landscape
  // the sheet is narrowed to a centered panel.
  final landscape = MediaQuery.orientationOf(context) == Orientation.landscape;
  return showModalBottomSheet<double>(
    context: context,
    constraints: landscape ? const BoxConstraints(maxWidth: 320) : null,
    builder: (BuildContext ctx) => SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text('播放速度', style: TextStyle(fontSize: 13)),
            ),
            for (final s in kPlaybackSpeeds)
              ListTile(
                dense: true,
                title: Text(formatSpeed(s)),
                trailing: s == current ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(ctx, s),
              ),
            const SizedBox(height: 4),
          ],
        ),
      ),
    ),
  );
}

/// The controls overlay. [compact] = inline-in-feed variant (smaller center
/// cluster, top-right share/fullscreen chips); full variant adds a SafeArea
/// top bar (close/share/save) for the fullscreen page.
class VideoControlsOverlay extends StatefulWidget {
  const VideoControlsOverlay({
    super.key,
    required this.controller,
    this.compact = false,
    required this.shareUrl,
    this.onEnterFullscreen,
    this.onClose,
    this.onSave,
    this.saving = false,
  });

  final VideoPlayerController controller;

  /// Inline variant: smaller buttons, fullscreen entry top-right.
  final bool compact;

  /// Raw video URL handed to the share action.
  final String shareUrl;

  /// Compact only: enter the fullscreen page.
  final VoidCallback? onEnterFullscreen;

  /// Full only: close the fullscreen page / save to gallery.
  final VoidCallback? onClose;
  final VoidCallback? onSave;
  final bool saving;

  @override
  State<VideoControlsOverlay> createState() => _VideoControlsOverlayState();
}

class _VideoControlsOverlayState extends State<VideoControlsOverlay> {
  static const _hideDelay = Duration(seconds: 3);

  bool _visible = true;
  Timer? _hideTimer;

  /// Local position while scrubbing (seek happens on release only, avoiding
  /// a seek-storm on remote URLs).
  Duration? _scrubPos;
  bool _wasPlaying = false;

  VideoPlayerController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _c.addListener(_onValue);
    if (_c.value.isPlaying) _armHide();
  }

  @override
  void didUpdateWidget(covariant VideoControlsOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onValue);
      widget.controller.addListener(_onValue);
      _hideTimer?.cancel();
      setState(() {
        _visible = true;
        _scrubPos = null;
      });
      if (widget.controller.value.isPlaying) _armHide();
    }
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _c.removeListener(_onValue);
    super.dispose();
  }

  void _onValue() {
    if (!mounted) return;
    final playing = _c.value.isPlaying;
    // Paused → controls stay up; playing → arm the 3s hide.
    if (!playing) {
      _hideTimer?.cancel();
      if (!_visible && _scrubPos == null) _visible = true;
    }
    setState(() {});
  }

  void _armHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(_hideDelay, () {
      if (!mounted) return;
      if (_c.value.isPlaying && _scrubPos == null && _visible) {
        setState(() => _visible = false);
      }
    });
  }

  void _toggleVisible() {
    setState(() => _visible = !_visible);
    if (_visible && _c.value.isPlaying) {
      _armHide();
    } else {
      _hideTimer?.cancel();
    }
  }

  void _togglePlay() {
    if (!_c.value.isInitialized) return;
    // Decide on the pre-toggle state: play()/pause() write the platform
    // value back asynchronously, so reading isPlaying right after would
    // see the stale side.
    if (_c.value.isPlaying) {
      _c.pause();
      _hideTimer?.cancel();
      setState(() => _visible = true);
    } else {
      _c.play();
      _armHide();
    }
  }

  void _step(int seconds) {
    if (!_c.value.isInitialized) return;
    _c.seekTo(clampSeek(_c.value.position, seconds, _c.value.duration));
    if (_visible && _c.value.isPlaying) _armHide();
  }

  void _scrubStart(double millis) {
    _wasPlaying = _c.value.isPlaying;
    _hideTimer?.cancel();
    if (_wasPlaying) _c.pause();
    setState(() => _scrubPos = Duration(milliseconds: millis.round()));
  }

  void _scrubTo(double millis) {
    setState(() => _scrubPos = Duration(milliseconds: millis.round()));
  }

  void _scrubEnd(double millis) {
    _c.seekTo(Duration(milliseconds: millis.round()));
    if (_wasPlaying) _c.play();
    setState(() => _scrubPos = null);
    if (_c.value.isPlaying) _armHide();
  }

  Future<void> _pickSpeed() async {
    final v = await showSpeedPickerSheet(context, _c.value.playbackSpeed);
    if (v != null && mounted) await _c.setPlaybackSpeed(v);
  }

  @override
  Widget build(BuildContext context) {
    final v = _c.value;
    final position = _scrubPos ?? v.position;
    final totalMs = v.duration.inMilliseconds.toDouble();
    final compact = widget.compact;
    return SizedBox.expand(
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Tap-only catcher under the bars: never wins against the feed's
          // vertical drag, so inline scrolling is unaffected.
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _toggleVisible,
            ),
          ),
          if (v.isBuffering)
            const Center(
              child: CircularProgressIndicator(
                color: Colors.white,
                strokeWidth: 2,
              ),
            ),
          if (_visible) ...[
            // Center cluster: -10s / play-pause / +10s.
            Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _CircleChip(
                    icon: Icons.fast_rewind,
                    size: compact ? 20 : 28,
                    onTap: () => _step(-10),
                  ),
                  SizedBox(width: compact ? 12 : 24),
                  _CircleChip(
                    icon: v.isPlaying ? Icons.pause : Icons.play_arrow,
                    size: compact ? 28 : 44,
                    onTap: _togglePlay,
                  ),
                  SizedBox(width: compact ? 12 : 24),
                  _CircleChip(
                    icon: Icons.fast_forward,
                    size: compact ? 20 : 28,
                    onTap: () => _step(10),
                  ),
                ],
              ),
            ),
            // Top bar.
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: compact
                  ? Padding(
                      padding: const EdgeInsets.all(4),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          _CircleChip(
                            icon: Icons.share_outlined,
                            size: 16,
                            onTap: () =>
                                shareVideoUrl(context, widget.shareUrl),
                          ),
                          const SizedBox(width: 6),
                          if (widget.onEnterFullscreen != null)
                            _CircleChip(
                              icon: Icons.fullscreen_rounded,
                              size: 18,
                              onTap: widget.onEnterFullscreen,
                            ),
                        ],
                      ),
                    )
                  : SafeArea(
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Row(
                          children: [
                            _CircleChip(
                              icon: Icons.close_rounded,
                              size: 24,
                              onTap: widget.onClose,
                            ),
                            const Spacer(),
                            _CircleChip(
                              icon: Icons.share_outlined,
                              size: 22,
                              onTap: () =>
                                  shareVideoUrl(context, widget.shareUrl),
                            ),
                            const SizedBox(width: 8),
                            _CircleChip(
                              icon: widget.saving
                                  ? Icons.downloading_outlined
                                  : Icons.download_rounded,
                              size: 24,
                              onTap: widget.saving ? null : widget.onSave,
                            ),
                          ],
                        ),
                      ),
                    ),
            ),
            // Bottom bar: current / slider / total / speed.
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Container(
                color: Colors.black38,
                padding: EdgeInsets.symmetric(
                  horizontal: compact ? 8 : 12,
                  vertical: 2,
                ),
                child: Row(
                  children: [
                    Text(
                      formatDuration(position),
                      style: const TextStyle(color: Colors.white, fontSize: 11),
                    ),
                    Expanded(
                      child: SliderTheme(
                        data: SliderThemeData(
                          trackHeight: 3,
                          activeTrackColor: Colors.white,
                          inactiveTrackColor: Colors.white24,
                          thumbColor: Colors.white,
                          overlayShape: SliderComponentShape.noOverlay,
                          thumbShape: RoundSliderThumbShape(
                            enabledThumbRadius: compact ? 5 : 7,
                          ),
                        ),
                        child: Slider(
                          value: position.inMilliseconds.toDouble().clamp(
                            0,
                            totalMs > 0 ? totalMs : 1,
                          ),
                          min: 0,
                          max: totalMs > 0 ? totalMs : 1,
                          onChangeStart: _scrubStart,
                          onChanged: _scrubTo,
                          onChangeEnd: _scrubEnd,
                        ),
                      ),
                    ),
                    Text(
                      formatDuration(v.duration),
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 11,
                      ),
                    ),
                    TextButton(
                      onPressed: _pickSpeed,
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.white,
                        minimumSize: Size.zero,
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: Text(formatSpeed(v.playbackSpeed)),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// White-on-black38 circular chip button — the overlay's only button style
/// (same look as the old fullscreen close/save buttons).
class _CircleChip extends StatelessWidget {
  const _CircleChip({required this.icon, required this.size, this.onTap});
  final IconData icon;
  final double size;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final disabled = onTap == null;
    return Material(
      color: Colors.black38,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.all(size * 0.35),
          child: Icon(
            icon,
            color: disabled ? Colors.white38 : Colors.white,
            size: size,
          ),
        ),
      ),
    );
  }
}
