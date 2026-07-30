/// NIP-01 Event model.
///
/// Represents a Nostr event as defined in
/// https://github.com/nostr-protocol/nips/blob/master/01.md
///
/// Parsing + signature-verification hook. Signing (building the canonical
/// serialized form, hashing, and signing) lands with the compose/posting
/// feature in a later version.
library;

import 'dart:convert';

import 'package:bip340/bip340.dart' as bip340;
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

@immutable
class Event {
  const Event({
    required this.id,
    required this.pubkey,
    required this.createdAt,
    required this.kind,
    required this.tags,
    required this.content,
    required this.sig,
  });

  /// Parse a NIP-01 event JSON array:
  /// `[id, pubkey, created_at, kind, tags, content, sig]`
  factory Event.fromList(List<dynamic> list) {
    if (list.length != 7) {
      throw FormatException(
        'event array must have 7 elements, got ${list.length}',
      );
    }
    final tags = list[4];
    if (tags is! List) {
      throw FormatException(
        'event tags must be a list, got ${tags.runtimeType}',
      );
    }
    return Event(
      id: list[0] as String,
      pubkey: list[1] as String,
      createdAt: (list[2] as num).toInt(),
      kind: (list[3] as num).toInt(),
      tags: tags.cast<List<dynamic>>(),
      content: list[5] as String,
      sig: list[6] as String,
    );
  }

  /// Parse an event sent as a JSON object (some relays send the object form
  /// `{"id","pubkey","created_at","kind","tags","content","sig"}` instead of
  /// the NIP-01 array). Handles both for robustness.
  factory Event.fromJson(Map<String, dynamic> m) {
    final tags = m['tags'];
    if (tags is! List) {
      throw FormatException(
        'event tags must be a list, got ${tags.runtimeType}',
      );
    }
    final sig = m['sig'];
    return Event(
      id: m['id'] as String,
      pubkey: m['pubkey'] as String,
      createdAt: (m['created_at'] as num).toInt(),
      kind: (m['kind'] as num).toInt(),
      tags: tags.cast<List<dynamic>>(),
      content: m['content'] as String,
      sig: (sig as String?) ?? '',
    );
  }

  /// Parse an event from either the NIP-01 array form or the object form.
  factory Event.fromMessage(dynamic m) {
    if (m is List) return Event.fromList(m);
    if (m is Map) return Event.fromJson(m as Map<String, dynamic>);
    throw FormatException(
      'event must be a JSON array or object, got ${m.runtimeType}',
    );
  }

  final String id;
  final String pubkey;
  final int createdAt;
  final int kind;
  final List<List<dynamic>> tags;
  final String content;
  final String sig;

  /// NIP-01 text note.
  static const int kindTextNote = 1;

  /// NIP-02 contact list (the user's follows).
  static const int kindContactList = 3;

  bool get isTextNote => kind == kindTextNote;
  bool get isContactList => kind == kindContactList;

  /// True if the event has a `["t", "nsfw"]` tag (convention for NSFW content).
  bool get isNsfw => hashtags.contains('nsfw');

  /// The event id this kind-1 note directly replies to (NIP-10), or null if it
  /// is a top-level post. Marker precedence: "reply" > legacy positional (empty
  /// marker, last one wins) > "root" (reply-to-root). "mention" tags are not
  /// replies and are ignored.
  String? get replyToId {
    String? replyMarker;
    String? rootMarker;
    String? lastPositional;
    for (final t in tags) {
      if (t.length < 2 || t[0] != 'e' || t[1] is! String) continue;
      final id = t[1] as String;
      final marker = (t.length >= 4 && t[3] is String) ? (t[3] as String) : '';
      if (marker == 'reply') {
        replyMarker = id;
      } else if (marker == 'root') {
        rootMarker = id;
      } else if (marker.isEmpty) {
        lastPositional = id;
      }
    }
    return replyMarker ?? lastPositional ?? rootMarker;
  }

  /// True if this note is a reply (has a parent it replies to).
  bool get isReply => replyToId != null;

  /// The thread root for this note (for building reply tags). The `e` tag with
  /// marker "root" if present; else the reply parent chain (replyToId); else
  /// this note itself (top-level post is its own root).
  String get rootEventId {
    for (final t in tags) {
      if (t.length >= 4 && t[0] == 'e' && t[3] is String && t[3] == 'root') {
        return t[1] as String;
      }
    }
    return replyToId ?? id;
  }

  /// Hashtags from NIP-12 `["t", "value"]` tags AND inline `#hashtag` patterns
  /// found in the content body. Values are lowercased and deduped (NIP-12
  /// recommends lowercase). Order: t-tags first, then content matches.
  List<String> get hashtags {
    final out = <String>[];
    final seen = <String>{};
    for (final tag in tags) {
      if (tag.length >= 2 && tag[0] == 't' && tag[1] is String) {
        final v = (tag[1] as String).trim().toLowerCase();
        if (v.isNotEmpty && seen.add(v)) out.add(v);
      }
    }
    // Inline #hashtag in content. `#` must start a word (not be part of a
    // URL/path/protocol), and be followed by letters/digits/underscore (incl.
    // Unicode, so #中文 works). Markdown headings `# Heading` (with space)
    // don't match — there's no word char immediately after `#`.
    final inline = RegExp(r'(?<![\w/:.])#([\p{L}\p{N}_]+)', unicode: true);
    for (final m in inline.allMatches(content)) {
      final v = m.group(1)!.toLowerCase();
      if (v.isNotEmpty && seen.add(v)) out.add(v);
    }
    return out;
  }

