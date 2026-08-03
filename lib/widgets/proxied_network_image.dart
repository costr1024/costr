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
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// Public mirror proxy prefix. Append the FULL original URL (including its
/// own scheme) to route through an unblocked domain:
/// `proxiedUrl('https://cdn.example.com/x.png')`
/// → `https://proxy.bostr.online/https://cdn.example.com/x.png`.
String proxiedUrl(String original) {
  if (original.isEmpty) return original;
  if (original.startsWith('https://proxy.bostr.online/')) return original;
  return 'https://proxy.bostr.online/$original';
}

/// Hard cap on a media fetch (connect + send + receive-headers). The default
/// [HttpFileService] / [CachedNetworkImage] has NO timeout, so a host blocked
/// at the network layer (e.g. behind the GFW) hangs on the OS TCP timer
/// (~30–60s) before the error callback fires — making the "代理媒体"
/// affordance take a minute to appear, and the user wait ages for any
/// failure feedback. 8s is long enough for a slow-but-working origin yet
/// short enough to surface failures fast.
const Duration _kMediaTimeout = Duration(seconds: 8);

/// [FileService] that wraps the default [HttpFileService] with:
/// - a hard [_kMediaTimeout] on each GET (connect+send+headers), so blocked
///   hosts fail fast instead of hanging;
/// - a browser-like User-Agent (some media hosts/proxies 403 non-browser
///   UAs — the bare Dart/`http` default UA caused proxy.bostr.online loads
///   to fail in-app while the same URL worked in the phone browser).
///
/// The response BODY stream isn't timeout-bounded here (the cache manager
/// drains it after [get] returns); a server that sends headers then stalls
/// the body is rare and the connect/send timeout covers the dominant
/// GFW-block case.
class _TimedHttpFileService extends HttpFileService {
  @override
  Future<FileServiceResponse> get(
    String url, {
    Map<String, String>? headers,
  }) {
    final h = headers ?? const <String, String>{};
    if (!h.containsKey('User-Agent')) {
      headers = {
        ...h,
        'User-Agent': 'Costr/0.3 (Nostr client; +https://github.com/costr1024/costr)',
      };
    }
    return super.get(url, headers: headers).timeout(_kMediaTimeout);
  }
}

/// Singleton [CacheManager] backed by [_TimedHttpFileService] so EVERY
/// CostrNetworkImage load (avatars, post images/videos) gets the timeout +
/// UA fix while keeping disk caching (cross-session, 30-day, 200-object
/// LRU). A singleton is required — flutter_cache_manager opens a SQLite DB
/// per CacheManager instance, so creating one per image leaks file handles.
CacheManager? _proxyMediaCacheManager;
CacheManager get proxyMediaCacheManager =>
    _proxyMediaCacheManager ??= CacheManager(
      Config(
        'costr_media_lib',
        stalePeriod: const Duration(days: 30),
        maxNrOfCacheObjects: 200,
        fileService: _TimedHttpFileService(),
      ),
    );

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

  @override
  State<CostrNetworkImage> createState() => _CostrNetworkImageState();
}

class _CostrNetworkImageState extends State<CostrNetworkImage> {
  @override
  Widget build(BuildContext context) {
    final effectiveUrl =
        widget.forceProxy ? proxiedUrl(widget.url) : widget.url;
    Widget img = CachedNetworkImage(
      imageUrl: effectiveUrl,
      cacheManager: proxyMediaCacheManager,
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      memCacheHeight: widget.memCacheHeight,
      placeholder: (c, _) =>
          widget.placeholder?.call(c) ?? const SizedBox.shrink(),
      errorWidget: (c, _, e) =>
          widget.errorWidget?.call(c) ??
          widget.placeholder?.call(c) ??
          const SizedBox.shrink(),
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
