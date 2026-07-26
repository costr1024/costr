/// NIP-01/NIP-19 identity: holds a private/public key pair and exposes
/// signature verification (hook; disabled by default in v1).
///
/// The private key never leaves this object + secure storage + the bech32
/// decode path. v1 does not sign/publish, so the nsec is not exposed over the
/// wire. `toString()` redacts the private key so it never appears in logs or
/// error reports.
library;

import 'package:bip340/bip340.dart' as bip340;
import 'package:flutter/foundation.dart';

import '../utils/nip19.dart';

@immutable
class Identity {
  const Identity({
    required this.privkeyHex,
    required this.pubkeyHex,
    required this.nsec,
    required this.npub,
  });

  /// Build from a 64-char lowercase hex private key (32 bytes).
  factory Identity.fromPrivkeyHex(String privkeyHex) {
    final cleaned = privkeyHex.toLowerCase();
    if (cleaned.length != 64 || !RegExp(r'^[0-9a-f]+$').hasMatch(cleaned)) {
      throw FormatException(
        'private key must be 64 lowercase hex chars, got length ${cleaned.length}',
      );
    }
    final pubkey = bip340.getPublicKey(cleaned);
    return Identity(
      privkeyHex: cleaned,
      pubkeyHex: pubkey,
      nsec: hexToNsec(cleaned),
      npub: hexToNpub(pubkey),
    );
  }

  /// Build from an `nsec1...` (NIP-19) bech32 private key.
  factory Identity.fromNsec(String nsec) {
    if (!nsec.toLowerCase().startsWith('nsec1')) {
      throw FormatException('not an nsec1 string');
    }
    return Identity.fromPrivkeyHex(nsecToHex(nsec));
  }

  final String privkeyHex;
  final String pubkeyHex;
  final String nsec;
  final String npub;

  /// Verify a NIP-01 event signature against this identity's pubkey.
  /// `id` is the event id (hex sha256), `sig` is the 128-char hex signature.
  /// Hook for v1 — arrival verification is OFF for perf; available for later.
  bool verifyEventSignature({required String id, required String sig}) {
    try {
      return bip340.verify(pubkeyHex, id, sig);
    } catch (_) {
      return false;
    }
  }

  /// Equality by pubkey (the identity is the key pair; privkey is unique).
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Identity && other.pubkeyHex == pubkeyHex);

  @override
  int get hashCode => pubkeyHex.hashCode;

  @override
  String toString() => 'Identity(npub: $npub, privkey: <redacted>)';
}
