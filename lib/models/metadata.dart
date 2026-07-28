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
  });

  factory Metadata.fromJson(Map<String, dynamic> m) => Metadata(
        name: _asString(m['name']),
        displayName: _asString(m['display_name']),
        picture: _asString(m['picture']),
        about: _asString(m['about']),
        website: _asString(m['website']),
        banner: _asString(m['banner']),
        nip05: _asString(m['nip05']),
        lud06: _asString(m['lud06']),
        lud16: _asString(m['lud16']),
      );

  final String? name;
  final String? displayName;
  final String? picture;
  final String? about;
  final String? website;
  final String? banner;
  final String? nip05;
  final String? lud06;  // LNURL pay (bech32)
  final String? lud16;  // Lightning address (user@domain)

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

  @override
  String toString() => 'Metadata(name: $name, picture: ${picture == null ? '∅' : '…'})';
}
