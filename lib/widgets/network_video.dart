/// Inline network video player (video_player). Tap to play/pause. Disposes
/// the controller when the widget leaves the tree (e.g. scrolls off-screen).
library;

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import 'fullscreen_video_page.dart';
import 'proxied_network_image.dart';

class NetworkVideo extends StatefulWidget {
  const NetworkVideo({
    super.key,
    required this.url,
    this.width,
    this.height,
    this.forceProxy = false,
    this.onError,
  });

  final String url;
  final int? width;
  final int? height;

  /// When true, load through the proxy mirror ([proxiedUrl]) — flipped on by
  /// the post's "代理媒体" affordance. Manual only.
  final bool forceProxy;

  /// Fired when the video fails to initialize, so the post can surface its
  /// "代理媒体" affordance.
  final ValueChanged<bool>? onError;

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
    final effectiveUrl =
        widget.forceProxy ? proxiedUrl(widget.url) : widget.url;
    _controller = VideoPlayerController.networkUrl(Uri.parse(effectiveUrl));
    _controller!
        .initialize()
        .then((_) {
          if (mounted) setState(() => _initialized = true);
        })
        .catchError((Object _) {
          if (mounted) {
            setState(() => _error = true);
            widget.onError?.call(true);
          }
        });
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  void _togglePlay() {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    setState(() {
      c.value.isPlaying ? c.pause() : c.play();
    });
  }

  Future<void> _enterFullscreen() async {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    final pos = c.value.position;
    // Pause the inline player so the same clip isn't audible twice while the
    // fullscreen page (its own controller) is open.
    c.pause();
    await pushFullscreenVideo(context, url: widget.url, startPosition: pos);
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
          alignment: Alignment.center,
          children: [
            VideoPlayer(c),
            Center(
              child: IconButton.filled(
                icon: Icon(c.value.isPlaying ? Icons.pause : Icons.play_arrow),
                onPressed: _togglePlay,
              ),
            ),
            // Fullscreen affordance (top-right). The fullscreen page owns its
            // own controller and starts from the inline's current position.
            Positioned(
              top: 4,
              right: 4,
              child: _FullscreenButton(onTap: _enterFullscreen),
            ),
          ],
        ),
      ),
    );
  }
}

class _FullscreenButton extends StatelessWidget {
  const _FullscreenButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black38,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: const Padding(
          padding: EdgeInsets.all(6),
          child: Icon(Icons.fullscreen_rounded, color: Colors.white, size: 20),
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
