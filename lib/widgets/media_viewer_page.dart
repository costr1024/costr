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

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

/// Push the viewer over the current route with a black fade transition.
/// [images] is the full set of images in the post (so the gallery can swipe
/// between them); [initialIndex] is the one that was tapped.
void pushMediaViewer(
  BuildContext context, {
  required List<String> images,
  int initialIndex = 0,
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
              ),
            );
          },
    ),
  );
}

class _MediaViewerPage extends StatefulWidget {
  const _MediaViewerPage({required this.images, required this.initialIndex});
  final List<String> images;
  final int initialIndex;

  @override
  State<_MediaViewerPage> createState() => _MediaViewerPageState();
}

class _MediaViewerPageState extends State<_MediaViewerPage> {
  late final PageController _pageController = PageController(
    initialPage: widget.initialIndex,
  );
  late int _index = widget.initialIndex;
  bool _controlsVisible = true;

  void _close() => Navigator.of(context).maybePop();

  void _toggleControls() {
    setState(() => _controlsVisible = !_controlsVisible);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
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
              itemBuilder: (BuildContext _, int i) =>
                  _ZoomableImage(url: widget.images[i], onTap: _toggleControls),
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

class _ZoomableImage extends StatelessWidget {
  const _ZoomableImage({required this.url, required this.onTap});
  final String url;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InteractiveViewer(
      minScale: 0.5,
      maxScale: 4.0,
      // Allow panning past the edges when zoomed in (so the image isn't
      // clipped to viewport while inspecting detail).
      boundaryMargin: const EdgeInsets.all(double.infinity),
      clipBehavior: Clip.none,
      child: CachedNetworkImage(
        imageUrl: url,
        fit: BoxFit.contain,
        width: double.infinity,
        height: double.infinity,
        placeholder: (BuildContext _, String _) => const Center(
          child: CircularProgressIndicator(color: Colors.white54),
        ),
        errorWidget: (BuildContext _, String _, Object _) => const Center(
          child: Icon(Icons.broken_image_outlined, color: Colors.white54),
        ),
      ),
    );
  }
}

class _CircleButton extends StatelessWidget {
  const _CircleButton({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black38,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(icon, color: Colors.white, size: 24),
        ),
      ),
    );
  }
}
