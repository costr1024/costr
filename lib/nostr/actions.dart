/// High-level Nostr actions (reply / reaction / repost / quote / follow) that
/// build the right NIP-10/18/25/30/02 tags, sign, and (via the caller) publish.
/// All reuse Identity.signEvent; the caller runs RelayPool.publishAndWait.
library;

import 'dart:convert';

import '../models/event.dart';
import '../utils/nip19.dart';
import '../utils/nip44.dart';
import 'identity.dart';

class NostrActions {
  NostrActions(this.id);
  final Identity id;

  /// Reply to [parent] (NIP-10). Includes a root marker (the thread root,
  /// computed from the parent's tags) and a reply marker (the parent), plus a
  /// `p` tag for the parent's author. [extraTags] (e.g. imeta for attachments)
  /// are appended.
  Event reply(Event parent, String content, {List<List<String>> extraTags = const []}) {
    final rootId = parent.rootEventId;
    final tags = <List<String>>[
      ['e', rootId, '', 'root'],
      ['e', parent.id, '', 'reply'],
      ['p', parent.pubkey, ''],
      ...extraTags,
    ];
    return id.signEvent(kind: 1, content: content, tags: tags);
  }

  /// Reaction (NIP-25 kind 7). [content] is the emoji (unicode), "+" for a
  /// simple like, or ":shortcode:" for a custom-emoji reaction. When
  /// [customShortcode]+[customUrl] are set, a NIP-30 `emoji` tag is added.
  Event reaction(
    Event target,
    String content, {
    String? customShortcode,
    String? customUrl,
  }) {
    final tags = <List<String>>[
      ['e', target.id, '', target.pubkey],
      ['p', target.pubkey, ''],
      ['k', '${target.kind}'],
    ];
    if (customShortcode != null && customUrl != null) {
      tags.add(['emoji', customShortcode, customUrl]);
    }
    return id.signEvent(kind: 7, content: content, tags: tags);
  }

  /// Repost (NIP-18 kind 6). content = the stringified JSON of the reposted
  /// event; tags reference it.
  Event repost(Event target) {
    final tags = <List<String>>[
      ['e', target.id, ''],
      ['p', target.pubkey, ''],
    ];
    return id.signEvent(
      kind: 6,
      content: jsonEncode(target.toWireObject()),
      tags: tags,
    );
  }

  /// Add [pubkey] to a NIP-51 kind-30000 categorized people list (Follow set)
  /// with `d`=[category]. [current] is the existing kind-30000 event for that
  /// category (or null for a new list). Preserves existing p-tags.
  Event followCategory(Event? current, String pubkey, String category, {String relay = ''}) {
    final tags = <List<String>>[
      ['d', category],
    ];
    final seen = <String>{};
    if (current != null) {
      for (final t in current.tags) {
        if (t.length < 2 || t[0] != 'p' || t[1] is! String) continue;
        final pk = t[1] as String;
        if (pk == pubkey) continue;
        final r = (t.length >= 3 && t[2] is String) ? (t[2] as String) : '';
        tags.add(['p', pk, r]);
        seen.add(pk);
      }
    }
    if (seen.add(pubkey)) {
      tags.add(['p', pubkey, relay]);
    }
    return id.signEvent(kind: 30000, content: '', tags: tags);
  }

  /// Publish updated profile metadata (NIP-01 kind 0). [contentJson] is the
  /// stringified JSON of the metadata object.
  Event setMetadata(String contentJson) {
    return id.signEvent(kind: 0, content: contentJson, tags: const []);
  }

  /// Quote (kind-1 referencing [quoted]). The user's [content] is followed by a
  /// `nostr:note1…` reference; an `e` mention tag + `p` tag reference the quote.
  /// [extraTags] (e.g. imeta) are appended.
  Event quote(Event quoted, String content, {List<List<String>> extraTags = const []}) {
    final ref = 'nostr:${hexToNote(quoted.id)}';
    final full = content.isEmpty ? ref : '$content\n\n$ref';
    final tags = <List<String>>[
      ['e', quoted.id, '', 'mention'],
      ['p', quoted.pubkey, ''],
      ...extraTags,
    ];
    return id.signEvent(kind: 1, content: full, tags: tags);
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
        final petname = (t.length >= 4 && t[3] is String) ? (t[3] as String) : '';
        tags.add(petname.isEmpty ? ['p', pk, r] : ['p', pk, r, petname]);
        seen.add(pk);
      }
    }
    if (seen.add(newPubkey)) {
      tags.add(['p', newPubkey, relay]);
    }
    return id.signEvent(kind: 3, content: '', tags: tags);
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
        final decoded =
            nip44Decrypt(id.privkeyHex, id.pubkeyHex, current.content);
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
        content =
            nip44Encrypt(id.privkeyHex, id.pubkeyHex, jsonEncode(privateTags));
      }
    } else {
      // Add to the private list (dedup) + re-encrypt.
      if (!privateTags
          .any((t) => t.length >= 2 && t[0] == 'e' && t[1] == eventId)) {
        privateTags.add(['e', eventId]);
      }
      content =
          nip44Encrypt(id.privkeyHex, id.pubkeyHex, jsonEncode(privateTags));
    }
    return id.signEvent(kind: 10003, content: content, tags: tags);
  }
}
