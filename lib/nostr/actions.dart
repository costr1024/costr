/// High-level Nostr actions (reply / reaction / repost / quote / follow) that
/// build the right NIP-10/18/25/30/02 tags, sign, and (via the caller) publish.
/// All reuse Identity.signEvent; the caller runs RelayPool.publishAndWait.
library;

import 'dart:convert';
import 'dart:math' show Random;

import '../models/bookmark_entry.dart';
import '../models/event.dart';
import '../models/mute_set.dart';
import '../utils/nip19.dart';
import '../utils/nip44.dart';
import 'identity.dart';

/// NIP-31 client tag identifying Costr as the publishing app (Amethyst parity:
/// every published event carries `["client","Amethyst"]`). Appended to all
/// events built here so other clients can attribute the source.
const List<String> _clientTag = ['client', 'Costr'];

/// The `d` tag value of [e], or null if absent. Identity key for a
/// parameterized-replaceable event.
String? _dTagOf(Event e) {
  for (final t in e.tags) {
    if (t.length >= 2 && t[0] == 'd' && t[1] is String) return t[1] as String;
  }
  return null;
}

/// The NIP-33 address coordinate `K:pubkey:d` for [e] if it is
/// parameterized-replaceable (kind 30000–39999 with a `d` tag), else null.
/// Used to emit the `a` tag in reposts/reactions/deletions of addressable
/// events — Amethyst includes `a` for addressable targets (NIP-18/25/09).
String? _addressCoordOf(Event e) {
  final k = e.kind;
  if (k < 30000 || k >= 40000) return null;
  final d = _dTagOf(e);
  if (d == null) return null;
  return '$k:${e.pubkey}:$d';
}

class NostrActions {
  NostrActions(this.id);
  final Identity id;

  /// Reply to [parent] (NIP-10). Includes a root marker (the thread root,
  /// computed from the parent's tags) and a reply marker (the parent), plus a
  /// `p` tag for the parent's author. [relay] is a best-effort NIP-65 hint
  /// (the parent author's write relay) attached to the `e`/`p` tags so other
  /// clients can fetch the referenced event/profile — empty when unknown
  /// (Amethyst's fallback shape). [extraTags] (e.g. imeta) are appended.
  Event reply(
    Event parent,
    String content, {
    List<List<String>> extraTags = const [],
    String relay = '',
  }) {
    final rootId = parent.rootEventId;
    final tags = <List<String>>[
      ['e', rootId, relay, 'root'],
      ['e', parent.id, relay, 'reply'],
      ['p', parent.pubkey, relay],
      ...extraTags,
    ];
    return id.signEvent(kind: 1, content: content, tags: [...tags, _clientTag]);
  }

  /// Reaction (NIP-25 kind 7). [content] is the emoji (unicode), "+" for a
  /// simple like, or ":shortcode:" for a custom-emoji reaction. When
  /// [customShortcode]+[customUrl] are set, a NIP-30 `emoji` tag is added.
  Event reaction(
    Event target,
    String content, {
    String? customShortcode,
    String? customUrl,
    String relay = '',
  }) {
    final tags = <List<String>>[
      ['e', target.id, relay, target.pubkey],
      ['p', target.pubkey, relay],
      ['k', '${target.kind}'],
    ];
    // NIP-25: include `a` for addressable reaction targets (Amethyst does).
    final coord = _addressCoordOf(target);
    if (coord != null) tags.add(['a', coord]);
    if (customShortcode != null && customUrl != null) {
      tags.add(['emoji', customShortcode, customUrl]);
    }
    return id.signEvent(kind: 7, content: content, tags: [...tags, _clientTag]);
  }

  /// Repost (NIP-18 kind 6). content = the stringified JSON of the reposted
  /// event; tags reference it. [relay] is a best-effort NIP-65 hint (the
  /// reposted author's write relay) so other clients can fetch the original.
  Event repost(Event target, {String relay = ''}) {
    final tags = <List<String>>[
      ['e', target.id, relay],
      ['p', target.pubkey, relay],
      ['k', '${target.kind}'],
    ];
    // NIP-18: include `a` for addressable repost targets (Amethyst does).
    final coord = _addressCoordOf(target);
    if (coord != null) tags.add(['a', coord]);
    return id.signEvent(
      kind: 6,
      content: jsonEncode(target.toWireObject()),
      tags: [...tags, _clientTag],
    );
  }

