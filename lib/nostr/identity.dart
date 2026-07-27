/// NIP-01/NIP-19 identity: holds a private/public key pair and exposes
/// signature verification (hook; disabled by default in v1).
///
/// The private key never leaves this object + secure storage + the bech32
/// decode path. v1 does not sign/publish, so the nsec is not exposed over the
/// wire. `toString()` redacts the private key so it never appears in logs or
/// error reports.
library;

import 'dart:math';

import 'package:bip340/bip340.dart' as bip340;
import 'package:flutter/foundation.dart';
import 'package:hex/hex.dart';

import '../models/event.dart';
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

  /// Sign a NIP-01 event. Builds the canonical id (sha256 of
  /// `[0, pubkey, created_at, kind, tags, content]`), signs it with the
  /// private key (BIP-340, secure-random aux), and returns the signed Event.
  /// [createdAt] defaults to now (unix seconds).
  Event signEvent({
    required int kind,
    required String content,
    List<List<String>> tags = const [],
    int? createdAt,
  }) {
    final ts = createdAt ??
        (DateTime.now().millisecondsSinceEpoch ~/ 1000);
    final wireTags = tags
        .map((t) => t.map((e) => e as dynamic).toList())
        .toList(growable: false);
    final unsigned = Event(
      id: '',
      pubkey: pubkeyHex,
      createdAt: ts,
      kind: kind,
      tags: wireTags,
      content: content,
      sig: '',
    );
    final id = unsigned.computeId();
    final aux = _secureRandomHex32();
    final sig = bip340.sign(privkeyHex, id, aux);
    return Event(
      id: id,
      pubkey: pubkeyHex,
      createdAt: ts,
      kind: kind,
      tags: wireTags,
      content: content,
      sig: sig,
    );
  }

  static String _secureRandomHex32() {
    final r = Random.secure();
    final bytes = List<int>.generate(32, (_) => r.nextInt(256));
    return HEX.encode(bytes);
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
