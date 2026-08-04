/// Display names with NIP-30 custom emoji.
///
/// A kind-0 profile can put `:shortcode:` in its name and declare the image
/// for each shortcode in `["emoji", shortcode, url]` event tags (parsed into
/// [Metadata.customEmoji]). Amethyst renders those inline in the nickname;
/// Costr used to show the raw `:shortcode:` text ("用户昵称里的自定义表情
/// 为什么显示不出来"). [DisplayName] (and [displayNameSpans] for embedding
/// into an existing RichText, e.g. the notification title line) swaps each
/// known shortcode for an inline image sized to the surrounding text;
/// unknown shortcodes keep their text.
library;

import 'package:flutter/material.dart';

import '../models/metadata.dart';
import '../utils/nip19.dart';
import 'proxied_network_image.dart';

/// The `:shortcode:` syntax allowed in names (same charset as NIP-30 usage
/// across clients — letters/digits/_/+/—).
final RegExp _shortcodeRegex = RegExp(r':([a-zA-Z0-9_+-]+):');

/// Plain-text fallback for a pubkey with no (or empty) metadata name —
/// the same fallback [displayLabelFor] in `avatar.dart` uses.
String _fallbackLabel(String pubkey) {
  try {
    return shortenEntity(hexToNpub(pubkey));
  } catch (_) {
    return pubkey.length > 10 ? '${pubkey.substring(0, 8)}…' : pubkey;
  }
}

/// Inline spans rendering [pubkey]'s display name with its NIP-30 custom
/// emoji as inline images. Every returned span carries [style] explicitly,
/// so the list can be dropped into ANY parent TextSpan (notification title
/// line, …) without depending on style inheritance. When the name has no
/// custom emoji this is a single plain TextSpan.
List<InlineSpan> displayNameSpans({
  required String pubkey,
  required Metadata? meta,
  required TextStyle style,
}) {
  final name = meta?.bestName;
  if (name == null || name.isEmpty) {
    return <InlineSpan>[TextSpan(text: _fallbackLabel(pubkey), style: style)];
  }
  final emoji = meta!.customEmoji;
  // Fast path: no custom emoji declared or no shortcode syntax in the name.
  if (emoji.isEmpty || !name.contains(':')) {
    return <InlineSpan>[TextSpan(text: name, style: style)];
  }
  final size = (style.fontSize ?? 14) * 1.3;
  final spans = <InlineSpan>[];
  var last = 0;
  for (final m in _shortcodeRegex.allMatches(name)) {
    if (m.start > last) {
      spans.add(TextSpan(text: name.substring(last, m.start), style: style));
    }
    final code = m.group(1)!;
    final url = emoji[code];
    if (url != null) {
      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 1),
            child: CostrNetworkImage(
              url: url,
              width: size,
              height: size,
              fit: BoxFit.contain,
              memCacheHeight: 64,
              errorWidget: (BuildContext _) => Text(':$code:', style: style),
            ),
          ),
        ),
      );
    } else {
      spans.add(TextSpan(text: m.group(0), style: style));
    }
    last = m.end;
  }
  if (last < name.length) {
    spans.add(TextSpan(text: name.substring(last), style: style));
  }
  return spans;
}

/// Standalone variant for the common "a Text widget showing this user's name"
/// case (feed card header, profile header, …).
class DisplayName extends StatelessWidget {
  const DisplayName({
    super.key,
    required this.pubkey,
    required this.meta,
    this.style,
    this.maxLines,
    this.overflow,
  });

  final String pubkey;
  final Metadata? meta;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow? overflow;

  @override
  Widget build(BuildContext context) {
    final effective = style ?? DefaultTextStyle.of(context).style;
    final name = meta?.bestName;
    if (name == null || name.isEmpty) {
      return Text(
        _fallbackLabel(pubkey),
        style: effective,
        maxLines: maxLines,
        overflow: overflow,
      );
    }
    final emoji = meta!.customEmoji;
    if (emoji.isEmpty || !name.contains(':')) {
      return Text(
        name,
        style: effective,
        maxLines: maxLines,
        overflow: overflow,
      );
    }
    return Text.rich(
      TextSpan(
        style: effective,
        children: displayNameSpans(
          pubkey: pubkey,
          meta: meta,
          style: effective,
        ),
      ),
      maxLines: maxLines,
      overflow: overflow,
    );
  }
}
