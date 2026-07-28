/// Avatar widget: loads the picture from the pubkey's kind-0 metadata (NIP-01)
/// via [metadataProvider], with a disk-cached image and an initial-letter fallback.
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../models/metadata.dart';
import '../utils/nip19.dart';

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
      child: CachedNetworkImage(
        imageUrl: url,
        width: radius * 2,
        height: radius * 2,
        fit: BoxFit.cover,
        placeholder: (BuildContext _, String _) => fallback,
        errorWidget: (BuildContext _, String _, Object _) => fallback,
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