  /// Add [pubkey] to a NIP-51 kind-30000 categorized people list (Follow set).
  ///
  /// [current] is the user's existing kind-30000 event for that group (or
  /// null for a new list). [category] is the group's display name — used as
  /// the `d` identifier (and a `name` tag) ONLY when creating a new list.
  ///
  /// When editing an existing list ([current] != null), the original `d`
  /// identifier is preserved verbatim and ALL metadata tags (`name`/`alt`/
  /// `description`/`image`/…) are carried over — only the `p` roster is
  /// rebuilt. This matters because Amethyst stores a UUID in `d` and the
  /// human name in a `name` tag: rewriting `d` to the display name would
  /// fork the list into a second replaceable event, and dropping the `name`
  /// tag would erase the human name other clients (and Costr's own display)
  /// rely on. See [kind30000DisplayName] for the matching read side.
  Event followCategory(
    Event? current,
    String pubkey,
    String category, {
    String relay = '',
  }) {
    final tags = <List<String>>[];
    if (current != null) {
      // 1. Carry over every non-`p`/non-`client` tag verbatim — preserves
      //    Amethyst's UUID `d` + human `name` + alt/description/image/… .
      for (final t in current.tags) {
        if (t.isEmpty) continue;
        if (t[0] == 'p' || t[0] == 'client') continue;
        tags.add(t.map((e) => e.toString()).toList());
      }
      // 2. Rebuild the p roster: keep existing entries (minus [pubkey] so
      //    its relay hint can be refreshed), then add [pubkey].
      final seen = <String>{};
      for (final t in current.tags) {
        if (t.length < 2 || t[0] != 'p' || t[1] is! String) continue;
        final pk = t[1] as String;
        if (pk == pubkey) continue;
        final r = (t.length >= 3 && t[2] is String) ? (t[2] as String) : '';
        tags.add(['p', pk, r]);
        seen.add(pk);
      }
      if (seen.add(pubkey)) {
        tags.add(['p', pubkey, relay]);
      }
    } else {
      // New list: d = a random UUID4 (Amethyst convention — a stable opaque
      // identifier, NOT the human name) + a `name` tag carrying the human
      // name so every client (Amethyst, Costr's name-first display) shows
      // it. A stable d is what makes [renameFollowSet] safe: renaming only
      // rewrites the `name` tag, never `d`, so the list never forks into a
      // second replaceable event (the bug that produced the orphaned
      // UUID-named lists you saw in Amethyst).
      tags.add(['d', _uuidV4()]);
      tags.add(['name', category]);
      tags.add(['p', pubkey, relay]);
    }
    return id.signEvent(kind: 30000, content: '', tags: [...tags, _clientTag]);
  }

  /// Rename a NIP-51 kind-30000 follow set to [newName]. Republishes the set
  /// with the `d` identifier preserved VERBATIM and only the `name` tag
  /// updated — rewriting `d` would fork the list into a second replaceable
  /// event (the old `d` version would linger on relays/other clients, exactly
  /// the UUID-named-ghost-list problem). All other metadata (alt/description/
  /// image) and the `p` roster are carried over unchanged.
  Event renameFollowSet(Event current, String newName) {
    final tags = <List<String>>[];
    // d: preserve verbatim. If missing (shouldn't happen for a real set),
    // mint a fresh UUID so the event is still well-formed.
    String? dVal;
    for (final t in current.tags) {
      if (t.length >= 2 && t[0] == 'd' && t[1] is String) {
        dVal = t[1] as String;
        break;
      }
    }
    tags.add(['d', dVal ?? _uuidV4()]);
    // Carry over metadata tags except d/name/p/client (name is re-added below).
    for (final t in current.tags) {
      if (t.isEmpty) continue;
      if (t[0] == 'd' || t[0] == 'name' || t[0] == 'p' || t[0] == 'client') {
        continue;
      }
      tags.add(t.map((e) => e.toString()).toList());
    }
    tags.add(['name', newName]);
    // p roster — carry over verbatim (relay hints + petnames preserved).
    for (final t in current.tags) {
      if (t.length < 2 || t[0] != 'p' || t[1] is! String) continue;
      tags.add(t.map((e) => e.toString()).toList());
    }
    return id.signEvent(kind: 30000, content: '', tags: [...tags, _clientTag]);
  }

