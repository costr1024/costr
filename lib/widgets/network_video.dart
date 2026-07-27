/// Inline network video player (video_player). Tap to play/pause. Disposes
/// the controller when the widget leaves the tree (e.g. scrolls off-screen).
library;

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

class NetworkVideo extends StatefulWidget {
  const NetworkVideo({super.key, required this.url, this.width, this.height});

  final String url;
  final int? width;
  final int? height;

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
    _controller = VideoPlayerController.networkUrl(Uri.parse(widget.url));
    _controller!.initialize().then((_) {
      if (mounted) setState(() => _initialized = true);
    }).catchError((Object _) {
      if (mounted) setState(() => _error = true);
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
