import 'package:bip340/bip340.dart' as bip340;
import 'package:costr/nostr/identity.dart';
import 'package:costr/utils/nip19.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // privkey = 1 → pubkey = secp256k1 base point G.x (canonical, public).
  const privHex =
      '0000000000000000000000000000000000000000000000000000000000000001';
  const expectedPub =
      '79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798';

  group('Identity', () {
    test('fromPrivkeyHex derives canonical G.x pubkey for privkey 1', () {
      final id = Identity.fromPrivkeyHex(privHex);
      expect(id.privkeyHex, privHex);
      expect(id.pubkeyHex, expectedPub);
      expect(id.nsec.startsWith('nsec1'), isTrue);
      expect(id.npub.startsWith('npub1'), isTrue);
    });

    test('fromNsec round-trips back to the same privkey and pubkey', () {
      final nsec = hexToNsec(privHex);
      final id = Identity.fromNsec(nsec);
      expect(id.nsec, nsec);
      expect(id.privkeyHex, privHex);
      expect(id.pubkeyHex, expectedPub);
    });

    test('fromNsec rejects non-nsec strings', () {
      expect(() => Identity.fromNsec('npub1abc'), throwsFormatException);
      expect(() => Identity.fromNsec('not-a-key'), throwsFormatException);
    });

    test('fromPrivkeyHex rejects bad-length / non-hex input', () {
      expect(() => Identity.fromPrivkeyHex('00'), throwsFormatException);
      expect(() => Identity.fromPrivkeyHex('g' * 64), throwsFormatException);
    });

    test('toString redacts the private key and nsec', () {
      final id = Identity.fromPrivkeyHex(privHex);
      final s = id.toString();
      expect(s.contains(privHex), isFalse);
      expect(s.contains(id.nsec), isFalse);
      expect(s.contains(id.npub), isTrue);
    });

    test('verifyEventSignature: sign+verify round-trip is true', () {
      final id = Identity.fromPrivkeyHex(privHex);
      final msg = '0' * 64; // 32-byte hex "event id"
      final aux = 'ab' * 32; // 32-byte random aux
      final sig = bip340.sign(id.privkeyHex, msg, aux);
      expect(sig.length, 128);
      expect(id.verifyEventSignature(id: msg, sig: sig), isTrue);
    });

    test('verifyEventSignature returns false for a tampered signature', () {
      final id = Identity.fromPrivkeyHex(privHex);
      final msg = '0' * 64;
      final sig = bip340.sign(id.privkeyHex, msg, 'cd' * 32);
      // Flip the last hex digit of the signature.
      final last = sig.substring(sig.length - 1);
      final alt = last == '0' ? '1' : '0';
      final bad = '${sig.substring(0, sig.length - 1)}$alt';
      expect(id.verifyEventSignature(id: msg, sig: bad), isFalse);
    });

    test('equality is by pubkey', () {
      final a = Identity.fromPrivkeyHex(privHex);
      final b = Identity.fromNsec(a.nsec);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('signEvent: id verifies and signature is valid', () {
      final id = Identity.fromPrivkeyHex(privHex);
      final signed = id.signEvent(
        kind: 1,
        content: 'hello costr',
        tags: const [
          ['t', 'nostr'],
        ],
        createdAt: 1700000000,
      );
      expect(signed.pubkey, id.pubkeyHex);
      expect(signed.kind, 1);
      expect(signed.content, 'hello costr');
      // id is the sha256 of the canonical serialization (not empty).
      expect(signed.id.length, 64);
      expect(signed.id, signed.computeId());
      expect(signed.sig.length, 128);
      // BIP-340 verify(pubkey, id, sig) == true.
      expect(id.verifyEventSignature(id: signed.id, sig: signed.sig), isTrue);
    });
  });
}