  /// NIP-09 deletion of a NIP-51 kind-30000 follow set. Publishes a kind-5
  /// with an `a` tag for the parameterized-replaceable coordinate
  /// `30000:pubkey:d` — this deletes EVERY version of the set (not just one
  /// event id), which is the correct form for replaceable events. Also adds
  /// an `e` tag pointing at the current event id for clients that key off
  /// that. Amethyst's own delete only sends `e` and is therefore ineffective
  /// for kind-30000; this is the fix. On receipt, Costr's
  /// [EventStoreNotifier._applyDeletion] clears the local SQLite row
  /// (author-validated).
  Event deleteFollowSet(Event current) {
    String? dVal;
    for (final t in current.tags) {
      if (t.length >= 2 && t[0] == 'd' && t[1] is String) {
        dVal = t[1] as String;
        break;
      }
    }
    final coord = '30000:${id.pubkeyHex}:${dVal ?? ''}';
    final tags = <List<String>>[
      ['e', current.id],
      ['a', coord],
      // Amethyst's DeletionEvent.build emits the author `p` + original `kind`
      // for addressable deletes; include them so Costr's outgoing delete
      // matches Amethyst exactly (interop is via `e`+`a`, but `p`+`kind` are
      // harmless extras Amethyst clients key off).
      ['p', current.pubkey],
      ['k', '${current.kind}'],
      _clientTag,
    ];
    return id.signEvent(kind: 5, content: '', tags: tags);
  }

  /// Random UUID v4 string (8-4-4-4-12, version/variant bits set), used as
  /// the `d` identifier for new kind-30000 follow sets (Amethyst convention).
  String _uuidV4() {
    final r = Random.secure();
    final bytes = List<int>.generate(16, (_) => r.nextInt(256));
    bytes[6] = (bytes[6] & 0x0F) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3F) | 0x80; // variant 10xx
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  /// Unfollow [pubkey] (NIP-02 kind 3). Publishes the FULL updated p-tag list
  /// minus [pubkey]. [currentKind3] is the user's existing kind-3 event, or
  /// null (no-op publish of an empty list). Existing entries' relay/petname
  /// are preserved.
  Event unfollow(Event? currentKind3, String pubkey) {
    final tags = <List<String>>[];
    if (currentKind3 != null) {
      for (final t in currentKind3.tags) {
        if (t.length < 2 || t[0] != 'p' || t[1] is! String) continue;
        final pk = t[1] as String;
        if (pk == pubkey) continue;
        final r = (t.length >= 3 && t[2] is String) ? (t[2] as String) : '';
        final petname = (t.length >= 4 && t[3] is String)
            ? (t[3] as String)
            : '';
        tags.add(petname.isEmpty ? ['p', pk, r] : ['p', pk, r, petname]);
      }
    }
    return id.signEvent(kind: 3, content: '', tags: [...tags, _clientTag]);
  }

  /// Build a NIP-51 kind-30015 Interests list (followed hashtags). [current]
  /// is the user's existing kind-30015 default list (d-tag "") or null.
  /// Preserves existing `t` tags; adds [add] if non-null and not already
  /// present; removes [remove] if present. Values are lowercased (NIP-12).
  /// The default list carries d="" so it is a single replaceable event per
  /// user — the user's set of followed hashtags, synced across relays.
  Event interests(Event? current, {String? add, String? remove}) {
    String norm(String s) => s.toLowerCase().replaceAll('#', '').trim();
    final tags = <List<String>>[
      ['d', ''],
    ];
    final seen = <String>{};
    if (current != null) {
      for (final t in current.tags) {
        if (t.length < 2 || t[0] != 't' || t[1] is! String) continue;
        final v = norm(t[1] as String);
        if (v.isEmpty) continue;
        if (remove != null && v == remove) continue;
        if (seen.add(v)) tags.add(['t', v]);
      }
    }
    if (add != null) {
      final v = norm(add);
      if (v.isNotEmpty && seen.add(v)) tags.add(['t', v]);
    }
    return id.signEvent(kind: 30015, content: '', tags: [...tags, _clientTag]);
  }

