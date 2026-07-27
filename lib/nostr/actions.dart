/// High-level Nostr actions (reply / reaction / repost / quote / follow) that
/// build the right NIP-10/18/25/30/02 tags, sign, and (via the caller) publish.
/// All reuse Identity.signEvent; the caller runs RelayPool.publishAndWait.
library;

import 'dart:convert';

import '../models/event.dart';
import '../utils/nip19.dart';
import 'identity.dart';

class NostrActions {
  NostrActions(this.id);
  final Identity id;

  /// Reply to [parent] (NIP-10). Includes a root marker (the thread root,
  /// computed from the parent's tags) and a reply marker (the parent), plus a
  /// `p` tag for the parent's author.
  Event reply(Event parent, String content) {
    final rootId = parent.rootEventId;
    final tags = <List<String>>[
      ['e', rootId, '', 'root'],
      ['e', parent.id, '', 'reply'],
      ['p', parent.pubkey, ''],
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

  /// Quote (kind-1 referencing [quoted]). The user's [content] is followed by a
  /// `nostr:note1…` reference; an `e` mention tag + `p` tag reference the quote.
  Event quote(Event quoted, String content) {
    final ref = 'nostr:${hexToNote(quoted.id)}';
    final full = content.isEmpty ? ref : '$content\n\n$ref';
    final tags = <List<String>>[
      ['e', quoted.id, '', 'mention'],
      ['p', quoted.pubkey, ''],
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
}
