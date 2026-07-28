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

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:markdown/markdown.dart' hide Text;
import 'package:url_launcher/url_launcher.dart';

import '../app/providers.dart';
import '../models/event.dart';
import '../utils/nip19.dart';
import 'network_video.dart';

const String _bech32Data = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l';
final RegExp _pubkeyEntityRegex = RegExp('(nprofile1|npub1)[$_bech32Data]{6,}');
final RegExp _mdImageRegex = RegExp(r'!\[([^\]]*)\]\(([^)\s]+)\)');
/// Bare media URLs in content (image/video/file extensions) — stripped from
/// text segments so they don't show as plain text; rendered via imeta extra.
final RegExp _bareMediaUrl = RegExp(
    r'https?://[^\s)]+\.(?:jpg|jpeg|png|gif|webp|bmp|mp4|webm|mov|m4v|mkv|pdf|zip|txt|md|mp3|wav|ogg)');

/// Posts with content longer than this many chars collapse to [_kCollapsedMaxHeight]
/// until expanded.
const int _kCollapseThreshold = 400;
const double _kCollapsedMaxHeight = 220;

class MarkdownContent extends ConsumerStatefulWidget {
  const MarkdownContent({super.key, required this.event, this.initiallyExpanded = false});

  final Event event;
  final bool initiallyExpanded;

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
      final entity = m.group(0)!;
      pubkeysByEntity.putIfAbsent(entity, () => entityToPubkeyHex(entity));
    }
    final nameByPubkey = <String, String>{};
    for (final pk in pubkeysByEntity.values) {
      if (pk == null) continue;
      final meta = ref.watch(metadataProvider(pk)).value;
      final name = meta?.bestName;
      if (name != null && name.isNotEmpty) nameByPubkey[pk] = name;
    }
    final linkified = event.content.replaceAllMapped(
      _pubkeyEntityRegex,
      (Match m) {
        final entity = m.group(0)!;
        final pk = pubkeysByEntity[entity];
        final label = (pk != null ? nameByPubkey[pk] : null) ?? shortenEntity(entity);
        return '[@$label](nostr:$entity)';
      },
    );

    // 2. Tokenize into segments: text / image-group (contiguous) / single video.
    final segments = tokenizeContent(linkified);

    final theme = Theme.of(context);
    final children = <Widget>[];
    for (final seg in segments) {
      if (seg is TextSeg) {
        // Strip bare media URLs from text (they're rendered via imeta extra).
        final cleaned = seg.text.replaceAll(_bareMediaUrl, '').trim();
        if (cleaned.isEmpty) continue;
        children.add(
          MarkdownBody(
            data: cleaned,
            extensionSet: ExtensionSet.gitHubFlavored,
            sizedImageBuilder: (MarkdownImageConfig _) => const SizedBox.shrink(),
            onTapLink: (String text, String? href, String? title) {
              if (href == null) return;
              if (href.startsWith('nostr:')) {
                final entity = href.substring('nostr:'.length);
                final pk = entityToPubkeyHex(entity);
                if (pk != null) context.push('/u/$pk');
              } else if (href.startsWith('http')) {
                launchUrl(Uri.parse(href), mode: LaunchMode.externalApplication);
              }
            },
            styleSheet: MarkdownStyleSheet.fromTheme(theme),
          ),
        );
      } else if (seg is ImageGroupSeg) {
        children.add(_ImageGrid(urls: seg.urls));
      } else if (seg is SingleVideoSeg) {
        children.add(NetworkVideo(url: seg.url));
      }
    }

    // 3. Append NIP-92 imeta media. Only filter out URLs that appear as
    // markdown images ](url) in the content — bare URLs in content are
    // stripped from text (above) and need imeta extra to render the image.
    final extra = event.mediaAttachments
        .where((m) => !event.content.contains('](${m.url})'))
        .toList();
    final extraImages = extra.where((m) => m.isImage).map((m) => m.url).toList();
    final extraVideos = extra.where((m) => m.isVideo).toList();
    if (extraImages.isNotEmpty) {
      children.add(const SizedBox(height: 8));
      children.add(_ImageGrid(urls: extraImages));
    }
    for (final v in extraVideos) {
      children.add(const SizedBox(height: 8));
      children.add(NetworkVideo(url: v.url, width: v.width, height: v.height));
    }
    final extraFiles =
        extra.where((m) => !m.isImage && !m.isVideo).toList();
    if (extraFiles.isNotEmpty) {
      children.add(const SizedBox(height: 8));
      children.add(Wrap(
        spacing: 8,
        runSpacing: 6,
        children: [
          for (final f in extraFiles) _FileChip(name: _fileName(f.url)),
        ],
      ));
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
            child: TextButton(
              onPressed: onToggle,
              child: const Text('收起'),
            ),
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
            child: TextButton(
              onPressed: onToggle,
              child: const Text('展开'),
            ),
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
  const _FileChip({required this.name});
  final String name;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 240),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.insert_drive_file_outlined,
                size: 18, color: theme.colorScheme.primary),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                name,
                style: theme.textTheme.labelSmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
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

  for (final m in _mdImageRegex.allMatches(content)) {
    final between = content.substring(lastEnd, m.start);
    final url = m.group(2)!;
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
class TextSeg extends ContentSeg { TextSeg(this.text); final String text; }
class ImageGroupSeg extends ContentSeg { ImageGroupSeg(this.urls); final List<String> urls; }
class SingleVideoSeg extends ContentSeg { SingleVideoSeg(this.url); final String url; }

// --- image grid + single image --------------------------------------------

class _ImageGrid extends StatelessWidget {
  const _ImageGrid({required this.urls});
  final List<String> urls;

  @override
  Widget build(BuildContext context) {
    if (urls.length == 1) return _SingleImage(url: urls.first);
    return GridView.count(
      crossAxisCount: 3,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 4,
      crossAxisSpacing: 4,
      childAspectRatio: 1,
      children: [for (final u in urls) _GridThumb(url: u)],
    );
  }
}

class _GridThumb extends StatelessWidget {
  const _GridThumb({required this.url});
  final String url;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: CachedNetworkImage(
        imageUrl: url,
        fit: BoxFit.cover,
        placeholder: (BuildContext _, String _) => const _Placeholder(),
        errorWidget: (BuildContext _, String _, Object _) => const _ErrorBox(),
      ),
    );
  }
}

class _SingleImage extends StatelessWidget {
  const _SingleImage({required this.url});
  final String url;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: CachedNetworkImage(
        imageUrl: url,
        width: double.infinity,
        fit: BoxFit.contain,
        placeholder: (BuildContext _, String _) => const _Placeholder(aspect: 16 / 9),
        errorWidget: (BuildContext _, String _, Object _) => const _ErrorBox(aspect: 16 / 9),
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