  /// Build/modify a NIP-51 kind-10015 Interests list — the user's FOLLOWED
  /// HASHTAGS. **Amethyst stores these as a PRIVATE list**: the `t` tags live
  /// in the NIP-44-encrypted `.content` as a JSON array `[["t","tag"],…]`
  /// (decryptable only by the owner), while the public tags carry just an
  /// `alt`/`client` label. Costr matches this EXACTLY so followed hashtags
  /// interoperate with Amethyst on both read and write — critical for
  /// Amethyst→Costr migration. [current] is the user's existing kind-10015
  /// (or null for a first follow). [add]/[remove] are lowercased hashtag
  /// values. The previous [interests] (kind-30015, plain t tags) is left in
  /// place only to read legacy/plain interest sets published by other
  /// clients; new writes go through this method.
  Event followedHashtags(Event? current, {String? add, String? remove}) {
    String norm(String s) => s.toLowerCase().replaceAll('#', '').trim();
    final tags = <List<String>>[];
    // Public label tags only (alt). t tags are NOT public — they go in the
    // encrypted content. Preserve an existing alt, else default "Hashtag List"
    // (Amethyst's label).
    String? altVal;
    if (current != null) {
      for (final t in current.tags) {
        if (t.isEmpty) continue;
        if (t[0] == 'alt' && altVal == null && t.length > 1 && t[1] is String) {
          altVal = t[1] as String;
        }
      }
    }
    tags.add(['alt', altVal ?? 'Hashtag List']);
    // Load existing followed hashtags from the encrypted content.
    final pairs = <List<String>>[];
    final seen = <String>{};
    if (current != null && current.content.isNotEmpty) {
      try {
        final decoded = nip44Decrypt(id.privkeyHex, id.pubkeyHex, current.content);
        final arr = jsonDecode(decoded);
        if (arr is List) {
          for (final t in arr) {
            if (t is List && t.length >= 2 && t[0] == 't' && t[1] is String) {
              final v = (t[1] as String);
              if (seen.add(v)) pairs.add(['t', v]);
            }
          }
        }
      } catch (_) {
        // Malformed/undecryptable — start fresh.
      }
    }
    if (remove != null) {
      final r = norm(remove);
      pairs.removeWhere((p) => p[1] == r);
      seen.remove(r);
    }
    if (add != null) {
      final a = norm(add);
      if (a.isNotEmpty && seen.add(a)) pairs.add(['t', a]);
    }
    final content = pairs.isEmpty
        ? ''
        : nip44Encrypt(id.privkeyHex, id.pubkeyHex, jsonEncode(pairs));
    return id.signEvent(
      kind: 10015,
      content: content,
      tags: [...tags, _clientTag],
    );
  }

  /// Extract followed hashtags from a kind-10015 Interests event: decrypt
  /// the NIP-44 `.content` (owner-only — needs the privkey, so non-owners
  /// get an empty list, which is correct for a private list) and parse the
  /// `[["t",…]]` JSON array. Lowercased, deduped, order-preserved. Empty for
  /// a null/undecryptable event.
  List<String> followedHashtagTags(Event? e) {
    if (e == null || e.content.isEmpty) return const <String>[];
    try {
      final decoded = nip44Decrypt(id.privkeyHex, id.pubkeyHex, e.content);
      final arr = jsonDecode(decoded);
      if (arr is List) {
        final out = <String>[];
        final seen = <String>{};
        for (final t in arr) {
          if (t is List && t.length >= 2 && t[0] == 't' && t[1] is String) {
            final v = (t[1] as String).toLowerCase();
            if (v.isNotEmpty && seen.add(v)) out.add(v);
          }
        }
        return out;
      }
    } catch (_) {}
    return const <String>[];
  }

