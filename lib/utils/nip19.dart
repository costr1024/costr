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

/// Decode an `nprofile1...` (NIP-19) to the 32-byte pubkey hex. The nprofile
/// payload is TLV: [type, length, value...] repeating; type 0x00 is the
/// pubkey (32 bytes). Relays (type 0x01) and petname (0x02) are ignored.
/// Returns null if the string isn't a valid nprofile or has no pubkey TLV.
String? nprofileToPubkeyHex(String nprofile) {
  if (!nprofile.toLowerCase().startsWith('nprofile1')) return null;
  final bytes = decodeBech32(nprofile).data;
  int i = 0;
  while (i + 2 <= bytes.length) {
    final type = bytes[i];
    final len = bytes[i + 1];
    if (i + 2 + len > bytes.length) break;
    final value = bytes.sublist(i + 2, i + 2 + len);
    if (type == 0 && len == 32) {
      return _bytesToHex(value);
    }
    i += 2 + len;
  }
  return null;
}

/// Decode any NIP-19 pubkey entity (`npub1` or `nprofile1`) to pubkey hex.
/// Returns null for non-pubkey entities (note1) or invalid input.
String? entityToPubkeyHex(String entity) {
  final l = entity.toLowerCase();
  if (l.startsWith('npub1')) return npubToHex(entity);
  if (l.startsWith('nprofile1')) return nprofileToPubkeyHex(entity);
  return null;
}

/// Encode a 32-byte pubkey hex as `nprofile1...` (NIP-19, TLV type 0x00).
String hexToNprofile(String pubkeyHex) {
  final pubkeyBytes = _hexToBytes(pubkeyHex);
  final tlv = <int>[0x00, 0x20, ...pubkeyBytes];
  return encodeBech32('nprofile', tlv);
}

/// Shorten an `npub1...`/`nsec1...` for display: first 8 + … + last 4.
String shortenEntity(String entity) {
  if (entity.length <= 16) return entity;
  return '${entity.substring(0, 8)}…${entity.substring(entity.length - 4)}';
}
