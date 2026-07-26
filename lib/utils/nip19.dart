/// NIP-19 — bech32 entity encodings for Nostr.
///
/// Wraps [encodeBech32]/[decodeBech32] for the NIP-19 hrps:
/// `nsec1` (private key, 32 bytes), `npub1` (public key, 32 bytes),
/// `note1` (event id, 32 bytes).
///
/// See https://github.com/nostr-protocol/nips/blob/master/19.md
library;

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

/// Shorten an `npub1...`/`nsec1...` for display: first 8 + … + last 4.
String shortenEntity(String entity) {
  if (entity.length <= 16) return entity;
  return '${entity.substring(0, 8)}…${entity.substring(entity.length - 4)}';
}
