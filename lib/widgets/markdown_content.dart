/// Renders post content as markdown (GitHub-flavored) with:
/// - NIP-19 `npub1`/`nprofile1` mentions linkified (tappable -> /u/:pubkey),
///   labeled with the resolved kind-0 name (else shortened entity).
/// - Contiguous markdown images grouped into a 3-column square thumbnail grid
///   (九宫格 style); images separated by text form separate groups. A single
///   image renders full-width (not gridded).
/// - Videos (`![](video.mp4)` or imeta `m video/*`) render full-width via
///   video_player.
/// - Audio (bare `….mp3/…` URLs, imeta `m audio/*`) renders as an inline
///   player ([NetworkAudio], Amethyst-style waveform card).
/// - NIP-19 `naddr1…` address references (parameterized replaceable events,
///   typically long-form articles) render as embedded cards below, same
///   pattern as NIP-27 quote embeds.
/// - NIP-92 imeta media not already in the content is appended below; its
///   images are gridded together, videos full-width, audio as players.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:markdown/markdown.dart' hide Text;
import 'package:url_launcher/url_launcher.dart';

import '../app/providers.dart';
import '../app/theme.dart';
import '../models/event.dart';
import '../utils/nav.dart';
import '../utils/nip19.dart';
import '../services/link_preview.dart';
import '../services/media_download.dart';
import 'avatar.dart';
import 'display_name.dart';
import 'media_viewer_page.dart';
import 'network_audio.dart';
import 'proxied_network_image.dart';
import 'mention_linkifier.dart';
import 'network_video.dart';

/// Matches nostr: prefix + npub1/nprofile1 entity (consumes the nostr: prefix
/// so it doesn't linger as orphan text before the link). Group 1 captures the
/// FULL bare entity (with its data) so the link href carries the whole entity,
/// not just the `npub1`/`nprofile1` prefix. The `(?<!\]\()` lookbehind stops
/// it from matching an entity already inside a markdown link's `](href)` —
/// otherwise a `[@name](nostr:npub1…)` mention (legacy form costr published)
/// gets double-wrapped into `[@name]([@label](nostr:npub1…))`. flutter_markdown
/// renders the intact markdown link itself, and the `onTapLink` handler routes
/// `nostr:` hrefs to the profile.
final RegExp _pubkeyEntityRegex = RegExp(
  r'(?<!\]\()(?:nostr:)?((?:nprofile1|npub1)[qpzry9x8gf2tvdw0s3jn54khce6mua7l]{6,})',
);

/// Matches `nostr:nevent1…` / `nostr:note1…` (NIP-27 event references). Group
/// 1 captures the bare entity so we can decode the referenced event id.
final RegExp _eventEntityRegex = RegExp(
  r'(?:nostr:)?((?:nevent1|note1)[qpzry9x8gf2tvdw0s3jn54khce6mua7l]{6,})',
);

/// Matches `nostr:naddr1…` (NIP-19 address coordinates of parameterized
/// replaceable events — typically long-form articles). Group 1 captures the
/// bare entity so [naddrDecode] can read kind/author/d + relay hints.
final RegExp _addrEntityRegex = RegExp(
  r'(?:nostr:)?(naddr1[qpzry9x8gf2tvdw0s3jn54khce6mua7l]{6,})',
);

/// Preserve blank lines in text fed to [MarkdownBody]. Markdown collapses
/// runs of blank lines into a single paragraph break; Amethyst renders every
/// blank line. Replace each empty line with a zero-width space (non-whitespace
/// → not a blank line → no paragraph split). Pair with `softLineBreak: true`
/// on MarkdownBody so single `\n` also render as line breaks.
///
/// One exception: a blank line must stay a REAL blank line when it ends a
/// blockquote. A zero-width space there is NOT a blank line, so the markdown
/// parser treats it as a lazy-continuation line and absorbs the ENTIRE
/// following content into the quote (a 财新-style `> 导语` post rendered its
/// whole article inside the quote box). Track blockquote state: while inside
/// one, keep blank lines truly blank so the quote ends where the author's
/// blank line says it does. Public for unit testing.
String preserveBlankLines(String s) {
  final out = <String>[];
  var inBlockquote = false;
  for (final l in s.split('\n')) {
    if (l.trim().isEmpty) {
      out.add(inBlockquote ? '' : '\u200B');
      inBlockquote = false;
    } else {
      out.add(l);
      // A `>` line opens/continues a quote; any other non-blank line keeps
      // the current state (right after a `>` line it is a lazy-continuation
      // line, still inside the quote; otherwise ordinary text).
      if (l.trimLeft().startsWith('>')) inBlockquote = true;
    }
  }
  return out.join('\n');
}

/// Bare media URLs in content (image/video/audio/file extensions) — stripped
/// from text segments so they don't show as plain text; rendered via imeta
/// extra or, for image/video/audio, by [tokenizeContent] below. Negative
/// lookbehind on `](` keeps it from matching the URL inside a markdown
/// link/image `](url)`, so `[text](x.jpg)` links aren't broken. The trailing
/// `[?#]…` group keeps query/fragment WITH the URL — signed CDN links like
/// `…/x.mp4?sign=…&t=…` must strip whole; without it the match ended at
/// `.mp4` and left an orphan `?sign=…` behind.
final RegExp _bareMediaUrl = RegExp(
  r'(?<!\]\()https?://[^\s)]+\.(?:jpg|jpeg|png|gif|webp|bmp|mp4|webm|mov|m4v|mkv|pdf|zip|txt|md|mp3|m4a|aac|wav|ogg|oga|opus|flac)(?:[?#][^\s)]*)?',
);

