/// Fullscreen media viewer: pinch-zoom images (Flutter's built-in
/// [InteractiveViewer] — no extra dependency) with multi-image gallery swipe
/// ([PageView]). Opened by tapping a post image in [MarkdownContent]; closes
/// on back / the close button / a tap on the image.
///
/// Mirrors Amethyst's image viewer UX: black canvas, fit-to-screen images,
/// drag to pan, pinch to zoom (0.5×–4×), swipe left/right between images in
/// the same post, and a `1/N` counter. No Hero transition (the source is a
/// cached-network thumbnail whose dimensions aren't known synchronously, so
/// a Hero would flicker) — a quick black fade is used instead.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/media_download.dart';
import 'proxied_network_image.dart';

/// Push the viewer over the current route with a black fade transition.
/// [images] is the full set of images in the post (so the gallery can swipe
/// between them); [initialIndex] is the one that was tapped.
/// [initialForceProxy] inherits the post card's 代理媒体 toggle: when the
/// user already opted this post's media into the proxy mirror (because the
/// origin host is unreachable for them), the fullscreen image must start
/// proxied too — otherwise it spins on the dead origin ("大图一直加载中").
void pushMediaViewer(
  BuildContext context, {
  required List<String> images,
  int initialIndex = 0,
  bool initialForceProxy = false,
}) {
  if (images.isEmpty) return;
  Navigator.of(context, rootNavigator: true).push(
    PageRouteBuilder<void>(
      opaque: false,
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 180),
      pageBuilder:
          (BuildContext _, Animation<double> anim, Animation<double> _) {
            return FadeTransition(
              opacity: anim,
              child: _MediaViewerPage(
                images: images,
                initialIndex: initialIndex.clamp(0, images.length - 1),
                initialForceProxy: initialForceProxy,
              ),
            );
          },
    ),
  );
}

class _MediaViewerPage extends StatefulWidget {
  const _MediaViewerPage({
    required this.images,
    required this.initialIndex,
    this.initialForceProxy = false,
  });
  final List<String> images;
  final int initialIndex;
  final bool initialForceProxy;

  @override
  State<_MediaViewerPage> createState() => _MediaViewerPageState();
}

class _MediaViewerPageState extends State<_MediaViewerPage> {
  late final PageController _pageController = PageController(
    initialPage: widget.initialIndex,
  );
  late int _index = widget.initialIndex;
  bool _controlsVisible = true;
  bool _saving = false;
  // Snackbars go through a viewer-OWNED ScaffoldMessenger: the viewer is
  // pushed over a page that has its own Scaffold, so the app-level messenger
  // would render the snack in BOTH (doubled in widget tests, ghosted behind
  // the viewer in-app). Keyed state (not ScaffoldMessenger.of(context))
  // because this State sits ABOVE its own ScaffoldMessenger in the tree.
  final GlobalKey<ScaffoldMessengerState> _messengerKey =
      GlobalKey<ScaffoldMessengerState>();

  void _close() => Navigator.of(context).maybePop();

  void _toggleControls() {
    setState(() => _controlsVisible = !_controlsVisible);
  }

  /// Copy the CURRENT image's origin URL (not the proxy mirror — the origin
  /// is the canonical, shareable address). For sharing the URL where saving
  /// the file isn't wanted/possible.
  Future<void> _copyCurrentUrl() async {
    await Clipboard.setData(ClipboardData(text: widget.images[_index]));
    if (!mounted) return;
    _messengerKey.currentState?.showSnackBar(
      const SnackBar(content: Text('已复制图片链接'), duration: Duration(seconds: 2)),
    );
  }

  Future<void> _saveCurrent() async {
    if (_saving) return;
    setState(() => _saving = true);
    _messengerKey.currentState?.showSnackBar(
      const SnackBar(content: Text('保存中…'), duration: Duration(seconds: 4)),
    );
    final msg = await MediaDownload.save(
      url: widget.images[_index],
      kind: MediaKind.image,
    );
    if (!mounted) return;
    setState(() => _saving = false);
    _messengerKey.currentState
      ?..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 3),
          content: Text(msg ?? '已取消'),
        ),
      );
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ScaffoldMessenger(
      key: _messengerKey,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            // Gallery (PageView) even for a single image — one code path.
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _toggleControls,
              child: PageView.builder(
                controller: _pageController,
                itemCount: widget.images.length,
                onPageChanged: (int i) => setState(() => _index = i),
                itemBuilder: (BuildContext _, int i) => _ZoomableImage(
                  url: widget.images[i],
                  onTap: _toggleControls,
                  initialForceProxy: widget.initialForceProxy,
                ),
              ),
            ),
            // Top bar: close + counter. Fades with the controls.
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: AnimatedOpacity(
                opacity: _controlsVisible ? 1 : 0,
                duration: const Duration(milliseconds: 150),
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    child: Row(
                      children: [
                        _CircleButton(icon: Icons.close_rounded, onTap: _close),
                        const Spacer(),
                        if (widget.images.length > 1)
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: Text(
                              '${_index + 1} / ${widget.images.length}',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                                decoration: TextDecoration.none,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        _CircleButton(
                          icon: Icons.link_rounded,
                          onTap: _copyCurrentUrl,
                        ),
                        const SizedBox(width: 8),
                        _CircleButton(
                          icon: _saving
                              ? Icons.downloading_outlined
                              : Icons.download_rounded,
                          onTap: _saving ? null : _saveCurrent,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ZoomableImage extends StatefulWidget {
  const _ZoomableImage({
    required this.url,
    required this.onTap,
    this.initialForceProxy = false,
  });
  final String url;
  final VoidCallback onTap;
  final bool initialForceProxy;

  @override
  State<_ZoomableImage> createState() => _ZoomableImageState();
}

class _ZoomableImageState extends State<_ZoomableImage> {
  // Starts from the post card's 代理媒体 state (inherited via the viewer
  // route) so a post whose thumbnails only load through the proxy doesn't
  // spin on the dead origin here; the "使用代理加载" overlay below still
  // allows a manual opt-in per image.
  late bool _forceProxy = widget.initialForceProxy;

  @override
  Widget build(BuildContext context) {
    return InteractiveViewer(
      minScale: 0.5,
      maxScale: 4.0,
      // Allow panning past the edges when zoomed in (so the image isn't
      // clipped to viewport while inspecting detail).
      boundaryMargin: const EdgeInsets.all(double.infinity),
      clipBehavior: Clip.none,
      child: CostrNetworkImage(
        url: widget.url,
        forceProxy: _forceProxy,
        fit: BoxFit.contain,
        width: double.infinity,
        height: double.infinity,
        placeholder: (BuildContext _) => const Center(
          child: CircularProgressIndicator(color: Colors.white54),
        ),
        errorWidget: (BuildContext _) => InkWell(
          onTap: () => setState(() => _forceProxy = true),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: const [
                Icon(Icons.broken_image_outlined, color: Colors.white54),
                SizedBox(height: 8),
                Text(
                  '使用代理加载',
                  style: TextStyle(color: Colors.white54, fontSize: 13),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CircleButton extends StatelessWidget {
  const _CircleButton({required this.icon, required this.onTap});
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
