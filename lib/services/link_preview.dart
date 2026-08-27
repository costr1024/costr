/// Classification + Open Graph previews for bare http(s) URLs in note
/// content.
///
/// A bare URL in a note can be a webpage, an image whose format lives ONLY in
/// the query string (小红书 CDN links like `…/1040g3k0…?imageView2/2/w/0/
/// format/jpg` have no extension in the path, so extension-based tokenizing
/// rendered them as plain text), or a video. The authoritative classifier is
/// the server's own `content-type`, so [inspectUrl] does ONE bounded streaming
/// GET and branches on the response headers:
///
/// - `image/*` / `video/*` / `audio/*` → [UrlImage] / [UrlVideo] /
///   [UrlAudio] — the body is cancelled right after the headers; not a
///   single byte of the media itself is downloaded here (the image/video/
///   audio widgets do the real loading, with disk caching).
/// - `text/html` → read at most ~128KB of the body (stopping early at
///   `</head>` — og: tags live in the head), parse Open Graph metadata via
///   [parseLinkPreview] → [UrlWebpage].
/// - anything else, or any failure → [UrlNone]; the URL then stays a plain
///   clickable link, exactly like today.
///
/// Anti-scraping walls (m.weibo.cn answers every UA with its "Sina Visitor
/// System" page, no og: tags at all) degrade via [isJunkTitle]: wall titles
/// are dropped so the card shows just the domain instead of garbage.
///
/// Candidates come from UNTRUSTED note content, so [inspectUrl] guards the
/// probe: http(s) only, private/loopback IP-literal hosts refused (incl. on
/// every redirect hop), per-request timeout, body byte cap.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Result of probing a bare URL from note content.
sealed class UrlInspection {
  const UrlInspection();
}

/// Not an image/video/audio/html page, or the probe failed — the URL stays a
/// plain clickable link.
class UrlNone extends UrlInspection {
  const UrlNone();
}

/// The server serves an image — render it as one (the URL carries the format
/// only in the query string or has no extension at all, which is why the
/// extension-based tokenizer missed it).
class UrlImage extends UrlInspection {
  const UrlImage(this.url);
  final String url;
}

/// The server serves a video — render a player.
class UrlVideo extends UrlInspection {
  const UrlVideo(this.url);
  final String url;
}

/// The server serves audio — render an inline audio player.
class UrlAudio extends UrlInspection {
  const UrlAudio(this.url);
  final String url;
}

/// The server serves an HTML page — show an Open Graph preview card.
class UrlWebpage extends UrlInspection {
  const UrlWebpage(this.preview);
  final LinkPreview preview;
}

/// Parsed Open Graph metadata for a webpage. [title]/[description]/[imageUrl]
/// are nullable: pages without og: tags degrade to [domain] only, and
/// anti-scraping walls lose their junk title+description too.
class LinkPreview {
  const LinkPreview({
    required this.pageUrl,
    required this.domain,
    this.title,
    this.description,
    this.imageUrl,
    this.siteName,
  });

  /// The page's URL after redirects (relative og:image values resolve
  /// against this).
  final String pageUrl;

  /// Display host, `www.` stripped (the card's bottom line; always present).
  final String domain;

  final String? title;
  final String? description;
  final String? imageUrl;
  final String? siteName;

  @override
  String toString() => 'LinkPreview($pageUrl, title=$title)';
}

/// Coarse response body class for [classifyContentType].
enum UrlContentKind { image, video, audio, html, other }

// --- pure helpers (unit-tested, no I/O) -------------------------------------

/// Classify a `Content-Type` header value. Only `text/html` and
/// `application/xhtml+xml` count as html (XML/JSON feeds are NOT pages and
/// must not be og-parsed).
UrlContentKind classifyContentType(String? contentType) {
  if (contentType == null) return UrlContentKind.other;
  final semi = contentType.indexOf(';');
  final t = (semi >= 0 ? contentType.substring(0, semi) : contentType)
      .trim()
      .toLowerCase();
  if (t.startsWith('image/')) return UrlContentKind.image;
  if (t.startsWith('video/')) return UrlContentKind.video;
  if (t.startsWith('audio/')) return UrlContentKind.audio;
  if (t == 'text/html' || t == 'application/xhtml+xml') {
    return UrlContentKind.html;
  }
  return UrlContentKind.other;
}

