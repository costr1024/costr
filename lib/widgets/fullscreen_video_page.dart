/// Fullscreen video page. Owns its own [VideoPlayerController] (the inline
/// [NetworkVideo] keeps a separate one), starts from the inline's last
/// position AND speed so playback continues seamlessly, and forces
/// orientation on mobile by the clip's aspect (no-op on desktop). Controls
/// come from the shared [VideoControlsOverlay] (full variant) — same
/// progress/±10s/speed/share UI as inline, plus close + save-to-gallery.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../services/media_download.dart';
import 'video_controls.dart';

/// Push a fullscreen video route for [url], starting at [startPosition]
/// with [startSpeed] (both carried over from the inline player).
Future<void> pushFullscreenVideo(
  BuildContext context, {
  required String url,
  Duration startPosition = Duration.zero,
  double startSpeed = 1.0,
}) {
  return Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute<void>(
      builder: (BuildContext _) => _FullscreenVideoPage(
        url: url,
        startPosition: startPosition,
        startSpeed: startSpeed,
      ),
      fullscreenDialog: true,
    ),
  );
}

class _FullscreenVideoPage extends StatefulWidget {
  const _FullscreenVideoPage({
    required this.url,
    required this.startPosition,
    required this.startSpeed,
  });
  final String url;
  final Duration startPosition;
  final double startSpeed;

  @override
  State<_FullscreenVideoPage> createState() => _FullscreenVideoPageState();
}

class _FullscreenVideoPageState extends State<_FullscreenVideoPage> {
  VideoPlayerController? _controller;
  bool _initialized = false;
  bool _error = false;
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
          _controller!.setPlaybackSpeed(widget.startSpeed);
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
      body = Stack(
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
          VideoControlsOverlay(
            controller: c,
            shareUrl: widget.url,
            onClose: () => Navigator.of(context).pop(),
            onSave: _save,
            saving: _saving,
          ),
        ],
      );
    }
    return Scaffold(backgroundColor: Colors.black, body: body);
  }
}