  /// Publish updated profile metadata (NIP-01 kind 0). [contentJson] is the
  /// stringified JSON of the metadata object.
  Event setMetadata(String contentJson) {
    return id.signEvent(kind: 0, content: contentJson, tags: [_clientTag]);
  }

  /// NIP-65 relay list (kind 10002). Declares which relays other clients
  /// should query for this author's events (outbox/inbox model). Each `["r",
  /// url]` tag with no third marker means the relay is used for both read and
  /// write. kind 10002 is replaceable, so re-publishing simply replaces the
  /// prior list.
  Event relayList(List<String> urls) {
    final tags = <List<String>>[
      for (final url in urls) ['r', url],
    ];
    return id.signEvent(kind: 10002, content: '', tags: [...tags, _clientTag]);
  }

  /// NIP-38 user status (kind 30315, `d`="general") — the short text shown
  /// under the user's name. Parameterized-replaceable (re-publishing replaces
  /// the prior status). Empty [text] clears the status.
  Event userStatus(String text) {
    return id.signEvent(
      kind: 30315,
      content: text,
      tags: const [
        _clientTag,
        ['d', 'general'],
      ],
    );
  }

  /// NIP-09 deletion (kind 5). Publish to ask relays to delete [target]; the
  /// `e` tag references the event id being deleted. Relays that implement
  /// NIP-09 will stop serving the deleted event — not all relays honor this,
  /// so deletion is best-effort.
  Event deleteEvent(Event target, {String reason = ''}) {
    return id.signEvent(
      kind: 5,
      content: reason,
      tags: [
        _clientTag,
        ['e', target.id],
      ],
    );
  }

  /// Quote (kind-1 referencing [quoted]). The user's [content] is followed by a
  /// `nostr:note1…` reference; an `e` mention tag + `p` tag reference the quote.
  /// [extraTags] (e.g. imeta) are appended.
  Event quote(
    Event quoted,
    String content, {
    List<List<String>> extraTags = const [],
    String relay = '',
  }) {
    final ref = 'nostr:${hexToNote(quoted.id)}';
    final full = content.isEmpty ? ref : '$content\n\n$ref';
    final tags = <List<String>>[
      ['e', quoted.id, relay, 'mention'],
      ['p', quoted.pubkey, relay],
      ...extraTags,
    ];
    return id.signEvent(kind: 1, content: full, tags: [...tags, _clientTag]);
  }

  /// Follow [newPubkey] (NIP-02 kind 3). Publishes the FULL updated p-tag list
  /// (preserving existing entries' relay/petname). [currentKind3] is the
  /// user's existing kind-3 event, or null if they have none yet.
  Event follow(Event? currentKind3, String newPubkey, {String relay = ''}) {
    final tags = <List<String>>[];
    final seen = <String>{};
    if (currentKind3 != null) {
      for (final t in currentKind3.tags) {
        if (t.length < 2 || t[0] != 'p' || t[1] is! String) continue;
        final pk = t[1] as String;
        if (pk == newPubkey) continue; // re-added below with the new relay hint
        final r = (t.length >= 3 && t[2] is String) ? (t[2] as String) : '';
        final petname = (t.length >= 4 && t[3] is String)
            ? (t[3] as String)
            : '';
        tags.add(petname.isEmpty ? ['p', pk, r] : ['p', pk, r, petname]);
        seen.add(pk);
      }
    }
    if (seen.add(newPubkey)) {
      tags.add(['p', newPubkey, relay]);
    }
    return id.signEvent(kind: 3, content: '', tags: [...tags, _clientTag]);
  }