/// True if [host] is a private/loopback/link-local address literal (or
/// `localhost`) that a probe from untrusted note content must never touch —
/// router admin panels, cloud metadata (169.254.169.254), the user's own LAN.
/// Non-IP hostnames pass: the app already loads arbitrary note-content media
/// URLs through the image cache, so the probe adds no NEW name-based SSRF
/// class; this removes the cheapest literal-IP cases (DNS-rebinding and
/// private DNS names stay out of scope).
bool isBlockedProbeHost(String host) {
  var h = host.trim().toLowerCase();
  if (h.isEmpty) return true;
  if (h.startsWith('[') && h.endsWith(']')) h = h.substring(1, h.length - 1);
  if (h == 'localhost') return true;
  final v4 = _parseIpv4(h);
  if (v4 != null) {
    final a = v4[0];
    final b = v4[1];
    if (a == 0 || a == 10 || a == 127) return true; // 0/8, 10/8, loopback
    if (a == 169 && b == 254) return true; // link-local + cloud metadata
    if (a == 172 && b >= 16 && b <= 31) return true; // 172.16/12
    if (a == 192 && b == 168) return true; // 192.168/16
    if (a == 100 && b >= 64 && b <= 127) return true; // CGNAT 100.64/10
    if (a >= 224) return true; // multicast + reserved (incl. 255.255.255.255)
    return false;
  }
  if (h.contains(':')) {
    // IPv6 literal.
    if (h == '::' || h == '::1') return true; // unspecified + loopback
    if (h.startsWith('::ffff:')) {
      // IPv4-mapped — judge the embedded v4.
      final embedded = _parseIpv4(h.substring('::ffff:'.length));
      if (embedded != null) {
        return isBlockedProbeHost(
          '${embedded[0]}.${embedded[1]}.${embedded[2]}.${embedded[3]}',
        );
      }
    }
    final first = h.split(':').first;
    final n = int.tryParse(first.padRight(4, '0'), radix: 16);
    if (n != null) {
      if (n >= 0xfc00 && n <= 0xfdff) return true; // ULA fc00::/7
      if (n >= 0xfe80 && n <= 0xfebf) return true; // link-local fe80::/10
    }
  }
  return false;
}

List<int>? _parseIpv4(String s) {
  final parts = s.split('.');
  if (parts.length != 4) return null;
  final out = <int>[];
  for (final p in parts) {
    if (p.isEmpty || p.length > 3) return null;
    final v = int.tryParse(p);
    if (v == null || v < 0 || v > 255) return null;
    out.add(v);
  }
  return out;
}

/// Anti-scraping wall / login-gate titles that are useless as a preview
/// title (both the title AND description get dropped when one matches — they
/// come from the same wall page). Kept tiny and testable on purpose.
const List<String> _kJunkTitlePhrases = [
  'sina visitor system',
  'visitor system',
  'just a moment',
  'attention required',
  'access denied',
  '验证码',
  '人机验证',
  '安全验证',
];

/// True if [title] looks like an anti-bot/login wall page title.
bool isJunkTitle(String title) {
  final t = title.toLowerCase();
  return _kJunkTitlePhrases.any(t.contains);
}

const Map<String, String> _kNamedEntities = {
  'amp': '&',
  'lt': '<',
  'gt': '>',
  'quot': '"',
  'apos': "'",
  'nbsp': ' ',
  'hellip': '…',
  'mdash': '—',
  'ndash': '–',
  'middot': '·',
  'ldquo': '“',
  'rdquo': '”',
  'lsquo': '‘',
  'rsquo': '’',
};

final RegExp _kEntityRe = RegExp(r'&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);');

/// Decode the common HTML entities found in og: values and `<title>`.
/// Unknown entities pass through untouched.
String unescapeHtml(String s) {
  if (!s.contains('&')) return s;
  return s.replaceAllMapped(_kEntityRe, (Match m) {
    final e = m.group(1)!;
    if (e.startsWith('#x') || e.startsWith('#X')) {
      return _codepointToString(int.tryParse(e.substring(2), radix: 16)) ??
          m.group(0)!;
    }
    if (e.startsWith('#')) {
      return _codepointToString(int.tryParse(e.substring(1))) ?? m.group(0)!;
    }
    return _kNamedEntities[e] ?? m.group(0)!;
  });
}

