/// Renders post content as markdown (GitHub-flavored) with:
/// - NIP-19 `npub1`/`nprofile1` mentions linkified (tappable -> /u/:pubkey),
///   labeled with the resolved kind-0 name (else shortened entity).
/// - Contiguous markdown images grouped into a 3-column square thumbnail grid
///   (九宫格 style); images separated by text form separate groups. A single
///   image renders full-width (not gridded).
/// - Videos (`![](video.mp4)` or imeta `m video/*`) render full-width via
///   video_player.
/// - NIP-92 imeta media not already in the content is appended below; its
///   images are gridded together, videos full-width.
library;

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
import '../services/media_download.dart';
import 'avatar.dart';
import 'media_viewer_page.dart';
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

/// Preserve blank lines in text fed to [MarkdownBody]. Markdown collapses
/// runs of blank lines into a single paragraph break; Amethyst renders every
/// blank line. Replace each empty line with a zero-width space (non-whitespace
/// → not a blank line → no paragraph split). Pair with `softLineBreak: true`
/// on MarkdownBody so single `\n` also render as line breaks.
String _preserveBlankLines(String s) =>
    s.split('\n').map((l) => l.trim().isEmpty ? '​' : l).join('\n');

/// Bare media URLs in content (image/video/file extensions) — stripped from
/// text segments so they don't show as plain text; rendered via imeta extra
/// or, for image/video, by [tokenizeContent] below. Negative lookbehind on
/// `](` keeps it from matching the URL inside a markdown link/image
/// `](url)`, so `[text](x.jpg)` links aren't broken.
final RegExp _bareMediaUrl = RegExp(
  r'(?<!\]\()https?://[^\s)]+\.(?:jpg|jpeg|png|gif|webp|bmp|mp4|webm|mov|m4v|mkv|pdf|zip|txt|md|mp3|wav|ogg)',
);

/// Combined media token: a markdown image `![alt](url)` OR a bare image/video
/// URL. Group 1+2 = markdown image alt + url; group 3 = bare url. The bare
/// alternative's negative lookbehind `(?<!\]\()` prevents it from matching the
/// URL inside `![](url)` or `[text](url)`, so only genuinely bare media URLs
/// are extracted as images.
final RegExp _mediaTokenRegex = RegExp(
  r'!\[([^\]]*)\]\(([^)\s]+)\)|(?<!\]\()(https?://[^\s)]+\.(?:jpg|jpeg|png|gif|webp|bmp|mp4|webm|mov|m4v|mkv))',
  caseSensitive: false,
);

/// Posts with content longer than this many chars collapse to [_kCollapsedMaxHeight]
/// until expanded.
const int _kCollapseThreshold = 400;
const double _kCollapsedMaxHeight = 220;

class MarkdownContent extends ConsumerStatefulWidget {
  const MarkdownContent({
    super.key,
    required this.event,
    this.initiallyExpanded = false,
    this.proxyMedia = false,
    this.onMediaFailed,
  });

  final Event event;
  final bool initiallyExpanded;

  /// When true, all images in this post load through the proxy mirror
  /// ([proxiedUrl]) — flipped on by the post's "代理媒体" affordance. Manual
  /// only: the proxy is opt-in per post so the mirror isn't overwhelmed.
  final bool proxyMedia;

  /// Fired (true) when an image fails to load, so the post can surface its
  /// "代理媒体" affordance. One fire per failure.
  final ValueChanged<bool>? onMediaFailed;

  @override
  ConsumerState<MarkdownContent> createState() => _MarkdownContentState();
}

class _MarkdownContentState extends ConsumerState<MarkdownContent> {
  late bool _expanded = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final event = widget.event;
    // 1. Linkify npub/nprofile mentions.
    final pubkeysByEntity = <String, String?>{};
    for (final m in _pubkeyEntityRegex.allMatches(event.content)) {
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
    final linkified = event.content.replaceAllMapped(_pubkeyEntityRegex, (
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
    for (final m in _eventEntityRegex.allMatches(linkified)) {
      final id = entityToEventIdHex(m.group(1)!) ?? '';
      if (id.isNotEmpty && seenRef.add(id)) referencedIds.add(id);
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
        : linkified.replaceAllMapped(_eventEntityRegex, (Match m) => '');

    // 2. Tokenize into segments: text / image-group (contiguous) / single video.
    final segments = tokenizeContent(stripped);

    final theme = Theme.of(context);
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
            onError: widget.onMediaFailed,
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
          _preserveBlankLines(seg.text.replaceAll(_bareMediaUrl, '')),
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
            styleSheet: MarkdownStyleSheet.fromTheme(theme),
          ),
        );
      } else if (seg is ImageGroupSeg) {
        children.add(_ImageGrid(
          urls: seg.urls,
          proxyMedia: widget.proxyMedia,
          onMediaFailed: widget.onMediaFailed,
        ));
      } else if (seg is SingleVideoSeg) {
        children.add(NetworkVideo(
          url: seg.url,
          forceProxy: widget.proxyMedia,
          onError: widget.onMediaFailed,
        ));
      }
    }