  /// Bookmark [eventId] in the NIP-51 kind-10003 list (NIP-44-encrypted to self
  /// for private). [current] is the user's existing kind-10003 event (or null
  /// for a first bookmark). Existing public (e/a tags) and private (encrypted
  /// content) entries are preserved.
  Event bookmark(Event? current, String eventId, {required bool publicList}) {
    final tags = <List<String>>[];
    // Preserve existing public e/a tags.
    if (current != null) {
      for (final t in current.tags) {
        if (t.isNotEmpty && (t[0] == 'e' || t[0] == 'a')) {
          tags.add([for (final x in t) x.toString()]);
        }
      }
    }
    // Load existing private entries (encrypted content → decrypt → JSON array).
    final privateTags = <List<String>>[];
    if (current != null && current.content.isNotEmpty) {
      try {
        final decoded = nip44Decrypt(
          id.privkeyHex,
          id.pubkeyHex,
          current.content,
        );
        final arr = jsonDecode(decoded);
        if (arr is List) {
          for (final t in arr) {
            if (t is List) privateTags.add(t.map((e) => e.toString()).toList());
          }
        }
      } catch (_) {
        // Malformed/undecryptable content — start fresh private list.
      }
    }

    String content = '';
    if (publicList) {
      // Add the new e tag to the public tags (dedup).
      if (!tags.any((t) => t.length >= 2 && t[0] == 'e' && t[1] == eventId)) {
        tags.add(['e', eventId]);
      }
      // Re-encrypt the (unchanged) private list back into content.
      if (privateTags.isNotEmpty) {
        content = nip44Encrypt(
          id.privkeyHex,
          id.pubkeyHex,
          jsonEncode(privateTags),
        );
      }
    } else {
      // Add to the private list (dedup) + re-encrypt.
      if (!privateTags.any(
        (t) => t.length >= 2 && t[0] == 'e' && t[1] == eventId,
      )) {
        privateTags.add(['e', eventId]);
      }
      content = nip44Encrypt(
        id.privkeyHex,
        id.pubkeyHex,
        jsonEncode(privateTags),
      );
    }
    return id.signEvent(
      kind: 10003,
      content: content,
      tags: [...tags, _clientTag],
    );
  }

  /// Extract the bookmarked EVENT ids from a kind-10003 event: public `e`
  /// tags (plaintext, visible to anyone) +, when this is the logged-in user's
  /// own list, the private `e` tags decrypted from the NIP-44-encrypted
  /// `.content`. `a` (address) bookmarks are skipped — only note ids returned.
  /// Deduped, order-preserved. Returns empty for a null event.
  List<String> bookmarkIds(Event? e, {bool includePrivate = true}) {
    if (e == null) return const <String>[];
    final out = <String>[];
    final seen = <String>{};
    void add(String id) {
      if (seen.add(id)) out.add(id);
    }

    // Public e-tags.
    for (final t in e.tags) {
      if (t.length >= 2 && t[0] == 'e' && t[1] is String) {
        add(t[1] as String);
      }
    }

    // Private entries (only decryptable for the owner — needs the privkey).
    if (includePrivate && e.content.isNotEmpty) {
      try {
        final decoded = nip44Decrypt(id.privkeyHex, id.pubkeyHex, e.content);
        final arr = jsonDecode(decoded);
        if (arr is List) {
          for (final t in arr) {
            if (t is List && t.length >= 2 && t[0] == 'e' && t[1] is String) {
              add(t[1] as String);
            }
          }
        }
      } catch (_) {
        // Not the owner (can't decrypt) or malformed — ignore.
      }
    }
    return out;
  }

  /// Same as [bookmarkIds] but tags each id with its origin (public `e` tag vs
  /// private NIP-44-encrypted entry) so the 收藏 tab can render public/private
  /// sections separately. Deduped across both lists (a public id wins if it
  /// appears in both); order-preserved (public first, then private). Returns
  /// empty for a null event.
  List<BookmarkEntry> bookmarkEntries(Event? e, {bool includePrivate = true}) {
    if (e == null) return const <BookmarkEntry>[];
    final out = <BookmarkEntry>[];
    final seen = <String>{};
    void add(String id, bool public) {
      if (seen.add(id)) out.add(BookmarkEntry(id: id, public: public));
    }

    // Public e-tags.
    for (final t in e.tags) {
      if (t.length >= 2 && t[0] == 'e' && t[1] is String) {
        add(t[1] as String, true);
      }
    }

    // Private entries (only decryptable for the owner — needs the privkey).
    if (includePrivate && e.content.isNotEmpty) {
      try {
        final decoded = nip44Decrypt(id.privkeyHex, id.pubkeyHex, e.content);
        final arr = jsonDecode(decoded);
        if (arr is List) {
          for (final t in arr) {
            if (t is List && t.length >= 2 && t[0] == 'e' && t[1] is String) {
              add(t[1] as String, false);
            }
          }
        }
      } catch (_) {
        // Not the owner (can't decrypt) or malformed — ignore.
      }
    }
    return out;
  }