String? _codepointToString(int? cp) {
  if (cp == null || cp <= 0 || cp > 0x10FFFF) return null;
  if (cp >= 0xD800 && cp <= 0xDFFF) return null; // surrogate halves
  return String.fromCharCode(cp);
}

/// Resolve a (possibly relative) og:image reference against the page URL.
/// Returns null for empty/unparseable refs and non-http(s) results.
String? resolveAgainst(String? ref, Uri base) {
  final r = ref?.trim();
  if (r == null || r.isEmpty) return null;
  final u = Uri.tryParse(r);
  if (u == null) return null;
  final abs = u.hasScheme ? u : base.resolveUri(u);
  if (abs.scheme != 'http' && abs.scheme != 'https') return null;
  return abs.toString();
}

/// Trailing punctuation that a URL extractor picks up but that isn't part of
/// the URL (Chinese text runs URLs straight into `。`/`，`). Mirrors what GFM
/// autolinks trim.
const String _kUrlTrailingPunct = '.,;:!?\'"()[]{}<>，。、；：！？…）（》《';

/// Strip trailing sentence punctuation from an extracted URL.
String trimUrlPunctuation(String url) {
  var end = url.length;
  while (end > 0 && _kUrlTrailingPunct.contains(url[end - 1])) {
    end--;
  }
  return url.substring(0, end);
}

/// Display host of [url] with a leading `www.` stripped; falls back to the
/// raw string when the URL doesn't parse.
String displayDomain(String url) {
  final host = Uri.tryParse(url)?.host ?? '';
  if (host.isEmpty) return url;
  return host.startsWith('www.') ? host.substring(4) : host;
}

final RegExp _kMetaTagRe = RegExp(r'<meta\b[^>]*>', caseSensitive: false);
final RegExp _kMetaKeyRe = RegExp(
  '''(?:property|name)\\s*=\\s*["']([^"']+)["']''',
  caseSensitive: false,
);
final RegExp _kMetaContentRe = RegExp(
  '''content\\s*=\\s*["']([^"']*)["']''',
  caseSensitive: false,
);
final RegExp _kTitleRe = RegExp(
  r'<title[^>]*>(.*?)</title>',
  caseSensitive: false,
  dotAll: true,
);

/// Parse Open Graph metadata out of an HTML page (the head is enough).
/// Tolerant by design: attribute order varies (`property=` before or after
/// `content=`), quotes are single or double, first occurrence of a key wins.
/// Falls back og:* → twitter:* → `<title>` / meta description. Anti-bot wall
/// titles ([isJunkTitle]) drop the title AND description so the card degrades
/// to domain-only. Always returns a [LinkPreview] (at minimum the domain).
///
/// [sourceUrl], when given, is the URL the note actually linked (pre-
/// redirect) — the card's domain line shows THAT, not the redirect target:
/// m.weibo.cn bounces every probe to `visitor.passport.weibo.cn`, and the
/// card must still say m.weibo.cn. [pageUrl] stays the post-redirect URL so
/// relative og:image values resolve correctly.
LinkPreview parseLinkPreview(String html, Uri pageUrl, {String? sourceUrl}) {
  final meta = <String, String>{};
  for (final m in _kMetaTagRe.allMatches(html)) {
    final tag = m.group(0)!;
    final key = _kMetaKeyRe.firstMatch(tag)?.group(1)?.trim().toLowerCase();
    final content = _kMetaContentRe.firstMatch(tag)?.group(1);
    if (key == null || key.isEmpty || content == null) continue;
    meta.putIfAbsent(key, () => content);
  }

  String? pick(List<String> keys) {
    for (final k in keys) {
      final v = meta[k]?.trim();
      if (v != null && v.isNotEmpty) return unescapeHtml(v);
    }
    return null;
  }

  var title = pick(const ['og:title', 'twitter:title']);
  if (title == null) {
    final t = _kTitleRe.firstMatch(html)?.group(1)?.trim();
    if (t != null && t.isNotEmpty) title = unescapeHtml(t);
  }
  var description = pick(const [
    'og:description',
    'twitter:description',
    'description',
  ]);
  final imageUrl = resolveAgainst(
    pick(const ['og:image', 'og:image:secure_url', 'twitter:image']),
    pageUrl,
  );
  final siteName = pick(const ['og:site_name']);

  if (title != null && isJunkTitle(title)) {
    title = null; // wall page — description is equally junk
    description = null;
  }
  if (title != null && title.length > 200) title = title.substring(0, 200);
  if (description != null && description.length > 500) {
    description = description.substring(0, 500);
  }

  return LinkPreview(
    pageUrl: pageUrl.toString(),
    domain: displayDomain(sourceUrl ?? pageUrl.toString()),
    title: title,
    description: description,
    imageUrl: imageUrl,
    siteName: siteName,
  );
}

