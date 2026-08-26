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

/// Public mirror proxy prefix. The mirror expects the origin WITHOUT its
/// scheme — `https://proxy.bostr.online/<origin-domain>/<path>` (per its own
/// usage banner). Prepending the scheme'd URL (`/https://host/...`) makes the
/// proxy parse `https:` as the origin domain → `400 Invalid origin domain` →
/// broken image even though the origin loads fine direct:
/// `proxiedUrl('https://cdn.example.com/x.png')`
/// → `https://proxy.bostr.online/cdn.example.com/x.png`.
/// An `http://` origin is stripped the same way and fetched as https upstream
/// — nearly all media hosts serve https; an http-only host is the rare miss.
String proxiedUrl(String original) {
  if (original.isEmpty) return original;
  if (original.startsWith('https://proxy.bostr.online/')) return original;
  return 'https://proxy.bostr.online/${original.replaceFirst(_kScheme, '')}';
}

final RegExp _kScheme = RegExp(r'^https?://');

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
  Future<FileServiceResponse> get(String url, {Map<String, String>? headers}) {
    final h = headers ?? const <String, String>{};
    if (!h.containsKey('User-Agent')) {
      headers = {
        ...h,
        'User-Agent':
            'Costr/0.3 (Nostr client; +https://github.com/costr1024/costr)',
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
  if (s.contains('404') || s.contains('Not Found') || s.contains('not found')) {
    return false;
  }
  return true;
}

/// Origin hosts learned as blocked during THIS session (an origin attempt
/// failed with a block-like error). New [ProxyableNetworkImage]s for these
/// hosts skip the doomed origin and go straight to the proxy mirror — so after
/// the first nostr.build avatar times out, every other nostr.build
/// avatar/banner loads via proxy without repeating the 8s timeout. In-memory
/// only (resets per launch); the proxied bytes themselves persist in the disk
/// cache, so a re-tap after restart is instant.
final Set<String> _blockedHosts = <String>{};

String _hostOf(String url) => Uri.tryParse(url)?.host ?? url;

/// Whether [url]'s host was already learned as blocked this session.
@visibleForTesting
bool originHostBlocked(String url) => _blockedHosts.contains(_hostOf(url));

/// Remember [url]'s host as blocked so later loads skip the doomed origin.
@visibleForTesting
void markOriginHostBlocked(String url) => _blockedHosts.add(_hostOf(url));

/// Network image with a MANUAL "proxy" affordance, for avatars and banners
/// whose origin host is blocked at the network layer (GFW). Loads the origin
/// first; when that fails with a block-like error it shows a small 「代理」 chip
/// over the placeholder — tapping reloads through [proxiedUrl], and the
/// proxied bytes are disk-cached by [proxyMediaCacheManager] so subsequent
/// shows are instant. Deliberately opt-in (matches the post-media manual
/// pattern): it never auto-proxies, and a definitive 404 shows the plain
/// placeholder without offering the proxy.
class ProxyableNetworkImage extends StatefulWidget {
  const ProxyableNetworkImage({
    super.key,
    required this.url,
    required this.placeholder,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.clipOval = false,
    this.borderRadius,
  });

  final String url;

  /// Shown while loading, and behind the 「代理」 chip once the origin fails.
  final Widget placeholder;
  final double? width;
  final double? height;
  final BoxFit fit;
  final bool clipOval;
  final double? borderRadius;

  @override
  State<ProxyableNetworkImage> createState() => _ProxyableNetworkImageState();
}

class _ProxyableNetworkImageState extends State<ProxyableNetworkImage> {
  bool _useProxy = false;
  bool _originFailed = false;
  bool _proxyFailed = false;

  @override
  void initState() {
    super.initState();
    // Host already learned blocked this session → skip the doomed origin.
    if (originHostBlocked(widget.url)) _useProxy = true;
  }

  String get _effectiveUrl => _useProxy ? proxiedUrl(widget.url) : widget.url;

  void _onLoadError(Object error) {
    if (!mounted) return;
    if (_useProxy) {
      // The proxy attempt itself failed → give up to the plain placeholder.
      if (!_proxyFailed) setState(() => _proxyFailed = true);
      return;
    }
    if (!shouldProxyRetry(error)) {
      // A definitive 404 — the media is gone, proxying won't help; show the
      // placeholder without offering the proxy.
      if (!_proxyFailed) setState(() => _proxyFailed = true);
      return;
    }
    markOriginHostBlocked(widget.url);
    if (!_originFailed) setState(() => _originFailed = true);
  }

  void _retryWithProxy() => setState(() => _useProxy = true);

  @override
  Widget build(BuildContext context) {
    Widget content;
    if (_originFailed && !_useProxy) {
      // Origin blocked → placeholder + centered 「代理」 chip (manual opt-in).
      content = Stack(
        fit: StackFit.passthrough,
        alignment: Alignment.center,
        children: [widget.placeholder, _ProxyChip(onTap: _retryWithProxy)],
      );
    } else if (_proxyFailed) {
      content = widget.placeholder;
    } else {
      final provider = CachedNetworkImageProvider(
        _effectiveUrl,
        cacheManager: proxyMediaCacheManager,
        errorListener: _onLoadError,
      );
      content = Image(
        image: provider,
        width: widget.width,
        height: widget.height,
        fit: widget.fit,
        frameBuilder: (c, child, frame, syncLoaded) =>
            (syncLoaded || frame != null) ? child : widget.placeholder,
        errorBuilder: (c, _, _) => widget.placeholder,
      );
    }
    if (widget.clipOval) return ClipOval(child: content);
    if (widget.borderRadius != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(widget.borderRadius!),
        child: content,
      );
    }
    return content;
  }
}

/// The small centered 「代理」 chip shown over a failed avatar/banner. Tapping
/// opts it into loading through the proxy mirror.
class _ProxyChip extends StatelessWidget {
  const _ProxyChip({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black54,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: const [
              Icon(Icons.language, size: 13, color: Colors.white),
              SizedBox(width: 3),
              Text(
                '代理',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
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
    final effectiveUrl = widget.forceProxy
        ? proxiedUrl(widget.url)
        : widget.url;
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