/// Strip bare media/file URLs from [text]. Public wrapper so the strip
/// regex is unit-testable ([_bareMediaUrl] is private).
String stripBareMediaUrls(String text) => text.replaceAll(_bareMediaUrl, '');

/// Combined media token: a markdown image `![alt](url)` OR a bare
/// image/video/audio URL. Group 1+2 = markdown image alt + url; group 3 =
/// bare url (including any `?query`/`#fragment` — signed CDN links like
/// `…/x.mp4?sign=…&t=…` must stay whole or the player gets a dead truncated
/// URL). The bare alternative's negative lookbehind `(?<!\]\()` prevents it
/// from matching the URL inside `![](url)` or `[text](url)`, so only
/// genuinely bare media URLs are extracted as media.
const _mdImagePattern = r'!\[([^\]]*)\]\(([^)\s]+)\)';
const _bareMediaPattern =
    r'(?<!\]\()(https?://[^\s)]+\.(?:jpg|jpeg|png|gif|webp|bmp|mp4|webm|mov|m4v|mkv|mp3|m4a|aac|wav|ogg|oga|opus|flac)(?:[?#][^\s)]*)?)';
final RegExp _mediaTokenRegex = RegExp(
  '$_mdImagePattern|$_bareMediaPattern',
  caseSensitive: false,
);

/// Posts with content longer than this many chars collapse to [_kCollapsedMaxHeight]
/// until expanded.
const int _kCollapseThreshold = 400;
const double _kCollapsedMaxHeight = 220;

/// While a long post is COLLAPSED, only the first ~this-many chars are run
/// through the parse pipeline (mention linkify, NIP-27 extraction, media
/// tokenization, markdown). The collapsed window (220px) shows far less than
/// this, so nothing visible changes — but per-build cost is bounded. Without
/// the cap a single 100KB+ post (spam waves seed the firehose with them)
/// made EVERY rebuild of its card parse 100KB of markdown and build hundreds
/// of link/media widgets; a feed whose visible cards were such posts froze
/// the UI thread ("开中文过滤卡死" — the language filter concentrated the
/// spam). Expanding (展开) parses the full text — an explicit, one-card-at-a
/// time user action.
const int _kCollapsedParseCap = 2000;

/// Hard ceiling for the EXPANDED parse too: 展开 is a deliberate action, but
/// a 100KB+ post still costs ~1s of markdown parsing + thousands of widgets
/// per tap (and adversarial content can be far larger). 30KB is dozens of
/// screens of text — more than anyone reads in a card — and keeps the
/// expanded build bounded. Content beyond it is replaced by a note.
const int _kExpandedParseCap = 30000;

/// Truncate [text] to at most [cap] code units, cutting at the last
/// whitespace/newline inside the final 200 chars when possible (avoids
/// splitting a word/URL mid-token in the visible part) and never splitting a
/// UTF-16 surrogate pair.
String _truncateAtBoundary(String text, int cap) {
  if (text.length <= cap) return text;
  var end = cap;
  final floor = cap - 200;
  for (var i = cap - 1; i > floor; i--) {
    final ch = text.codeUnitAt(i);
    if (ch == 0x20 || ch == 0x0A || ch == 0x09) {
      end = i;
      break;
    }
  }
  // Never cut between a high and low surrogate.
  if (end > 0) {
    final u = text.codeUnitAt(end - 1);
    if (u >= 0xD800 && u <= 0xDBFF) end--;
  }
  return text.substring(0, end);
}

/// Replace each match of [re] in [text] with [replace(m)], SKIPPING matches
/// that fall inside a `https?://…` URL (see [entityMatchInUrl]). Entity
/// matches inside URLs (e.g. npub-subdomain blossom media hosts) must stay
/// untouched or the URL — and the media it points to — breaks.
String _replaceOutsideUrls(
  String text,
  RegExp re,
  String Function(Match) replace,
) {
  final buf = StringBuffer();
  var lastEnd = 0;
  for (final m in re.allMatches(text)) {
    if (entityMatchInUrl(text, m)) continue;
    buf.write(text.substring(lastEnd, m.start));
    buf.write(replace(m));
    lastEnd = m.end;
  }
  buf.write(text.substring(lastEnd));
  return buf.toString();
}

class MarkdownContent extends ConsumerStatefulWidget {
  const MarkdownContent({
    super.key,
    required this.event,
    this.initiallyExpanded = false,
    this.proxyMedia = false,
  });

  final Event event;
  final bool initiallyExpanded;

  /// When true, all images in this post load through the proxy mirror
  /// ([proxiedUrl]) — flipped on by the post's "代理媒体" toggle. Manual
  /// only: the proxy is opt-in per post so the mirror isn't overwhelmed.
  final bool proxyMedia;

  @override
  ConsumerState<MarkdownContent> createState() => _MarkdownContentState();
}