/// Extensions that are already handled elsewhere (tokenized as media or
/// stripped as files) — such URLs must never be probed for previews.
const Set<String> _kHandledExts = {
  '.jpg',
  '.jpeg',
  '.png',
  '.gif',
  '.webp',
  '.bmp',
  '.mp4',
  '.webm',
  '.mov',
  '.m4v',
  '.mkv',
  '.pdf',
  '.zip',
  '.txt',
  '.md',
  '.mp3',
  '.m4a',
  '.aac',
  '.wav',
  '.ogg',
  '.oga',
  '.opus',
  '.flac',
};

final RegExp _kHttpUrlRe = RegExp(r'https?://[^\s]+');

/// Bare http(s) URLs in [text] that are preview/classification candidates:
/// not inside a markdown link/image (`](url)`), not in [exclude]
/// (tag-declared attachments already render as media), and not ending in a
/// media/file extension (already tokenized/stripped). Deduped in order of
/// first appearance, capped at [cap] — a bound on per-note probe fan-out.
List<String> extractPreviewCandidates(
  String text, {
  Set<String> exclude = const {},
  int cap = 4,
}) {
  final out = <String>[];
  final seen = <String>{};
  for (final m in _kHttpUrlRe.allMatches(text)) {
    if (out.length >= cap) break;
    // Inside a markdown link/image `](url)` — flutter_markdown renders it.
    if (m.start >= 2 && text.substring(m.start - 2, m.start) == '](') {
      continue;
    }
    final url = trimUrlPunctuation(m.group(0)!);
    if (url.isEmpty || exclude.contains(url)) continue;
    // Path part (without query/fragment) — extension here means the
    // tokenizer already owns this URL.
    var path = url;
    final q = path.indexOf('?');
    if (q >= 0) path = path.substring(0, q);
    final h = path.indexOf('#');
    if (h >= 0) path = path.substring(0, h);
    final lower = path.toLowerCase();
    if (_kHandledExts.any(lower.endsWith)) continue;
    if (!seen.add(url)) continue;
    out.add(url);
  }
  return out;
}

// --- I/O ---------------------------------------------------------------------

/// Browser-like UA for probes: several sites 403 the default Dart UA or serve
/// a different (og-less) page to it, and og yield is the whole point.
/// (Precedent for UA sensitivity: `_TimedHttpFileService`.)
const String _kProbeUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/126.0 Safari/537.36';

