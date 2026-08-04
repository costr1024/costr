/// NIP-01 kind 0 user metadata (profile).
///
/// A kind-0 event's `content` is a JSON object describing the user. This model
/// parses the commonly-used fields. Unknown fields are ignored (forward-compat).
/// See https://github.com/nostr-protocol/nips/blob/master/01.md
library;

import 'package:flutter/foundation.dart';

@immutable
class Metadata {
  const Metadata({
    this.name,
    this.displayName,
    this.picture,
    this.about,
    this.website,
    this.banner,
    this.nip05,
    this.lud06,
    this.lud16,
    this.customEmoji = const <String, String>{},
  });

  /// [tags] is the kind-0 event's tag list — NIP-30 custom emoji used in the
  /// name/about live THERE (`["emoji", shortcode, url]`), not in the JSON
  /// content. Parsed into [customEmoji] (shortcode → image URL).
  factory Metadata.fromJson(Map<String, dynamic> m, {List<dynamic>? tags}) =>
      Metadata(
        name: _asString(m['name']),
        displayName: _asString(m['display_name']),
        picture: _asString(m['picture']),
        about: _asString(m['about']),
        website: _asString(m['website']),
        banner: _asString(m['banner']),
        nip05: _asString(m['nip05']),
        lud06: _asString(m['lud06']),
        lud16: _asString(m['lud16']),
        customEmoji: _emojiFromTags(tags),
      );

  final String? name;
  final String? displayName;
  final String? picture;
  final String? about;
  final String? website;
  final String? banner;
  final String? nip05;
  final String? lud06; // LNURL pay (bech32)
  final String? lud16; // Lightning address (user@domain)

  /// NIP-30 custom emoji declared on the kind-0 event (shortcode → URL).
  /// `:shortcode:` occurrences in [bestName] render as inline images
  /// (Amethyst shows them too — "我用amethyst是可以看到昵称里的自定义表情的").
  final Map<String, String> customEmoji;

  /// Preferred display name: display_name > name.
  String? get bestName => displayName ?? name;

  /// First character (uppercased) for avatar fallback.
  String get initial {
    final n = bestName ?? '';
    if (n.isNotEmpty) return n[0].toUpperCase();
    return '?';
  }

  static String? _asString(Object? v) {
    if (v is String) return v;
    return null;
  }

  /// Parse `["emoji", shortcode, url]` tags (NIP-30) into shortcode → URL.
  static Map<String, String> _emojiFromTags(List<dynamic>? tags) {
    if (tags == null || tags.isEmpty) return const <String, String>{};
    final out = <String, String>{};
    for (final t in tags) {
      if (t is List &&
          t.length >= 3 &&
          t[0] == 'emoji' &&
          t[1] is String &&
          t[2] is String) {
        out[t[1] as String] = t[2] as String;
      }
    }
    return out.isEmpty ? const <String, String>{} : out;
  }

  @override
  String toString() =>
      'Metadata(name: $name, picture: ${picture == null ? '∅' : '…'})';
}
