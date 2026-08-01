/// Fullscreen video page. Owns its own [VideoPlayerController] (the inline
/// [NetworkVideo] keeps a separate one), starts from the inline's last
/// position so the user doesn't restart, and forces landscape on mobile
/// (no-op on desktop). Isolated from the inline player so it can't regress
/// inline playback — the inline is paused while this is open.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

/// Push a fullscreen video route for [url], starting at [startPosition].
Future<void> pushFullscreenVideo(
  BuildContext context, {
  required String url,
  Duration startPosition = Duration.zero,
}) {
  return Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute<void>(
      builder: (BuildContext _) =>
          _FullscreenVideoPage(url: url, startPosition: startPosition),
      fullscreenDialog: true,
    ),
  );
}

class _FullscreenVideoPage extends StatefulWidget {
  const _FullscreenVideoPage({required this.url, required this.startPosition});
  final String url;
  final Duration startPosition;

  @override
  State<_FullscreenVideoPage> createState() => _FullscreenVideoPageState();
}

class _FullscreenVideoPageState extends State<_FullscreenVideoPage> {
  VideoPlayerController? _controller;
  bool _initialized = false;
  bool _error = false;
  bool _showControls = true;

  @override
  void initState() {
    super.initState();
    // Landscape on mobile only; harmless no-op on desktop.
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    _controller = VideoPlayerController.networkUrl(Uri.parse(widget.url));
    _controller!
        .initialize()
        .then((_) {
          if (!mounted) {
            _controller?.dispose();
            return;
          }
          _controller!.seekTo(widget.startPosition);
          _controller!.play();
          setState(() => _initialized = true);
        })
        .catchError((Object _) {
          if (mounted) setState(() => _error = true);
        });
  }

  @override
  void dispose() {
    _controller?.dispose();
    // Restore full orientation freedom (portrait + landscape) on mobile.
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    super.dispose();
  }

  void _togglePlay() {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    setState(() {
      c.value.isPlaying ? c.pause() : c.play();
    });
  }

  void _toggleControls() => setState(() => _showControls = !_showControls);

  @override
  Widget build(BuildContext context) {
    Widget body;
    if (_error) {
      body = const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.broken_image_outlined, color: Colors.white54, size: 40),
            SizedBox(height: 8),
            Text('视频无法加载', style: TextStyle(color: Colors.white54)),
          ],
        ),
      );
    } else if (!_initialized) {
      body = const Center(
        child: CircularProgressIndicator(color: Colors.white54),
      );
    } else {
      final c = _controller!;
      body = GestureDetector(
        onTap: _toggleControls,
        child: Stack(
          alignment: Alignment.center,
          children: [
            SizedBox(
              width: double.infinity,
              height: double.infinity,
              child: FittedBox(
                fit: BoxFit.contain,
                child: SizedBox(
                  width: c.value.size.width,
                  height: c.value.size.height,
                  child: VideoPlayer(c),
                ),
              ),
            ),
            if (_showControls)
              IconButton.filled(
                iconSize: 40,
                icon: Icon(c.value.isPlaying ? Icons.pause : Icons.play_arrow),
                onPressed: _togglePlay,
              ),
          ],
        ),
      );
    }
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          body,
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: AnimatedOpacity(
              opacity: _showControls ? 1 : 0,
              duration: const Duration(milliseconds: 150),
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: _CloseButton(
                      onTap: () => Navigator.of(context).pop(),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CloseButton extends StatelessWidget {
  const _CloseButton({required this.onTap});
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
          padding: EdgeInsets.all(8),
          child: Icon(Icons.close_rounded, color: Colors.white, size: 24),
        ),
      ),
    );
  }
}