/// Probe [url] once and classify it: image / video / audio / webpage
/// (+ parsed Open Graph metadata) / none. NEVER throws — every failure
/// becomes [UrlNone] so the caller's fallback (plain clickable link) always
/// holds.
///
/// Bounds: [timeout] per request, ≤[maxRedirects] hops (re-guarded for
/// scheme + private hosts each hop), HTML bodies read up to [maxBodyBytes]
/// with an early stop at `</head>`. Media bodies are cancelled after the
/// headers — the probe never downloads the media itself.
Future<UrlInspection> inspectUrl(
  String url, {
  http.Client? client,
  Duration timeout = const Duration(seconds: 8),
  int maxBodyBytes = 128 * 1024,
  int maxRedirects = 5,
}) async {
  final uri = Uri.tryParse(url);
  if (uri == null ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      isBlockedProbeHost(uri.host)) {
    return const UrlNone();
  }
  final ownClient = client == null;
  final c = client ?? http.Client();
  try {
    var current = uri;
    for (var hop = 0; hop <= maxRedirects; hop++) {
      final req = http.Request('GET', current)..followRedirects = false;
      req.headers['User-Agent'] = _kProbeUserAgent;
      req.headers['Accept'] =
          'text/html,application/xhtml+xml,image/*,*/*;q=0.8';
      final http.StreamedResponse res;
      try {
        res = await c.send(req).timeout(timeout);
      } catch (_) {
        return const UrlNone();
      }
      final status = res.statusCode;
      if (status >= 300 && status < 400) {
        final location = res.headers['location'];
        await _cancelBody(res);
        if (location == null || location.isEmpty) return const UrlNone();
        final next = current.resolve(location);
        if ((next.scheme != 'http' && next.scheme != 'https') ||
            isBlockedProbeHost(next.host)) {
          return const UrlNone();
        }
        current = next;
        continue;
      }
      if (status < 200 || status >= 300) {
        await _cancelBody(res);
        return const UrlNone();
      }
      switch (classifyContentType(res.headers['content-type'])) {
        case UrlContentKind.image:
          await _cancelBody(res);
          return UrlImage(url);
        case UrlContentKind.video:
          await _cancelBody(res);
          return UrlVideo(url);
        case UrlContentKind.audio:
          await _cancelBody(res);
          return UrlAudio(url);
        case UrlContentKind.html:
          final html = await _readHeadHtml(res, maxBodyBytes, timeout);
          return UrlWebpage(parseLinkPreview(html, current, sourceUrl: url));
        case UrlContentKind.other:
          await _cancelBody(res);
          return const UrlNone();
      }
    }
    return const UrlNone(); // redirect budget exhausted
  } finally {
    if (ownClient) c.close();
  }
}

/// Cancel a response body without draining it (`drain()` would download the
/// whole file — a video!).
Future<void> _cancelBody(http.StreamedResponse res) async {
  final sub = res.stream.listen(null, onError: (Object _) {});
  await sub.cancel();
}

/// Read an html body up to [maxBodyBytes], stopping early once `</head>` has
/// arrived (og: tags live in the head; the rest of the page is dead weight).
Future<String> _readHeadHtml(
  http.StreamedResponse res,
  int maxBodyBytes,
  Duration timeout,
) async {
  final decoder = _encodingFromContentType(res.headers['content-type']).decoder;
  final buf = StringBuffer();
  var received = 0;
  final done = Completer<void>();
  late final StreamSubscription<List<int>> sub;
  sub = res.stream.listen(
    (chunk) {
      if (done.isCompleted) return;
      received += chunk.length;
      try {
        buf.write(decoder.convert(chunk));
      } catch (_) {
        // Undecodable bytes — keep whatever decoded cleanly (a decode
        // exception must never escape into the zone and kill the probe).
      }
      if (received >= maxBodyBytes ||
          buf.toString().toLowerCase().contains('</head>')) {
        done.complete();
        unawaited(sub.cancel());
      }
    },
    onError: (Object _) {
      if (!done.isCompleted) done.complete();
    },
    onDone: () {
      if (!done.isCompleted) done.complete();
    },
    cancelOnError: true,
  );
  try {
    await done.future.timeout(timeout);
  } catch (_) {
    // Timeout or otherwise unsettled — use whatever arrived.
  }
  await sub.cancel();
  return buf.toString();
}

/// Charset from a `Content-Type` header, limited to what Dart ships decoders
/// for (utf-8/latin1/ascii…); anything else falls back to lenient UTF-8.
/// UTF-8 is ALWAYS decoded leniently: the body byte cap can cut a multi-byte
/// sequence mid-character, and a strict decoder throws on that.
/// Known limitation: GBK/GB2312 pages garble — Dart has no GBK decoder, and
/// the CN sites this feature targets serve UTF-8.
Encoding _encodingFromContentType(String? contentType) {
  if (contentType != null) {
    final m = RegExp(
      r'charset\s*=\s*"?([\w-]+)"?',
      caseSensitive: false,
    ).firstMatch(contentType);
    final name = m?.group(1)?.toLowerCase();
    if (name != null && name != 'utf-8' && name != 'utf8') {
      final enc = Encoding.getByName(name);
      if (enc != null) return enc;
    }
  }
  return const Utf8Codec(allowMalformed: true);
}
