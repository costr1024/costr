/// NIP-01 Event model.
///
/// Represents a Nostr event as defined in https://github.com/nostr-protocol/nips/blob/master/01.md
/// Minimal parsing/serialization only — signing and validation land with the
/// first real feature.
library;

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

  /// Parse a NIP-01 event JSON array: [id, pubkey, created_at, kind, tags, content, sig]
  factory Event.fromList(List<dynamic> list) {
    return Event(
      id: list[0] as String,
      pubkey: list[1] as String,
      createdAt: (list[2] as num).toInt(),
      kind: (list[3] as num).toInt(),
      tags: (list[4] as List).cast<List<dynamic>>(),
      content: list[5] as String,
      sig: list[6] as String,
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

  bool get isTextNote => kind == kindTextNote;

  String get _preview =>
      content.length <= 40 ? content : '${content.substring(0, 40)}…';

  @override
  String toString() => 'Event(kind=$kind, id=$id, content=$_preview)';
}
