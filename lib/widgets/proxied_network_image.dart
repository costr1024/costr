/// Network image with an opt-in proxy mirror, used for post media.
///
/// Some media hosts are blocked at the network layer (e.g. behind the GFW)
/// and time out rather than 404. Rather than auto-retry every failure
/// through the public proxy mirror (which would overwhelm it), this widget
/// is **manual-only**: it loads the origin URL by default and reports a
/// failure via [onError]; the surrounding post exposes a "代理媒体" affordance
/// the user taps to flip [forceProxy] on, which rebuilds the image with the
/// proxy URL. The user opts in per post — the proxy only serves what's
/// explicitly requested.
///
/// [proxiedUrl] / [shouldProxyRetry] stay public for callers that need them.
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

/// Public mirror proxy prefix. Append the FULL original URL (including its
/// own scheme) to route through an unblocked domain:
/// `proxiedUrl('https://cdn.example.com/x.png')`
/// → `https://proxy.bostr.online/https://cdn.example.com/x.png`.
String proxiedUrl(String original) {
  if (original.isEmpty) return original;
  if (original.startsWith('https://proxy.bostr.online/')) return original;
  return 'https://proxy.bostr.online/$original';
}

/// True if [error] looks like a transient network/blocking failure that's
/// worth retrying through the proxy; false for a definitive "not found"
/// (404). Heuristic on the error's string form (cached_network_image wraps
/// dart:io exceptions). Kept for tests / future auto-retry callers; the
/// post-media path is manual today.
bool shouldProxyRetry(Object error) {
  final s = error.toString();
  if (s.contains('404') ||
      s.contains('Not Found') ||
      s.contains('not found')) {
    return false;
  }
  return true;
}

/// Network image that loads [url] (or its [proxiedUrl] mirror when
/// [forceProxy] is true) and reports load failures via [onError].
///
/// No automatic proxy swap — the proxy is opt-in via [forceProxy], driven by
/// the post's "代理媒体" affordance so the proxy mirror only serves media the
/// user explicitly asked it to. On any failure [onError] fires once per
/// attempt so the post can surface the affordance.
class CostrNetworkImage extends StatefulWidget {
  const CostrNetworkImage({
    super.key,
    required this.url,
    this.forceProxy = false,
    this.width,
    this.height,
    this.fit,
    this.placeholder,
    this.errorWidget,
    this.memCacheHeight,
    this.borderRadius,
    this.onError,
  });

  final String url;
  final bool forceProxy;
  final double? width;
  final double? height;
  final BoxFit? fit;
  final WidgetBuilder? placeholder;
  final WidgetBuilder? errorWidget;
  final int? memCacheHeight;
  final double? borderRadius;

  /// Fired when the load fails (origin or proxy attempt). The post uses this
  /// to decide whether to show its "代理媒体" affordance.
  final ValueChanged<bool>? onError;

  @override
  State<CostrNetworkImage> createState() => _CostrNetworkImageState();
}

class _CostrNetworkImageState extends State<CostrNetworkImage> {
  // Whether this attempt has already reported a failure (avoid duplicate
  // onError fires for a single load attempt).
  bool _reportedFailure = false;

  @override
  void didUpdateWidget(covariant CostrNetworkImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A new URL or a forceProxy flip starts a fresh attempt → re-enable
    // failure reporting so the post can re-track.
    if (widget.url != oldWidget.url ||
        widget.forceProxy != oldWidget.forceProxy) {
      _reportedFailure = false;
    }
  }

  void _fail() {
    if (_reportedFailure) return;
    _reportedFailure = true;
    widget.onError?.call(true);
  }

  @override
  Widget build(BuildContext context) {
    final effectiveUrl =
        widget.forceProxy ? proxiedUrl(widget.url) : widget.url;
    Widget img = CachedNetworkImage(
      imageUrl: effectiveUrl,
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      memCacheHeight: widget.memCacheHeight,
      placeholder: (c, _) =>
          widget.placeholder?.call(c) ?? const SizedBox.shrink(),
      errorWidget: (c, _, e) {
        // Report the failure to the post (once) so it can surface the
        // "代理媒体" affordance. No automatic proxy swap here.
        _fail();
        return widget.errorWidget?.call(c) ??
            widget.placeholder?.call(c) ??
            const SizedBox.shrink();
      },
      fadeInDuration: Duration.zero,
      fadeOutDuration: Duration.zero,
    );
    if (widget.borderRadius != null) {
      img = ClipRRect(
        borderRadius: BorderRadius.circular(widget.borderRadius!),
        child: img,
      );
    }
    return img;
  }
}
