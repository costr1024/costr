/// Renders post content as markdown (GitHub-flavored) with cached images and
/// inline video, then appends any NIP-92 imeta media not already referenced
/// in the content body.
///
/// NIP-19 pubkey mentions (`npub1…` / `nprofile1…`) in the content are
/// linkified: rendered as tappable links that jump to the user's profile
/// (`/u/<pubkey>`). The link label is the resolved kind-0 name if metadata
/// is cached, else the shortened entity. Watching metadataProvider keeps the
/// label in sync once the name arrives.
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:markdown/markdown.dart';

import '../app/providers.dart';
import '../models/event.dart';
import '../utils/nip19.dart';
import 'network_video.dart';

/// bech32 charset (excludes 1/b/i/o). After the hrp+separator '1', only these.
const String _bech32Data = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l';

final RegExp _pubkeyEntityRegex =
    RegExp('(nprofile1|npub1)[$_bech32Data]{6,}');

class MarkdownContent extends ConsumerWidget {
  const MarkdownContent({super.key, required this.event});

  final Event event;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final matches = _pubkeyEntityRegex.allMatches(event.content).toList();
    final pubkeyByEntity = <String, String?>{};
    for (final m in matches) {
      final entity = m.group(0)!;
      pubkeyByEntity.putIfAbsent(entity, () => entityToPubkeyHex(entity));
    }

    // Watch metadata for each mentioned pubkey so the label refreshes when the
    // kind-0 name arrives (rebuilds MarkdownContent).
    final nameByPubkey = <String, String>{};
    for (final pk in pubkeyByEntity.values) {
      if (pk == null) continue;
      final meta = ref.watch(metadataProvider(pk)).value;
      final name = meta?.bestName;
      if (name != null && name.isNotEmpty) nameByPubkey[pk] = name;
    }

    // Single-pass linkify so the inserted links (which contain the entity) are
    // not re-matched.
    final processed = event.content.replaceAllMapped(
      _pubkeyEntityRegex,
      (Match m) {
        final entity = m.group(0)!;
        final pk = pubkeyByEntity[entity];
        final label = (pk != null ? nameByPubkey[pk] : null) ?? shortenEntity(entity);
        return '[@$label](nostr:$entity)';
      },
    );

    final media = event.mediaAttachments;
    final extra = media.where((m) => !event.content.contains(m.url)).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        MarkdownBody(
          data: processed,
          extensionSet: ExtensionSet.gitHubFlavored,
          sizedImageBuilder: (MarkdownImageConfig config) => _MediaView(
            attachment: MediaAttachment(
              url: config.uri.toString(),
              width: config.width?.toInt(),
              height: config.height?.toInt(),
            ),
          ),
          onTapLink: (String text, String? href, String? title) {
            if (href == null) return;
            if (href.startsWith('nostr:')) {
              final entity = href.substring('nostr:'.length);
              final pk = entityToPubkeyHex(entity);
              if (pk != null) context.push('/u/$pk');
            }
          },
          styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)),
        ),
        for (final m in extra) ...[
          const SizedBox(height: 8),
          _MediaView(attachment: m),
        ],
      ],
    );
  }
}

class _MediaView extends StatelessWidget {
  const _MediaView({required this.attachment});
  final MediaAttachment attachment;

  @override
  Widget build(BuildContext context) {
    if (attachment.isVideo) {
      return NetworkVideo(
        url: attachment.url,
        width: attachment.width,
        height: attachment.height,
      );
    }
    final aspect = (attachment.width != null &&
            attachment.height != null &&
            attachment.height! > 0)
        ? (attachment.width! / attachment.height!)
        : 16.0 / 9.0;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: AspectRatio(
        aspectRatio: aspect,
        child: CachedNetworkImage(
          imageUrl: attachment.url,
          fit: BoxFit.cover,
          placeholder: (BuildContext _, String _) => const _Placeholder(),
          errorWidget: (BuildContext _, String _, Object _) => const _ErrorBox(),
        ),
      ),
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder();
  @override
  Widget build(BuildContext context) => Container(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        alignment: Alignment.center,
        child: const SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
}

class _ErrorBox extends StatelessWidget {
  const _ErrorBox();
  @override
  Widget build(BuildContext context) => Container(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        alignment: Alignment.center,
        child: const Icon(Icons.broken_image_outlined),
      );
}