class _MarkdownContentState extends ConsumerState<MarkdownContent> {
  late bool _expanded = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final event = widget.event;
    // Bounded parse source (see [_kCollapsedParseCap] / [_kExpandedParseCap]):
    // collapsed long posts parse a short prefix; expanded posts parse up to
    // the hard cap with a note when content is clipped.
    final isLong = event.content.length > _kCollapseThreshold;
    final expandedNow = _expanded || !isLong;
    final String source;
    final bool hardTruncated;
    if (!expandedNow) {
      source = _truncateAtBoundary(event.content, _kCollapsedParseCap);
      hardTruncated = false;
    } else if (event.content.length > _kExpandedParseCap) {
      source = _truncateAtBoundary(event.content, _kExpandedParseCap);
      hardTruncated = true;
    } else {
      source = event.content;
      hardTruncated = false;
    }
    // 1. Linkify npub/nprofile mentions — but never ones INSIDE a URL (npub-
    // subdomain blossom media hosts like `https://npub1….blossom.band/x.mp4`;
    // rewriting those broke the URL and its media).
    final pubkeysByEntity = <String, String?>{};
    for (final m in _pubkeyEntityRegex.allMatches(source)) {
      if (entityMatchInUrl(source, m)) continue;
      // group(1) = full bare entity (no nostr: prefix).
      final entity = m.group(1)!;
      pubkeysByEntity.putIfAbsent(entity, () => entityToPubkeyHex(entity));
    }
    final nameByPubkey = <String, String>{};
    for (final pk in pubkeysByEntity.values) {
      if (pk == null) continue;
      final meta = ref.watch(metadataProvider(pk)).value;
      final name = meta?.bestName;
      if (name != null && name.isNotEmpty) nameByPubkey[pk] = name;
    }
    final linkified = _replaceOutsideUrls(source, _pubkeyEntityRegex, (
      Match m,
    ) {
      final entity = m.group(1)!;
      final pk = pubkeysByEntity[entity];
      final label =
          (pk != null ? nameByPubkey[pk] : null) ?? shortenEntity(entity);
      return '[@$label](nostr:$entity)';
    });

    // 1b. NIP-27 event references (`nostr:nevent1…` / `nostr:note1…`, plus `e`
    // mention tags): collect referenced ids, then strip the raw entity text
    // from the content (rendered as embedded quote cards below instead).
    final referencedIds = <String>[];
    final seenRef = <String>{};
    // NIP-19 relay hints per referenced id — where the quoted note actually
    // lives; [quotedEventProvider] falls back to them when the default-pool
    // broadcast misses (quotes often live only on the author's own relays).
    final relayHintsById = <String, List<String>>{};
    for (final m in _eventEntityRegex.allMatches(linkified)) {
      // Same URL guard as pubkey mentions: an nevent/note entity inside a URL
      // (e.g. a shared link) must not be stripped out of it.
      if (entityMatchInUrl(linkified, m)) continue;
      final entity = m.group(1)!;
      final id = entityToEventIdHex(entity) ?? '';
      if (id.isEmpty || !seenRef.add(id)) continue;
      referencedIds.add(id);
      final relays = neventDecode(entity)?.relays;
      if (relays != null && relays.isNotEmpty) relayHintsById[id] = relays;
    }
    for (final t in event.tags) {
      if (t.length >= 4 &&
          t[0] == 'e' &&
          t[3] == 'mention' &&
          seenRef.add(t[1].toString())) {
        referencedIds.add(t[1].toString());
      }
    }
    final stripped = referencedIds.isEmpty
        ? linkified
        : _replaceOutsideUrls(linkified, _eventEntityRegex, (Match m) => '');

    // 1b'. NIP-19 address references (`nostr:naddr1…` — parameterized
    // replaceable coordinates, typically long-form articles): collect the
    // decoded coordinates, then strip the raw entities from the content
    // (rendered as embedded cards below, same pattern as NIP-27 quotes).
    final addrRefs = <Naddr>[];
    final seenAddr = <String>{};
    for (final m in _addrEntityRegex.allMatches(stripped)) {
      // Same URL guard as the other entities: an naddr inside a URL must
      // not be stripped out of it.
      if (entityMatchInUrl(stripped, m)) continue;
      final addr = naddrDecode(m.group(1)!);
      if (addr == null) continue;
      final coord = '${addr.kind}\x1f${addr.pubkey}\x1f${addr.d}';
      if (!seenAddr.add(coord)) continue;
      addrRefs.add(addr);
    }
    final strippedAll = addrRefs.isEmpty
        ? stripped
        : _replaceOutsideUrls(stripped, _addrEntityRegex, (Match m) => '');

    // 1c. Probe candidates: bare http(s) URLs that are NOT already handled —
    // not media/file-extension URLs (tokenized/stripped above), not markdown
    // link targets, not tag-declared attachments. Each resolves async via
    // [linkPreviewProvider] (session-cached, capped at 4 per note):
    // - image/video (e.g. 小红书 `?imageView2/…/format/jpg` links whose
    //   format lives only in the query) → injected into [tokenizeContent] as
    //   tag-declared media, so it renders in place exactly like the 抖音
    //   extensionless-video mechanism;
    // - webpage → an Open Graph preview card appended below;
    // - loading/none → the URL stays plain clickable text (today's look).
    final previewTagged = <MediaAttachment>[];
    final previewCards = <(String, LinkPreview)>[];
    for (final cand in extractPreviewCandidates(
      strippedAll,
      exclude: {for (final m in event.mediaAttachments) m.url},
    )) {
      switch (ref.watch(linkPreviewProvider(cand)).value) {
        case UrlImage(:final url):
          previewTagged.add(MediaAttachment(url: url, mimeType: 'image/jpeg'));
        case UrlVideo(:final url):
          previewTagged.add(MediaAttachment(url: url, mimeType: 'video/mp4'));
        case UrlAudio(:final url):
          previewTagged.add(MediaAttachment(url: url, mimeType: 'audio/mpeg'));
        case UrlWebpage(:final preview):
          previewCards.add((cand, preview));
        case UrlNone() || null:
          break;
      }
    }

