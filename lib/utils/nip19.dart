/// NIP-19 — bech32 entity encodings for Nostr.
///
/// Wraps [encodeBech32]/[decodeBech32] for the NIP-19 hrps:
/// `nsec1` (private key, 32 bytes), `npub1` (public key, 32 bytes),
/// `note1` (event id, 32 bytes), `nevent1` (event id + relay/author hints),
/// `nprofile1` (pubkey + relay hints).
///
/// See https://github.com/nostr-protocol/nips/blob/master/19.md
library;

import 'dart:convert';

import 'package:hex/hex.dart';

import 'bech32_codec.dart';

/// Decode a hex string to bytes via the `hex` package.
List<int> _hexToBytes(String hex) => HEX.decode(hex);

String _bytesToHex(List<int> bytes) => HEX.encode(bytes);

/// Encode a 32-byte private key (hex) as `nsec1...`.
String hexToNsec(String privkeyHex) =>
    encodeBech32('nsec', _hexToBytes(privkeyHex));

/// Decode an `nsec1...` string to a hex private key.
String nsecToHex(String nsec) => _bytesToHex(decodeBech32(nsec).data);

/// Encode a 32-byte public key (hex, x-only) as `npub1...`.
String hexToNpub(String pubkeyHex) =>
    encodeBech32('npub', _hexToBytes(pubkeyHex));

/// Decode an `npub1...` string to a hex public key.
String npubToHex(String npub) => _bytesToHex(decodeBech32(npub).data);

/// Encode a 32-byte event id (hex) as `note1...`.
String hexToNote(String idHex) => encodeBech32('note', _hexToBytes(idHex));

/// Decode a `note1...` string to a hex event id.
String noteToHex(String note) => _bytesToHex(decodeBech32(note).data);

/// Decoded `nprofile1...` parts (NIP-19).
class Nprofile {
  const Nprofile({this.pubkey, this.relays = const []});
  final String? pubkey; // 32-byte hex pubkey
  final List<String> relays; // relay hints (where to find this user's events)
}

/// Decode an `nprofile1...` to its pubkey + relay hints. Accepts an optional
/// `nostr:` prefix. Returns null if not an nprofile, has no pubkey TLV, or
/// the bech32 is malformed (junk like `nprofile1abc…` must not throw — these
/// decoders run on untrusted post content during widget build).
/// Relay hints (TLV type 0x01) are the URLs where this user publishes their
/// events (NIP-65 outbox model) — preserve them so callers can DIRECT REQs
/// at the user's own relays instead of broadcasting.
Nprofile? nprofileDecode(String nprofile) {
  var e = nprofile;
  if (e.toLowerCase().startsWith('nostr:')) e = e.substring(6);
  if (!e.toLowerCase().startsWith('nprofile1')) return null;
  final List<int> bytes;
  try {
    bytes = decodeBech32(e).data;
  } on Bech32Exception {
    return null; // malformed bech32 — treat as "not an nprofile"
  }
  int i = 0;
  String? pubkey;
  final relays = <String>[];
  while (i + 2 <= bytes.length) {
    final type = bytes[i];
    final len = bytes[i + 1];
    if (i + 2 + len > bytes.length) break;
    final value = bytes.sublist(i + 2, i + 2 + len);
    if (type == 0 && len == 32) {
      pubkey = _bytesToHex(value);
    } else if (type == 1) {
      relays.add(utf8.decode(value));
    }
    i += 2 + len;
  }
  if (pubkey == null) return null;
  return Nprofile(pubkey: pubkey, relays: relays);
}

/// Decode an `nprofile1...` (NIP-19) to the 32-byte pubkey hex. The nprofile
/// payload is TLV: [type, length, value...] repeating; type 0x00 is the
/// pubkey (32 bytes). Relay hints (type 0x01) are decoded by [nprofileDecode]
/// but not returned here — use it directly when you need the relay hints.
/// Returns null if the string isn't a valid nprofile or has no pubkey TLV.
String? nprofileToPubkeyHex(String nprofile) =>
    nprofileDecode(nprofile)?.pubkey;

/// Decode any NIP-19 pubkey entity (`npub1` or `nprofile1`) to pubkey hex.
/// Strips an optional `nostr:` prefix (mentions in post content are often
/// written as `nostr:npub1…` / `nostr:nprofile1…`, per NIP-27). Returns null
/// for non-pubkey entities (note1) or invalid input — including malformed
/// bech32 (the entity regex matches any bech32-charset run, so junk like
/// `npub1qqqqqq` reaches here; throwing would crash the render path).
String? entityToPubkeyHex(String entity) {
  var e = entity;
  if (e.toLowerCase().startsWith('nostr:')) e = e.substring(6);
  final l = e.toLowerCase();
  try {
    if (l.startsWith('npub1')) return npubToHex(e);
    if (l.startsWith('nprofile1')) return nprofileToPubkeyHex(e);
  } on Bech32Exception {
    return null;
  }
  return null;
}

/// Encode a 32-byte pubkey hex as `nprofile1...` (NIP-19). Carries the pubkey
/// as TLV type 0x00 and, when [relays] is non-empty, one TLV type 0x01 record
/// per relay URL (NIP-65 outbox hints). The decode side (`nprofileDecode`)
/// already reads type-0x01 relays, so this round-trips. Mirrors the nprofile
/// Amethyst publishes for @-mentions.
String hexToNprofile(String pubkeyHex, {List<String> relays = const []}) {
  final pubkeyBytes = _hexToBytes(pubkeyHex);
  final tlv = <int>[..._tlv(0x00, pubkeyBytes)];
  for (final r in relays) {
    if (r.isNotEmpty) tlv.addAll(_tlv(0x01, utf8.encode(r)));
  }
  return encodeBech32('nprofile', tlv);
}

