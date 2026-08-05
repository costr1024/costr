/// Lightweight @-mention linkifier for clipped post previews (quote-card
/// body, reply-to parent snippet, notification preview).
///
/// These snippets use `Text.rich(..., maxLines, overflow: ellipsis)` —
/// `flutter_markdown` can't render inside a maxLines-clipped `Text`, so a
/// bare `nostr:nprofile1…` / `nostr:npub1…` (or the markdown-link form
/// `[@name](nostr:npub1…)`) would otherwise show RAW to the user. This turns
/// each embedded pubkey entity into a styled `@nickname` span (resolved from
/// kind-0 metadata, falling back to a shortened entity / the link label),
/// matching how the full feed renderer (`MarkdownContent`) displays mentions.
///
/// This deliberately does NOT render full markdown (links, bold, …) — it's a
/// fallback for previews only. The full `MarkdownContent` is used where the
/// whole post body is shown.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../utils/nip19.dart';

/// Matches a bare pubkey entity `nostr:npub1…` / `nostr:nprofile1…` (the
/// optional `nostr:` prefix is consumed). The `(?<!\]\()` lookbehind avoids
/// matching an entity already inside a markdown link's `](href)`. New posts
/// publish bare entities (Amethyst form); legacy costr markdown-link mentions
/// are intentionally NOT handled here per scope.
final RegExp _mentionRegex = RegExp(
  r'(?<!\]\()(?:nostr:)?((?:nprofile1|npub1)[qpzry9x8gf2tvdw0s3jn54khce6mua7l]{6,})',
);

/// Build an [InlineSpan] tree for [text] where every embedded pubkey entity
/// is rendered as a styled `@nickname` span. Use with `Text.rich(span,
/// maxLines: …, overflow: TextOverflow.ellipsis)`.
///
/// [onTapPubkey], if set, makes each `@nickname` tappable (e.g. push
/// `/u/<pubkey>`); pass null for non-interactive previews (the surrounding
/// card already routes somewhere). Names resolve synchronously from
/// [metadataProvider]'s current value; once metadata streams in, rebuild the
/// owning widget (it should `ref.watch(metadataProvider(pk))` for visible
/// mentioned pubkeys) so this re-runs with the real name.
InlineSpan linkifyMentions(
  String text,
  WidgetRef ref, {
  TextStyle? baseStyle,
  TextStyle? mentionStyle,
  void Function(String pubkey)? onTapPubkey,
}) {
  if (text.isEmpty) return TextSpan(text: '', style: baseStyle);

  final children = <InlineSpan>[];
  var lastEnd = 0;
  for (final m in _mentionRegex.allMatches(text)) {
    // An entity INSIDE a URL (npub-subdomain blossom media hosts like
    // `https://npub1….blossom.band/x.mp4`) is part of the URL, not a mention
    // — leave it as plain text or the URL breaks. Skipped matches stay in the
    // surrounding plain-text spans (lastEnd only advances on accepted ones).
    if (entityMatchInUrl(text, m)) continue;
    // Plain text before this match.
    if (m.start > lastEnd) {
      children.add(
        TextSpan(text: text.substring(lastEnd, m.start), style: baseStyle),
      );
    }
    final entity = m.group(1)!;
    final pk = entityToPubkeyHex(entity);
    String name;
    if (pk != null) {
      final meta = ref.read(metadataProvider(pk)).value;
      final resolved = meta?.bestName;
      name = (resolved != null && resolved.isNotEmpty)
          ? resolved
          : shortenEntity(entity);
    } else {
      name = m.group(0)!; // couldn't decode — show the raw substring.
    }
    final recognizer = (onTapPubkey != null && pk != null)
        ? (TapGestureRecognizer()..onTap = () => onTapPubkey(pk))
        : null;
    children.add(
      TextSpan(text: '@$name', style: mentionStyle, recognizer: recognizer),
    );
    lastEnd = m.end;
  }
  // Trailing plain text.
  if (lastEnd < text.length) {
    children.add(TextSpan(text: text.substring(lastEnd), style: baseStyle));
  }
  // All-plain (no mentions) → a single TextSpan keeps Text.rich happy.
  if (children.isEmpty) return TextSpan(text: text, style: baseStyle);
  return TextSpan(style: baseStyle, children: children);
}