    // 2. Tokenize into segments: text / image-group (contiguous) / single video.
    // Tag-declared media (imeta / ["video",url,mime]) is passed along so bare
    // URLs without a media file extension (抖音 share links) still render as
    // players instead of plain links — same mechanism carries probe-resolved
    // media (previewTagged).
    final segments = tokenizeContent(
      strippedAll,
      tagged: [...event.mediaAttachments, ...previewTagged],
    );

    final children = <Widget>[];

    // NIP-30 custom emoji: collect `["emoji", shortcode, url]` tags and
    // replace `:shortcode:` occurrences in text with inline markdown images.
    // Done after tokenization so the 九宫格 image-grouper doesn't pull emoji
    // into a grid — they stay inline within their text segment.
    final emojiMap = <String, String>{};
    for (final t in event.tags) {
      if (t.length >= 3 &&
          t[0] == 'emoji' &&
          t[1] is String &&
          t[2] is String) {
        emojiMap[t[1] as String] = t[2] as String;
      }
    }
    final emojiUrlSet = emojiMap.values.toSet();
    String replaceEmoji(String text) {
      if (emojiMap.isEmpty) return text;
      return text.replaceAllMapped(RegExp(r':([a-zA-Z0-9_+-]+):'), (Match m) {
        final url = emojiMap[m[1]];
        return url == null ? m[0]! : '![${m[1]}]($url)';
      });
    }

    Widget sizedImageBuilder(MarkdownImageConfig c) {
      // Inline custom-emoji image: render small so it sits inline with text.
      final isEmoji =
          (c.alt != null && emojiMap.containsKey(c.alt!)) ||
          emojiUrlSet.contains(c.uri.toString());
      if (isEmoji) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(4),
          // forceProxy follows the post's manual "代理媒体" toggle; on a
          // definitive miss fall back to :shortcode:.
          child: CostrNetworkImage(
            url: c.uri.toString(),
            forceProxy: widget.proxyMedia,
            width: 22,
            height: 22,
            fit: BoxFit.cover,
            errorWidget: (BuildContext _) => Text(':${c.alt ?? ''}:'),
          ),
        );
      }
      // Other images are rendered via the 九宫格 / imeta pipeline; shrink
      // here to avoid duplicating them inline.
      return const SizedBox.shrink();
    }

    for (final seg in segments) {
      if (seg is TextSeg) {
        // Strip bare media URLs from text (they're rendered via imeta extra).
        final cleaned = replaceEmoji(
          preserveBlankLines(stripBareMediaUrls(seg.text)),
        ).trim();
        if (cleaned.isEmpty) continue;
        children.add(
          MarkdownBody(
            data: cleaned,
            softLineBreak: true,
            extensionSet: ExtensionSet.gitHubFlavored,
            sizedImageBuilder: sizedImageBuilder,
            onTapLink: (String text, String? href, String? title) {
              if (href == null) return;
              if (href.startsWith('nostr:')) {
                final entity = href.substring('nostr:'.length);
                final pk = entityToPubkeyHex(entity);
                if (pk != null) context.push('/u/$pk');
              } else if (href.startsWith('http')) {
                launchUrl(
                  Uri.parse(href),
                  mode: LaunchMode.externalApplication,
                );
              }
            },
            styleSheet: costrMarkdownStyleSheet(context),
          ),
        );
      } else if (seg is ImageGroupSeg) {
        children.add(_ImageGrid(urls: seg.urls, proxyMedia: widget.proxyMedia));
      } else if (seg is SingleVideoSeg) {
        children.add(NetworkVideo(url: seg.url, forceProxy: widget.proxyMedia));
      } else if (seg is AudioSeg) {
        children.add(_audioWidget(seg.url));
      }
    }

    // 3. Append NIP-92 imeta / `["image",...]` media whose URL is NOT already
    // rendered from the content. [tokenizeContent] now extracts both markdown
    // `![](url)` and bare image/video/audio URLs into segments, so any media
    // URL that appears in the content has already been rendered — skip it to
    // avoid duplication. Media whose URL is absent from the content (pure
    // imeta attachments) still renders here.
    final extra = event.mediaAttachments
        .where((m) => !event.content.contains(m.url))
        .toList();
    final extraImages = extra
        .where((m) => m.isImage)
        .map((m) => m.url)
        .toList();
    final extraVideos = extra.where((m) => m.isVideo).toList();
    final extraAudios = extra.where((m) => m.isAudio).toList();
    if (extraImages.isNotEmpty) {
      children.add(const SizedBox(height: 8));
      children.add(
        _ImageGrid(urls: extraImages, proxyMedia: widget.proxyMedia),
      );
    }
    for (final v in extraVideos) {
      children.add(const SizedBox(height: 8));
      children.add(
        NetworkVideo(
          url: v.url,
          width: v.width,
          height: v.height,
          forceProxy: widget.proxyMedia,
        ),
      );
    }
    for (final a in extraAudios) {
      children.add(const SizedBox(height: 8));
      children.add(_audioWidget(a.url, attachment: a));
    }
    final extraFiles = extra
        .where((m) => !m.isImage && !m.isVideo && !m.isAudio)
        .toList();
    if (extraFiles.isNotEmpty) {
      children.add(const SizedBox(height: 8));
      children.add(
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            for (final f in extraFiles)
              _FileChip(url: f.url, name: _fileName(f.url)),
          ],
        ),
      );
    }

    // 3b. Open Graph preview cards for bare web URLs that resolved as
    // webpages (the URL text itself stays clickable above; the card is an
    // affordance with title/image, X-style).
    for (final (url, preview) in previewCards) {
      children.add(
        _LinkPreviewCard(
          url: url,
          preview: preview,
          proxyMedia: widget.proxyMedia,
        ),
      );
    }

    // 4. Append embedded quote cards for referenced events (NIP-27).
    for (final id in referencedIds) {
      children.add(
        _EventEmbed(id: id, relayHints: relayHintsById[id] ?? const []),
      );
    }

    // 4b. Append embedded cards for NIP-19 address references (`naddr1…` —
    // parameterized replaceable events, typically long-form articles).
    for (final a in addrRefs) {
      children.add(_AddrEmbed(addr: a));
    }

    if (hardTruncated) {
      children.add(
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            '内容过长，超出部分已省略',
            style: TextStyle(
              fontSize: 12,
              fontStyle: FontStyle.italic,
              color: CostrColors.of(context).text3,
            ),
          ),
        ),
      );
    }

    return _CollapseBox(
      expanded: expandedNow,
      canCollapse: isLong,
      onToggle: () => setState(() => _expanded = !_expanded),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }

  /// Inline audio player for [url]; on platforms without an audio backend
  /// (Windows/Linux — video is equally unsupported there) degrades to the
  /// download chip instead. [attachment] supplies the real waveform when
  /// already at hand (imeta extra path); otherwise the event's attachments
  /// are consulted so tag-declared audio URLs in the content also get their
  /// `waveform` field.
  Widget _audioWidget(String url, {MediaAttachment? attachment}) {
    if (defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux) {
      return _FileChip(url: url, name: _fileName(url));
    }
    final a = attachment ?? _attachmentFor(url);
    return NetworkAudio(
      url: url,
      waveform: a?.waveform,
      forceProxy: widget.proxyMedia,
    );
  }

  MediaAttachment? _attachmentFor(String url) {
    for (final m in widget.event.mediaAttachments) {
      if (m.url == url) return m;
    }
    return null;
  }
}