  /// Build/modify the user's NIP-51 kind-10000 mute list. **Amethyst stores
  /// public mutes as plain tags** (`p` user, `word` word, `t` hashtag, `e`
  /// event) **and private mutes as the same tag shape NIP-44-encrypted in
  /// `.content`** (a `[["p",…],["word",…]]` JSON array, owner-only). Costr
  /// matches this exactly so mute lists interoperate both ways. [entry] is
  /// the tag to add/remove (e.g. `['p', pubkey]`, `['word', 'spam']`,
  /// `['t', 'nsfw']`). [publicList]: public tag vs NIP-44-private. [add]:
  /// add vs remove.
  Event muteList(
    Event? current, {
    required MuteEntry entry,
    required bool add,
    required bool publicList,
  }) {
    final publicTags = <List<String>>[];
    final privateTags = <List<String>>[];
    if (current != null) {
      for (final t in current.tags) {
        if (t.isEmpty) continue;
        final name = t[0].toString();
        if (name == 'p' || name == 'word' || name == 't' || name == 'e') {
          publicTags.add(t.map((e) => e.toString()).toList());
        }
      }
      if (current.content.isNotEmpty) {
        try {
          final decoded = nip44Decrypt(
            id.privkeyHex,
            id.pubkeyHex,
            current.content,
          );
          final arr = jsonDecode(decoded);
          if (arr is List) {
            for (final t in arr) {
              if (t is List) {
                privateTags.add(t.map((e) => e.toString()).toList());
              }
            }
          }
        } catch (_) {
          // Malformed/undecryptable — start fresh private list.
        }
      }
    }
    final target = publicList ? publicTags : privateTags;
    bool eq(List<String> a, List<String> b) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (a[i] != b[i]) return false;
      }
      return true;
    }
    if (add) {
      if (!target.any((t) => eq(t, entry))) target.add(entry);
    } else {
      target.removeWhere((t) => eq(t, entry));
    }
    final content = privateTags.isEmpty
        ? ''
        : nip44Encrypt(id.privkeyHex, id.pubkeyHex, jsonEncode(privateTags));
    return id.signEvent(
      kind: 10000,
      content: content,
      tags: [...publicTags, _clientTag],
    );
  }

  /// Parse a kind-10000 mute list into a [MuteSet]: public `p`/`word`/`t`/`e`
  /// tags + NIP-44-decrypted private entries (owner-only — needs the privkey;
  /// non-owners get only the public entries). Empty for a null event.
  MuteSet muteSetOf(Event? e, {bool includePrivate = true}) {
    final pubkeys = <String>{};
    final words = <String>{};
    final hashtags = <String>{};
    final eventIds = <String>{};
    void addTag(List<String> t) {
      if (t.length < 2) return;
      switch (t[0]) {
        case 'p':
          pubkeys.add(t[1]);
        case 'word':
          words.add(t[1]);
        case 't':
          hashtags.add(t[1].toLowerCase());
        case 'e':
          eventIds.add(t[1]);
      }
    }

    if (e != null) {
      for (final t in e.tags) {
        if (t.isEmpty) continue;
        addTag(t.map((x) => x.toString()).toList());
      }
      if (includePrivate && e.content.isNotEmpty) {
        try {
          final decoded = nip44Decrypt(id.privkeyHex, id.pubkeyHex, e.content);
          final arr = jsonDecode(decoded);
          if (arr is List) {
            for (final t in arr) {
              if (t is List) addTag(t.map((x) => x.toString()).toList());
            }
          }
        } catch (_) {
          // Not the owner or malformed — public entries only.
        }
      }
    }
    return MuteSet(
      pubkeys: pubkeys,
      words: words,
      hashtags: hashtags,
      eventIds: eventIds,
    );
  }
}
