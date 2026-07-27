/// Renders post content as markdown (GitHub-flavored) with cached images and
/// inline video, then appends any NIP-92 imeta media not already referenced
/// in the content body.
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart';

import '../models/event.dart';
import 'network_video.dart';

class MarkdownContent extends StatelessWidget {
  const MarkdownContent({super.key, required this.event});

  final Event event;

  @override
  Widget build(BuildContext context) {
    final media = event.mediaAttachments;
    // Append imeta media whose URL isn't already embedded in the content.
    final extra = media.where((m) => !event.content.contains(m.url)).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        MarkdownBody(
          data: event.content,
          extensionSet: ExtensionSet.gitHubFlavored,
          sizedImageBuilder: (MarkdownImageConfig config) => _MediaView(
            attachment: MediaAttachment(
              url: config.uri.toString(),
              width: config.width?.toInt(),
              height: config.height?.toInt(),
            ),
          ),
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
    final aspect = (attachment.width != null && attachment.height != null && attachment.height! > 0)
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