/// Bounded-height wrapper with a 展开/收起 toggle for long posts.
class _CollapseBox extends StatelessWidget {
  const _CollapseBox({
    required this.expanded,
    required this.canCollapse,
    required this.onToggle,
    required this.child,
  });
  final bool expanded;
  final bool canCollapse;
  final VoidCallback onToggle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!canCollapse) return child;
    if (expanded) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          child,
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(onPressed: onToggle, child: const Text('收起')),
          ),
        ],
      );
    }
    final surface = Theme.of(context).colorScheme.surface;
    return Stack(
      children: [
        // Fixed-height window showing the TOP of the child, clipped.
        //
        // Deliberately NOT a SingleChildScrollView: with the default
        // `primary: true` (controller is null), a nested ScrollView inside
        // the feed's PrimaryScrollController scope inherits the FEED's
        // scroll position — so when the feed is scrolled down, the
        // collapsed post showed its content scrolled to the BOTTOM (the
        // latter half) instead of the beginning. OverflowBox renders the
        // child at its natural (taller) height, top-aligned, clipped to the
        // window — no ScrollController entanglement, the beginning always
        // shows.
        SizedBox(
          height: _kCollapsedMaxHeight,
          child: ClipRect(
            child: OverflowBox(
              alignment: Alignment.topCenter,
              maxHeight: double.infinity,
              child: child,
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: Container(
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.only(top: 18),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [surface.withValues(alpha: 0), surface],
              ),
            ),
            child: TextButton(onPressed: onToggle, child: const Text('展开')),
          ),
        ),
      ],
    );
  }
}

// --- segmentation ----------------------------------------------------------

String _fileName(String url) {
  final path = Uri.tryParse(url)?.path ?? url;
  final slash = path.lastIndexOf('/');
  final name = slash >= 0 ? path.substring(slash + 1) : path;
  return name.isEmpty ? url : name;
}

class _FileChip extends StatelessWidget {
  const _FileChip({required this.url, required this.name});
  final String url;
  final String name;

