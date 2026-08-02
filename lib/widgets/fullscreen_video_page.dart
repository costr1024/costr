/// Fullscreen video page. Owns its own [VideoPlayerController] (the inline
/// [NetworkVideo] keeps a separate one), starts from the inline's last
/// position so the user doesn't restart, and forces landscape on mobile
/// (no-op on desktop). Isolated from the inline player so it can't regress
/// inline playback — the inline is paused while this is open.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../services/media_download.dart';

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
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    // Orientation is applied after init based on the video's aspect ratio
    // (portrait video → lock portrait; landscape video → lock landscape).
    // Defer the lock so a portrait clip isn't forced sideways.
    _controller = VideoPlayerController.networkUrl(Uri.parse(widget.url));
    _controller!
        .initialize()
        .then((_) {
          if (!mounted) {
            _controller?.dispose();
            return;
          }
          _applyOrientation();
          _controller!.seekTo(widget.startPosition);
          _controller!.play();
          setState(() => _initialized = true);
        })
        .catchError((Object _) {
          if (mounted) setState(() => _error = true);
        });
  }

  /// Lock orientation to the video's own aspect: width >= height → landscape,
  /// else portrait. Lets portrait (vertical) clips play upright instead of
  /// being squeezed into a forced-landscape canvas.
  void _applyOrientation() {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    final size = c.value.size;
    final landscape = size.width >= size.height;
    SystemChrome.setPreferredOrientations(
      landscape
          ? [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]
          : [DeviceOrientation.portraitUp, DeviceOrientation.portraitDown],
    );
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      const SnackBar(content: Text('保存中…'), duration: Duration(seconds: 4)),
    );
    final msg = await MediaDownload.save(
      url: widget.url,
      kind: MediaKind.video,
    );
    if (!mounted) return;
    setState(() => _saving = false);
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 3),
          content: Text(msg ?? '已取消'),
        ),
      );
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
                  child: Row(
                    children: [
                      _CloseButton(
                        onTap: () => Navigator.of(context).pop(),
                      ),
                      const Spacer(),
                      _CloseButton(
                        icon: _saving
                            ? Icons.downloading_outlined
                            : Icons.download_rounded,
                        onTap: _saving ? null : _save,
                      ),
                    ],
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
  const _CloseButton({this.icon = Icons.close_rounded, required this.onTap});
  final IconData icon;
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
          padding: const EdgeInsets.all(8),
          child: Icon(
            icon,
            color: disabled ? Colors.white38 : Colors.white,
            size: 24,
          ),
        ),
      ),
    );
  }
}
