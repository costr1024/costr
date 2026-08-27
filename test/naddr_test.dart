import 'dart:convert';

import 'package:costr/utils/bech32_codec.dart';
import 'package:costr/utils/nip19.dart';
import 'package:flutter_test/flutter_test.dart';

/// Build a real `naddr1…` string from its parts (NIP-19 TLV: 0=d, 1=relay,
/// 2=author, 3=kind big-endian) so the decoder is tested against true
/// wire-format entities, not hand-typed approximations.
String _encodeNaddr({
  required String d,
  required List<String> relays,
  required String pubkeyHex,
  required int kind,
  bool omitKind = false,
}) {
  final tlv = <int>[];
  final dBytes = utf8.encode(d);
  tlv.addAll([0, dBytes.length, ...dBytes]);
  for (final r in relays) {
    final rb = utf8.encode(r);
    tlv.addAll([1, rb.length, ...rb]);
  }
  final pk = <int>[
    for (var i = 0; i < 64; i += 2)
      int.parse(pubkeyHex.substring(i, i + 2), radix: 16),
  ];
  tlv.addAll([2, 32, ...pk]);
  if (!omitKind) {
    tlv.addAll([
      3,
      4,
      (kind >> 24) & 0xff,
      (kind >> 16) & 0xff,
      (kind >> 8) & 0xff,
      kind & 0xff,
    ]);
  }
  return encodeBech32('naddr', tlv);
}

void main() {
  const pubkey =
      '7ea9ed1c3ffb4ebac097c392be6ca99df924be37966611b3d6e7255527834dd2';

  group('naddrDecode', () {
    test('decodes kind/author/d/relay hints', () {
      final naddr = _encodeNaddr(
        d: 'my-article',
        relays: ['wss://relay.example'],
        pubkeyHex: pubkey,
        kind: 30023,
      );
      final a = naddrDecode(naddr);
      expect(a, isNotNull);
      expect(a!.kind, 30023);
      expect(a.pubkey, pubkey);
      expect(a.d, 'my-article');
      expect(a.relays, ['wss://relay.example']);
    });

    test('accepts the nostr: prefix (NIP-27 in-content form)', () {
      final naddr = _encodeNaddr(
        d: 'x',
        relays: const [],
        pubkeyHex: pubkey,
        kind: 30023,
      );
      expect(naddrDecode('nostr:$naddr')!.d, 'x');
    });

    test('multiple relay hints keep their order', () {
      final naddr = _encodeNaddr(
        d: 'x',
        relays: const ['wss://a.example', 'wss://b.example'],
        pubkeyHex: pubkey,
        kind: 30023,
      );
      expect(naddrDecode(naddr)!.relays, [
        'wss://a.example',
        'wss://b.example',
      ]);
    });

    test('large kinds decode as 4-byte big-endian (no varint drift)', () {
      final naddr = _encodeNaddr(
        d: 'x',
        relays: const [],
        pubkeyHex: pubkey,
        kind: 31989,
      );
      expect(naddrDecode(naddr)!.kind, 31989);
    });

    test('rejects non-naddr entities', () {
      expect(naddrDecode('npub1abc'), isNull);
      expect(naddrDecode('nevent1abc'), isNull);
    });

    test('rejects malformed bech32 without throwing', () {
      expect(naddrDecode('naddr1qqqqqqq'), isNull);
      expect(naddrDecode('naddr1not-bech32!!'), isNull);
    });

    test('rejects an incomplete coordinate (missing kind)', () {
      final naddr = _encodeNaddr(
        d: 'x',
        relays: const [],
        pubkeyHex: pubkey,
        kind: 30023,
        omitKind: true,
      );
      expect(naddrDecode(naddr), isNull);
    });

    test('rejects an empty d identifier', () {
      final naddr = _encodeNaddr(
        d: '',
        relays: const [],
        pubkeyHex: pubkey,
        kind: 30023,
      );
      expect(naddrDecode(naddr), isNull);
    });
  });
}