  /// Pubkeys referenced by `p` tags (NIP-02 follows). Values only — relay
  /// markers (NIP-65) and petnames are ignored. Deduped, order-preserving.
  List<String> get pTagPubkeys {
    final out = <String>[];
    final seen = <String>{};
    for (final tag in tags) {
      if (tag.length >= 2 && tag[0] == 'p' && tag[1] is String) {
        final pk = tag[1] as String;
        if (seen.add(pk)) out.add(pk);
      }
    }
    return out;
  }

  /// Media attachments from NIP-92 `imeta` tags. Each imeta tag is
  /// `["imeta", "url <u>", "m <mimetype>", "x <w>", "y <h>", "dim WxH", ...]`.
  /// `blurhash`/`alt` are parsed but not surfaced in v1.
  List<MediaAttachment> get mediaAttachments {
    final out = <MediaAttachment>[];
    for (final tag in tags) {
      if (tag.isEmpty || tag[0] != 'imeta') continue;
      String? url;
      String? mimeType;
      int? width;
      int? height;
      for (int i = 1; i < tag.length; i++) {
        final part = tag[i];
        if (part is! String) continue;
        final sp = part.indexOf(' ');
        if (sp <= 0) continue;
        final key = part.substring(0, sp);
        final value = part.substring(sp + 1);
        switch (key) {
          case 'url':
            url = value;
          case 'm':
            mimeType = value;
          case 'x':
            width = int.tryParse(value);
          case 'y':
            height = int.tryParse(value);
          case 'dim':
            final parts = value.split('x');
            if (parts.length == 2) {
              width = int.tryParse(parts[0]);
              height = int.tryParse(parts[1]);
            }
        }
      }
      if (url != null && url.isNotEmpty) {
        out.add(
          MediaAttachment(
            url: url,
            mimeType: mimeType,
            width: width,
            height: height,
          ),
        );
      }
    }
    return out;
  }

  /// Verify the Schnorr signature against `pubkey` and `id` (hook; v1 leaves
  /// arrival verification OFF for perf — available for selective use later).
  bool get isSignatureValid {
    try {
      return bip340.verify(pubkey, id, sig);
    } catch (_) {
      return false;
    }
  }

  String get _preview =>
      content.length <= 40 ? content : '${content.substring(0, 40)}…';

  /// NIP-01 canonical serialization for the event id: the JSON array
  /// `[0, pubkey, created_at, kind, tags, content]` (compact, no signature).
  String computeId() {
    final serialized = jsonEncode(<dynamic>[
      0,
      pubkey,
      createdAt,
      kind,
      tags,
      content,
    ]);
    return sha256.convert(utf8.encode(serialized)).toString();
  }

  /// NIP-01 wire OBJECT form: `{"id","pubkey","created_at","kind","tags",
  /// "content","sig"}`. Modern relays (2026) require the EVENT message's
  /// event payload to be an object, not the legacy array form.
  Map<String, dynamic> toWireObject() => <String, dynamic>{
    'id': id,
    'pubkey': pubkey,
    'created_at': createdAt,
    'kind': kind,
    'tags': tags,
    'content': content,
    'sig': sig,
  };

  @override
  String toString() => 'Event(kind=$kind, id=$id, content=$_preview)';
}

/// A media attachment (image or video) from a NIP-92 imeta tag, or inferred
/// from a URL's extension when the mimetype is absent.
@immutable
class MediaAttachment {
  const MediaAttachment({
    required this.url,
    this.mimeType,
    this.width,
    this.height,
  });

  final String url;
  final String? mimeType;
  final int? width;
  final int? height;

  bool get isVideo {
    final m = mimeType;
    if (m != null && m.isNotEmpty) {
      if (m.startsWith('video/')) return true;
      if (m.startsWith('image/')) return false;
      // mime set but neither image nor video → fall through to URL check.
    }
    return _hasExt(const {'.mp4', '.webm', '.mov', '.m4v', '.mkv'});
  }

  bool get isImage {
    final m = mimeType;
    if (m != null && m.isNotEmpty) {
      if (m.startsWith('image/')) return true;
      if (m.startsWith('video/')) return false;
      // mime set but neither image nor video → fall through to URL check.
    }
    return _hasExt(const {'.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp'});
  }

  bool _hasExt(Set<String> exts) {
    final lower = url.toLowerCase().split('?').first;
    return exts.any(lower.endsWith);
  }

  @override
  String toString() => 'MediaAttachment($url, m=$mimeType, ${width}x$height)';
}