/// Encode a TLV record: [type, length, ...value].
List<int> _tlv(int type, List<int> value) => [type, value.length, ...value];

/// Unsigned LEB128 varint (used for the kind TLV in nevent).
List<int> _encodeVarint(int v) {
  final out = <int>[];
  do {
    var b = v & 0x7f;
    v >>= 7;
    if (v != 0) b |= 0x80;
    out.add(b);
  } while (v != 0);
  return out;
}

int _decodeVarint(List<int> bytes) {
  var result = 0;
  var shift = 0;
  for (final b in bytes) {
    result |= (b & 0x7f) << shift;
    if ((b & 0x80) == 0) break;
    shift += 7;
  }
  return result;
}

/// Encode an event id (hex) + optional relay hint + author pubkey + kind as
/// `nevent1...` (NIP-19). The relay + author hints let other clients fetch
/// the event even when their usual relays don't have it (outbox model).
String hexToNevent(
  String idHex, {
  List<String> relays = const [],
  String? authorHex,
  int? kind,
}) {
  final idBytes = _hexToBytes(idHex);
  final tlv = <int>[..._tlv(0x00, idBytes)];
  for (final r in relays) {
    if (r.isNotEmpty) tlv.addAll(_tlv(0x01, utf8.encode(r)));
  }
  if (authorHex != null && authorHex.isNotEmpty) {
    tlv.addAll(_tlv(0x02, _hexToBytes(authorHex)));
  }
  if (kind != null) tlv.addAll(_tlv(0x03, _encodeVarint(kind)));
  return encodeBech32('nevent', tlv);
}

/// Decoded `nevent1...` parts (NIP-19).
class Nevent {
  const Nevent({this.id, this.relays = const [], this.author, this.kind});
  final String? id; // hex event id
  final List<String> relays;
  final String? author; // hex author pubkey
  final int? kind;
}

/// Decode an `nevent1...` (NIP-19) to its parts. Accepts an optional
/// `nostr:` prefix. Returns null if not a nevent, has no id TLV, or the
/// bech32 is malformed (these decoders run on untrusted post content during
/// widget build — junk must yield null, not throw).
Nevent? neventDecode(String nevent) {
  var e = nevent;
  if (e.toLowerCase().startsWith('nostr:')) e = e.substring(6);
  if (!e.toLowerCase().startsWith('nevent1')) return null;
  final List<int> bytes;
  try {
    bytes = decodeBech32(e).data;
  } on Bech32Exception {
    return null; // malformed bech32 — treat as "not an nevent"
  }
  int i = 0;
  String? id;
  final relays = <String>[];
  String? author;
  int? kind;
  while (i + 2 <= bytes.length) {
    final type = bytes[i];
    final len = bytes[i + 1];
    if (i + 2 + len > bytes.length) break;
    final value = bytes.sublist(i + 2, i + 2 + len);
    switch (type) {
      case 0x00:
        if (len == 32) id = _bytesToHex(value);
      case 0x01:
        relays.add(utf8.decode(value));
      case 0x02:
        if (len == 32) author = _bytesToHex(value);
      case 0x03:
        kind = _decodeVarint(value);
    }
    i += 2 + len;
  }
  if (id == null) return null;
  return Nevent(id: id, relays: relays, author: author, kind: kind);
}

/// Decode any NIP-19 event entity (`nevent1` or `note1`, optionally with
/// `nostr:` prefix) to the hex event id. Returns null for non-event entities
/// or invalid input — including malformed bech32 (see [entityToPubkeyHex]).
String? entityToEventIdHex(String entity) {
  var e = entity;
  if (e.toLowerCase().startsWith('nostr:')) e = e.substring(6);
  final l = e.toLowerCase();
  try {
    if (l.startsWith('nevent1')) return neventDecode(e)?.id;
    if (l.startsWith('note1')) return noteToHex(e);
  } on Bech32Exception {
    return null;
  }
  return null;
}

/// Shorten an `npub1...`/`nsec1...` for display: first 8 + … + last 4.
String shortenEntity(String entity) {
  if (entity.length <= 16) return entity;
  return '${entity.substring(0, 8)}…${entity.substring(entity.length - 4)}';
}

/// Matches a bare http(s) URL (up to the next whitespace). Used to keep
/// NIP-19 entity matching from reaching INSIDE URLs.
final RegExp _urlRegex = RegExp(r'https?://[^\s]+');

/// True when match [m] falls inside a `https?://…` URL in [text].
///
/// NIP-19 entities embedded in URLs must NOT be linkified/stripped: blossom
/// servers serve media under the uploader's npub as a subdomain
/// (`https://npub1….blossom.band/<sha256>.mp4`), and rewriting the npub part
/// into an `[@name](nostr:…)` mention breaks the URL — the mention shows up
/// as stray `@npub…` text and the media fails to load.
bool entityMatchInUrl(String text, Match m) => rangeInUrl(text, m.start, m.end);

/// True when the range [start, end) lies entirely inside a single
/// `https?://…` URL in [text]. Offset-based variant of [entityMatchInUrl]
/// for callers (e.g. the composer's special-text builder) that track an
/// absolute start offset rather than holding a [Match] over the full text.
bool rangeInUrl(String text, int start, int end) {
  for (final u in _urlRegex.allMatches(text)) {
    if (start >= u.start && end <= u.end) return true;
    if (u.start > end) break; // both sequences are start-ordered
  }
  return false;
}
