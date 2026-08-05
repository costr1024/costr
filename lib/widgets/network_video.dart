/// Inline network video player (video_player) with the shared controls
/// overlay ([VideoControlsOverlay], compact variant): progress bar, ±10s,
/// speed, share + fullscreen entry. Disposes the controller when the widget
/// leaves the tree (e.g. scrolls off-screen).
library;

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import 'fullscreen_video_page.dart';
import 'proxied_network_image.dart';
import 'video_controls.dart';

class NetworkVideo extends StatefulWidget {
  const NetworkVideo({
    super.key,
    required this.url,
    this.width,
    this.height,
    this.forceProxy = false,
  });

  final String url;
  final int? width;
  final int? height;

  /// When true, load through the proxy mirror ([proxiedUrl]) — flipped on by
  /// the post's "代理媒体" toggle. Manual only.
  final bool forceProxy;

  @override
  State<NetworkVideo> createState() => _NetworkVideoState();
}

class _NetworkVideoState extends State<NetworkVideo> {
  VideoPlayerController? _controller;
  bool _initialized = false;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void didUpdateWidget(covariant NetworkVideo oldWidget) {
    super.didUpdateWidget(oldWidget);
    // forceProxy flip → re-init with the (un)proxied URL.
    if (widget.forceProxy != oldWidget.forceProxy ||
        widget.url != oldWidget.url) {
      _controller?.dispose();
      _controller = null;
      _initialized = false;
      _error = false;
      _init();
    }
  }

  void _init() {
    final effectiveUrl = widget.forceProxy
        ? proxiedUrl(widget.url)
        : widget.url;
    _controller = VideoPlayerController.networkUrl(Uri.parse(effectiveUrl));
    _controller!
        .initialize()
        .then((_) {
          if (mounted) setState(() => _initialized = true);
        })
        .catchError((Object _) {
          if (mounted) {
            setState(() => _error = true);
          }
        });
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  void _enterFullscreen() {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    // Pause the inline player so the same clip isn't audible twice while the
    // fullscreen page (its own controller) is open. Position AND speed carry
    // over so playback continues seamlessly.
    final pos = c.value.position;
    final speed = c.value.playbackSpeed;
    c.pause();
    pushFullscreenVideo(
      context,
      url: widget.url,
      startPosition: pos,
      startSpeed: speed,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_error) {
      return _Box(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: const [
            Icon(Icons.broken_image_outlined),
            SizedBox(width: 6),
            Text('视频无法加载'),
          ],
        ),
      );
    }
    if (!_initialized) {
      return const _Box(child: CircularProgressIndicator());
    }
    final c = _controller!;
    final aspect = c.value.aspectRatio > 0 ? c.value.aspectRatio : 16 / 9;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: AspectRatio(
        aspectRatio: aspect,
        child: Stack(
          children: [
            VideoPlayer(c),
            VideoControlsOverlay(
              compact: true,
              controller: c,
              shareUrl: widget.url,
              onEnterFullscreen: _enterFullscreen,
            ),
          ],
        ),
      ),
    );
  }
}

class _Box extends StatelessWidget {
  const _Box({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        alignment: Alignment.center,
        child: child,
      ),
    );
  }
}