  Future<void> _save(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      const SnackBar(content: Text('下载中…'), duration: Duration(seconds: 4)),
    );
    final msg = await MediaDownload.save(
      url: url,
      kind: MediaKind.file,
      filename: name,
    );
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
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 240),
      child: Material(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _save(context),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.insert_drive_file_outlined,
                  size: 18,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    name,
                    style: theme.textTheme.labelSmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 6),
                Icon(
                  Icons.download_rounded,
                  size: 16,
                  color: theme.colorScheme.primary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Tokenize content into text / contiguous image-group / single-video /
/// single-audio segments, so consecutive images render as a 九宫格 grid and
/// text-broken runs form separate groups. Public for unit testing.
/// True if [event] carries ANY renderable image, video or audio — markdown
/// `![](url)`, a bare image/video/audio URL in the content, or a NIP-92
/// imeta `["image",url]` / `["video",url]` / `["audio",url]` tag. Used by
/// the post's name bar to decide whether to surface the per-post "代理媒体"
/// toggle (the toggle is only meaningful when there's media to proxy;
/// text-only posts hide it).
bool postHasMedia(Event event) {
  // imeta image/video/audio attachments.
  if (event.mediaAttachments.any(
    (m) => m.isImage || m.isVideo || m.isAudio,
  )) {
    return true;
  }
  // Markdown images / bare image-video-audio URLs in the content body.
  // Bounded to a prefix: this runs on every visible-card build (name-bar
  // proxy toggle), and adversariously long posts (100KB+ spam) must not be
  // tokenized in full here — media within the first few KB is plenty for
  // the toggle decision, and the card itself parses the same bounded prefix
  // while collapsed (see [_kCollapsedParseCap]).
  final body = event.content.length > 4000
      ? event.content.substring(0, 4000)
      : event.content;
  final segs = tokenizeContent(body);
  for (final s in segs) {
    if (s is ImageGroupSeg || s is SingleVideoSeg || s is AudioSeg) {
      return true;
    }
  }
  return false;
}

List<ContentSeg> tokenizeContent(
  String content, {
  List<MediaAttachment> tagged = const [],
}) {
  final out = <ContentSeg>[];
  final group = <String>[];
  int lastEnd = 0;
  // Tag-declared media (imeta / `["video",url,mime]` / `["image",url,mime]`
  // / `["audio",url,mime]`) whose bare URL lacks a media file extension —
  // e.g. a 抖音 share link like `…/playwm/?video_id=…`. The base regex would
  // miss it and it would render as a plain link instead of a player
  // ("视频链接不渲染播放控件" bug). The tag's MIME wins over the extension
  // guess; listed BEFORE the bare-ext alternative so the exact full URL wins
  // over an extension-terminated prefix of it.
  final taggedByUrl = <String, MediaAttachment>{
    for (final m in tagged)
      if (m.isImage || m.isVideo || m.isAudio) m.url: m,
  };
  final regex = taggedByUrl.isEmpty
      ? _mediaTokenRegex
      : RegExp(
          '$_mdImagePattern|(?<!\\]\\()(?:${taggedByUrl.keys.map(RegExp.escape).join('|')})|$_bareMediaPattern',
          caseSensitive: false,
        );

  void flushGroup() {
    if (group.isNotEmpty) {
      out.add(ImageGroupSeg(List<String>.of(group)));
      group.clear();
    }
  }

  for (final m in regex.allMatches(content)) {
    final between = content.substring(lastEnd, m.start);
    // group(2) = markdown image url; group(3) = bare media url; a
    // tag-declared literal match carries neither → group(0) is the url.
    final url = (m.group(2) ?? m.group(3) ?? m.group(0)!).toString();
    if (url.isEmpty) continue;
    final attachment = taggedByUrl[url] ?? MediaAttachment(url: url);
    if (between.trim().isNotEmpty) {
      flushGroup();
      out.add(TextSeg(between));
    }
    if (attachment.isVideo) {
      flushGroup();
      out.add(SingleVideoSeg(url));
    } else if (attachment.isAudio) {
      flushGroup();
      out.add(AudioSeg(url));
    } else {
      group.add(url);
    }
    lastEnd = m.end;
  }

  final tail = content.substring(lastEnd);
  if (tail.trim().isNotEmpty) {
    flushGroup();
    out.add(TextSeg(tail));
  } else {
    flushGroup();
  }
  return out;
}

abstract class ContentSeg {}

class TextSeg extends ContentSeg {
  TextSeg(this.text);
  final String text;
}

class ImageGroupSeg extends ContentSeg {
  ImageGroupSeg(this.urls);
  final List<String> urls;
}

class SingleVideoSeg extends ContentSeg {
  SingleVideoSeg(this.url);
  final String url;
}

/// A single audio URL (bare audio-extension URL or tag-declared `audio/*`
/// media). Rendered as an inline player by [NetworkAudio].
class AudioSeg extends ContentSeg {
  AudioSeg(this.url);
  final String url;
}

// --- image grid + single image --------------------------------------------

class _ImageGrid extends StatelessWidget {
  const _ImageGrid({required this.urls, required this.proxyMedia});
  final List<String> urls;
  final bool proxyMedia;

  @override
  Widget build(BuildContext context) {
    if (urls.length == 1) {
      return _SingleImage(url: urls.first, proxyMedia: proxyMedia);
    }
    return GridView.count(
      crossAxisCount: 3,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 4,
      crossAxisSpacing: 4,
      childAspectRatio: 1,
      children: [
        for (var i = 0; i < urls.length; i++)
          _GridThumb(
            url: urls[i],
            urls: urls,
            index: i,
            proxyMedia: proxyMedia,
          ),
      ],
    );
  }
}

class _GridThumb extends StatelessWidget {
  const _GridThumb({
    required this.url,
    required this.urls,
    required this.index,
    required this.proxyMedia,
  });
  final String url;
  final List<String> urls;
  final int index;
  final bool proxyMedia;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => pushMediaViewer(
        context,
        images: urls,
        initialIndex: index,
        initialForceProxy: proxyMedia,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: CostrNetworkImage(
          url: url,
          forceProxy: proxyMedia,
          fit: BoxFit.cover,
          placeholder: (BuildContext _) => const _Placeholder(),
          errorWidget: (BuildContext _) => const _ErrorBox(),
        ),
      ),
    );
  }
}

class _SingleImage extends StatelessWidget {
  const _SingleImage({required this.url, required this.proxyMedia});
  final String url;
  final bool proxyMedia;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => pushMediaViewer(
        context,
        images: [url],
        initialForceProxy: proxyMedia,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: CostrNetworkImage(
          url: url,
          forceProxy: proxyMedia,
          width: double.infinity,
          fit: BoxFit.contain,
          placeholder: (BuildContext _) => const _Placeholder(aspect: 16 / 9),
          errorWidget: (BuildContext _) => const _ErrorBox(aspect: 16 / 9),
        ),
      ),
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({this.aspect = 1});
  final double aspect;
  @override
  Widget build(BuildContext context) => AspectRatio(
    aspectRatio: aspect,
    child: Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      alignment: Alignment.center,
      child: const SizedBox(
        width: 22,
        height: 22,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
    ),
  );
}

