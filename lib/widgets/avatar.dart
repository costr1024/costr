/// Avatar widget: loads the picture from the pubkey's kind-0 metadata (NIP-01)
/// via [metadataProvider], with a disk-cached image and an initial-letter fallback.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../models/metadata.dart';
import '../utils/nip19.dart';
import 'proxied_network_image.dart';

class Avatar extends ConsumerWidget {
  const Avatar({super.key, required this.pubkey, this.radius = 18});
  final String pubkey;
  final double radius;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final meta = ref.watch(metadataProvider(pubkey)).value;
    final url = meta?.picture;
    final initial = (meta?.bestName ?? '').isNotEmpty
        ? meta!.bestName![0].toUpperCase()
        : '?';
    final fallback = _InitialCircle(initial: initial, radius: radius);

    if (url == null || url.trim().isEmpty) return fallback;

    return ClipOval(
      // No auto-proxy here (manual proxy is a post-media affordance; avatars
      // fall back to the initial-letter circle on failure). [metadataProvider]
      // resolves the picture URL; if the host is unreachable the fallback
      // shows rather than hammering the public proxy mirror.
      child: CostrNetworkImage(
        url: url,
        width: radius * 2,
        height: radius * 2,
        fit: BoxFit.cover,
        placeholder: (BuildContext _) => fallback,
        errorWidget: (BuildContext _) => fallback,
      ),
    );
  }
}

/// Default avatar: a gradient circle with the first letter. Has visual
/// distinction from the surface (not transparent/white). Also used when
/// the picture URL is missing or fails to load.
class _InitialCircle extends StatelessWidget {
  const _InitialCircle({required this.initial, required this.radius});
  final String initial;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: radius * 2,
      height: radius * 2,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF6750A4), Color(0xFF9C27B0)],
        ),
      ),
      child: Center(
        child: Text(
          initial,
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w600,
            fontSize: radius * 0.9,
          ),
        ),
      ),
    );
  }
}

/// Short display label for a pubkey: metadata name > shortened npub.
String displayLabelFor(String pubkey, Metadata? meta) {
  final name = meta?.bestName;
  if (name != null && name.isNotEmpty) return name;
  try {
    return shortenEntity(hexToNpub(pubkey));
  } catch (_) {
    return pubkey.length > 10 ? '${pubkey.substring(0, 8)}…' : pubkey;
  }
}