    // 3. Append NIP-92 imeta / `["image",...]` media whose URL is NOT already
    // rendered from the content. [tokenizeContent] now extracts both markdown
    // `![](url)` and bare image/video URLs into image groups, so any media URL
    // that appears in the content has already been rendered — skip it to avoid
    // duplication. Media whose URL is absent from the content (pure imeta
    // attachments) still renders here.
    final extra = event.mediaAttachments
        .where((m) => !event.content.contains(m.url))
        .toList();
    final extraImages = extra
        .where((m) => m.isImage)
        .map((m) => m.url)
        .toList();
    final extraVideos = extra.where((m) => m.isVideo).toList();
    if (extraImages.isNotEmpty) {
      children.add(const SizedBox(height: 8));
      children.add(_ImageGrid(
        urls: extraImages,
        proxyMedia: widget.proxyMedia,
        onMediaFailed: widget.onMediaFailed,
      ));
    }
    for (final v in extraVideos) {
      children.add(const SizedBox(height: 8));
      children.add(NetworkVideo(
        url: v.url,
        width: v.width,
        height: v.height,
        forceProxy: widget.proxyMedia,
        onError: widget.onMediaFailed,
      ));
    }
    final extraFiles = extra.where((m) => !m.isImage && !m.isVideo).toList();
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

    // 4. Append embedded quote cards for referenced events (NIP-27).
    for (final id in referencedIds) {
      children.add(_EventEmbed(id: id));
    }

    final isLong = event.content.length > _kCollapseThreshold;
    return _CollapseBox(
      expanded: _expanded || !isLong,
      canCollapse: isLong,
      onToggle: () => setState(() => _expanded = !_expanded),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
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
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: _kCollapsedMaxHeight),
          child: ClipRect(
            child: SingleChildScrollView(
              physics: const NeverScrollableScrollPhysics(),
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

/// Tokenize content into text / contiguous image-group / single-video
/// segments, so consecutive images render as a 九宫格 grid and text-broken
/// runs form separate groups. Public for unit testing.
List<ContentSeg> tokenizeContent(String content) {
  final out = <ContentSeg>[];
  final group = <String>[];
  int lastEnd = 0;

  void flushGroup() {
    if (group.isNotEmpty) {
      out.add(ImageGroupSeg(List<String>.of(group)));
      group.clear();
    }
  }

  for (final m in _mediaTokenRegex.allMatches(content)) {
    final between = content.substring(lastEnd, m.start);
    // group(2) = markdown image url; group(3) = bare media url.
    final url = (m.group(2) ?? m.group(3) ?? '').toString();
    if (url.isEmpty) continue;
    final isVideo = MediaAttachment(url: url).isVideo;
    if (between.trim().isEmpty) {
      if (isVideo) {
        flushGroup();
        out.add(SingleVideoSeg(url));
      } else {
        group.add(url);
      }
    } else {
      flushGroup();
      out.add(TextSeg(between));
      if (isVideo) {
        out.add(SingleVideoSeg(url));
      } else {
        group.add(url);
      }
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

// --- image grid + single image --------------------------------------------

class _ImageGrid extends StatelessWidget {
  const _ImageGrid({
    required this.urls,
    required this.proxyMedia,
    required this.onMediaFailed,
  });
  final List<String> urls;
  final bool proxyMedia;
  final ValueChanged<bool>? onMediaFailed;

  @override
  Widget build(BuildContext context) {
    if (urls.length == 1) {
      return _SingleImage(
        url: urls.first,
        proxyMedia: proxyMedia,
        onMediaFailed: onMediaFailed,
      );
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
            onMediaFailed: onMediaFailed,
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
    required this.onMediaFailed,
  });
  final String url;
  final List<String> urls;
  final int index;
  final bool proxyMedia;
  final ValueChanged<bool>? onMediaFailed;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => pushMediaViewer(context, images: urls, initialIndex: index),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: CostrNetworkImage(
          url: url,
          forceProxy: proxyMedia,
          fit: BoxFit.cover,
          placeholder: (BuildContext _) => const _Placeholder(),
          errorWidget: (BuildContext _) => const _ErrorBox(),
          onError: onMediaFailed,
        ),
      ),
    );
  }
}

class _SingleImage extends StatelessWidget {
  const _SingleImage({
    required this.url,
    required this.proxyMedia,
    required this.onMediaFailed,
  });
  final String url;
  final bool proxyMedia;
  final ValueChanged<bool>? onMediaFailed;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => pushMediaViewer(context, images: [url]),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: CostrNetworkImage(
          url: url,
          forceProxy: proxyMedia,
          width: double.infinity,
          fit: BoxFit.contain,
          placeholder: (BuildContext _) =>
              const _Placeholder(aspect: 16 / 9),
          errorWidget: (BuildContext _) =>
              const _ErrorBox(aspect: 16 / 9),
          onError: onMediaFailed,
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
/// [eventByIdProvider] (SQLite → in-memory → relay REQ) and renders the
/// author + a content snippet; tap opens `/n/:id`.
class _EventEmbed extends ConsumerWidget {
  const _EventEmbed({required this.id});
  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final async = ref.watch(eventByIdProvider(id));
    final ev = async.value;
    if (ev == null) {
      final notFound = !async.isLoading && async.hasValue;
      return Container(
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: CostrColors.bg2,
          border: Border(
            left: BorderSide(color: theme.colorScheme.outline, width: 3),
          ),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          notFound ? '引用内容不可用' : '加载引用…',
          style: theme.textTheme.bodySmall?.copyWith(color: CostrColors.text3),
        ),
      );
    }
    final meta = ref.watch(metadataProvider(ev.pubkey)).value;
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
          color: CostrColors.bg2,
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
                  child: Text(
                    displayLabelFor(ev.pubkey, meta),
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
                  color: CostrColors.text2,
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
        color: CostrColors.bg2,
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
              color: CostrColors.text3,
            ),
          ),
        ],
      ),
    );
  }
}