class _ErrorBox extends StatelessWidget {
  const _ErrorBox({this.aspect = 1});
  final double aspect;
  @override
  Widget build(BuildContext context) => AspectRatio(
    aspectRatio: aspect,
    child: Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      alignment: Alignment.center,
      child: const Icon(Icons.broken_image_outlined),
    ),
  );
}

/// An embedded quote card for a referenced event (NIP-27 `nostr:nevent1…` /
/// `nostr:note1…` in content, or an `e` mention tag). Fetches the event via
/// [quotedEventProvider] (SQLite → in-memory → relay REQ → the nevent's own
/// relay hints) and renders the author + a content snippet; tap opens
/// `/n/:id`. When the lookup settles empty the card shows "引用内容不可用"
/// and a tap retries (the old code spun on "加载引用…" forever whenever the
/// future settled without AsyncData — e.g. an error state).
class _EventEmbed extends ConsumerWidget {
  const _EventEmbed({required this.id, this.relayHints = const []});
  final String id;
  final List<String> relayHints;

  /// Family key: id + hints (baked in so the widget stays a ConsumerWidget).
  String get _key => <String>[id, ...relayHints].join('\x1f');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final mute = ref.watch(myMuteSetProvider);
    final async = ref.watch(quotedEventProvider(_key));
    final ev = async.value;
    if (ev == null) {
      final notFound = !async.isLoading;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: notFound
            ? () => ref.invalidate(quotedEventProvider(_key))
            : null,
        child: Container(
          margin: const EdgeInsets.only(top: 8),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: CostrColors.of(context).bg2,
            border: Border(
              left: BorderSide(color: theme.colorScheme.outline, width: 3),
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            notFound ? '引用内容不可用 · 点击重试' : '加载引用…',
            style: theme.textTheme.bodySmall?.copyWith(
              color: CostrColors.of(context).text3,
            ),
          ),
        ),
      );
    }
    final meta = ref.watch(metadataProvider(ev.pubkey)).value;
    // Muted quoted note: name + content stay hidden; only the hint shows
    // until the user explicitly taps the card open (same rule as the
    // reply-context preview in EventCard).
    if (mute.hidesEvent(ev)) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => pushPostDetail(context, ev.id),
        child: Container(
          margin: const EdgeInsets.only(top: 8),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: CostrColors.of(context).bg2,
            border: Border(
              left: BorderSide(color: theme.colorScheme.outline, width: 3),
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            mute.hintFor(ev),
            style: theme.textTheme.bodySmall?.copyWith(
              color: CostrColors.of(context).text3,
            ),
          ),
        ),
      );
    }
    // Non-post events (reactions, contact lists, …) referenced via nevent must
    // NOT be rendered as a quote post card. Show a compact inline label
    // instead (Amethyst pattern). Only post-like kinds (1/6/16/30023) get the
    // full author + snippet card below.
    if (!ev.isPostLike) {
      return _NonPostRefLabel(ev: ev);
    }
    return GestureDetector(
      onTap: () => pushPostDetail(context, ev.id),
      child: Container(
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: CostrColors.of(context).bg2,
          border: Border(
            left: BorderSide(color: theme.colorScheme.outline, width: 3),
          ),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Avatar(pubkey: ev.pubkey, radius: 12),
                const SizedBox(width: 6),
                Flexible(
                  child: DisplayName(
                    pubkey: ev.pubkey,
                    meta: meta,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text.rich(
              linkifyMentions(
                ev.content,
                ref,
                baseStyle: theme.textTheme.bodySmall?.copyWith(
                  color: CostrColors.of(context).text2,
                  height: 1.4,
                ),
                mentionStyle: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

/// Shared quote-embed box (left border + bg2, Amethyst style).
Widget _embedBox(BuildContext context, {required Widget child}) {
  final theme = Theme.of(context);
  return Container(
    margin: const EdgeInsets.only(top: 8),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: CostrColors.of(context).bg2,
      border: Border(left: BorderSide(color: theme.colorScheme.outline, width: 3)),
      borderRadius: BorderRadius.circular(12),
    ),
    child: child,
  );
}

/// First non-empty string value of tag [name] on [e] (e.g. a long-form
/// article's `title`).
String? _stringTag(Event e, String name) {
  for (final t in e.tags) {
    if (t.length >= 2 && t[0] == name && t[1] is String) {
      final v = (t[1] as String).trim();
      if (v.isNotEmpty) return v;
    }
  }
  return null;
}

/// An embedded card for a NIP-19 address reference (`nostr:naddr1…` — a
/// parameterized replaceable coordinate; in notes this is typically a
/// long-form article). Resolves via [addressedEventProvider] (store → global
/// window → broadcast kinds+authors+#d → the naddr's own relay hints) and
/// renders author + title (when the event carries one) + content snippet;
/// tap opens the post detail. When the lookup settles empty the card shows
/// "引用内容不可用" and a tap retries — same contract as [_EventEmbed].
class _AddrEmbed extends ConsumerWidget {
  const _AddrEmbed({required this.addr});
  final Naddr addr;

  /// Family key: kind + author + d + relay hints (baked in so the widget
  /// stays a ConsumerWidget).
  String get _key => <String>[
    '${addr.kind}',
    addr.pubkey,
    addr.d,
    ...addr.relays,
  ].join('\x1f');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final mute = ref.watch(myMuteSetProvider);
    final async = ref.watch(addressedEventProvider(_key));
    final ev = async.value;
    if (ev == null) {
      final notFound = !async.isLoading;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: notFound
            ? () => ref.invalidate(addressedEventProvider(_key))
            : null,
        child: _embedBox(
          context,
          child: Text(
            notFound ? '引用内容不可用 · 点击重试' : '加载引用…',
            style: theme.textTheme.bodySmall?.copyWith(
              color: CostrColors.of(context).text3,
            ),
          ),
        ),
      );
    }
    // Muted referenced note: name + content stay hidden; only the hint shows
    // until the user explicitly taps the card open (same rule as
    // [_EventEmbed]).
    if (mute.hidesEvent(ev)) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => pushPostDetail(context, ev.id),
        child: _embedBox(
          context,
          child: Text(
            mute.hintFor(ev),
            style: theme.textTheme.bodySmall?.copyWith(
              color: CostrColors.of(context).text3,
            ),
          ),
        ),
      );
    }
    // Non-post events referenced via naddr (relay lists, app data, …) must
    // NOT render as a post card — compact inline label, same rule as NIP-27.
    if (!ev.isPostLike) {
      return _NonPostRefLabel(ev: ev);
    }
    final meta = ref.watch(metadataProvider(ev.pubkey)).value;
    final title = _stringTag(ev, 'title');
    return GestureDetector(
      onTap: () => pushPostDetail(context, ev.id),
      child: _embedBox(
        context,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Avatar(pubkey: ev.pubkey, radius: 12),
                const SizedBox(width: 6),
                Flexible(
                  child: DisplayName(
                    pubkey: ev.pubkey,
                    meta: meta,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            if (title != null) ...[
              Text(
                title,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  height: 1.3,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
            ],
            Text.rich(
              linkifyMentions(
                ev.content,
                ref,
                baseStyle: theme.textTheme.bodySmall?.copyWith(
                  color: CostrColors.of(context).text2,
                  height: 1.4,
                ),
                mentionStyle: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              maxLines: title != null ? 2 : 4,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

/// Compact inline label shown when a post references a non-post event via
/// `nostr:nevent1…` (e.g. a kind-7 reaction or kind-3 contact list). Instead
/// of rendering it as a full quote post card, show a small chip describing
/// what was referenced — Amethyst does the same (reactions never become
/// posts).
class _NonPostRefLabel extends StatelessWidget {
  const _NonPostRefLabel({required this.ev});
  final Event ev;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (label, icon) = switch (ev.kind) {
      7 => (
        '引用了一个赞',
        ev.content.isNotEmpty && ev.content.length <= 8 ? ev.content : '👍',
      ),
      3 => ('引用了联系人列表', '👥'),
      _ => ('引用了类型 ${ev.kind} 的事件', '📎'),
    };
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: CostrColors.of(context).bg2,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: theme.colorScheme.outline, width: 0.5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(icon, style: const TextStyle(fontSize: 13)),
          const SizedBox(width: 5),
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: CostrColors.of(context).text3,
            ),
          ),
        ],
      ),
    );
  }
}

/// Open Graph preview card for a bare web URL in the note (X-style): optional
/// og:image on top, then title / description / domain. Whole card taps out to
/// the browser, same as the URL text itself. Degrades: dead og:image hides
/// the image area entirely; anti-bot walls (title+description dropped by the
/// parser) render a domain-only card. DESIGN §15: radius 16, 1px border.
class _LinkPreviewCard extends StatelessWidget {
  const _LinkPreviewCard({
    required this.url,
    required this.preview,
    required this.proxyMedia,
  });

  final String url;
  final LinkPreview preview;
  final bool proxyMedia;

  @override
  Widget build(BuildContext context) {
    final colors = CostrColors.of(context);
    final title = preview.title;
    final description = preview.description;
    final imageUrl = preview.imageUrl;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () =>
          launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
      child: Container(
        margin: const EdgeInsets.only(top: 8),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: colors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (imageUrl != null)
              _PreviewImage(url: imageUrl, forceProxy: proxyMedia),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (title != null)
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: colors.text,
                        height: 1.3,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  if (description != null) ...[
                    if (title != null) const SizedBox(height: 4),
                    Text(
                      description,
                      style: TextStyle(
                        fontSize: 13,
                        color: colors.text2,
                        height: 1.3,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  SizedBox(height: (title ?? description) != null ? 4 : 0),
                  Text(
                    preview.domain,
                    style: TextStyle(fontSize: 13, color: colors.text3),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// og:image area of a preview card: 16:9, cover; on load failure collapses
/// to nothing (a dead og:image must degrade to the text-only card, never a
/// broken-image box — 不因图崩).
class _PreviewImage extends StatefulWidget {
  const _PreviewImage({required this.url, required this.forceProxy});

  final String url;
  final bool forceProxy;

  @override
  State<_PreviewImage> createState() => _PreviewImageState();
}

class _PreviewImageState extends State<_PreviewImage> {
  bool _failed = false;

  @override
  Widget build(BuildContext context) {
    if (_failed) return const SizedBox.shrink();
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: CostrNetworkImage(
        url: widget.url,
        forceProxy: widget.forceProxy,
        fit: BoxFit.cover,
        memCacheHeight: 600,
        placeholder: (BuildContext c) =>
            Container(color: Theme.of(c).colorScheme.surfaceContainerHighest),
        errorWidget: (BuildContext _) {
          // Flip AFTER the frame — errorWidget builds during the parent's
          // build, where setState is illegal.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && !_failed) setState(() => _failed = true);
          });
          return const SizedBox.shrink();
        },
      ),
    );
  }
}
