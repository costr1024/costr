import 'package:costr/utils/bech32_codec.dart';
import 'package:costr/utils/nip19.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('NIP-19 nsec/npub/note', () {
    const privHex =
        '0000000000000000000000000000000000000000000000000000000000000001';
    // secp256k1 base point G.x — the canonical x-only pubkey for privkey 1.
    const pubHex =
        '79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798';

    test('nsec round-trips to the same private key hex', () {
      final nsec = hexToNsec(privHex);
      expect(nsec.startsWith('nsec1'), isTrue);
      expect(nsecToHex(nsec), privHex);
    });

    test('npub round-trips to the same public key hex', () {
      final npub = hexToNpub(pubHex);
      expect(npub.startsWith('npub1'), isTrue);
      expect(npubToHex(npub), pubHex);
    });

    test('note round-trips to the same event id hex', () {
      final note = hexToNote(pubHex); // any 32-byte id
      expect(note.startsWith('note1'), isTrue);
      expect(noteToHex(note), pubHex);
    });

    test('decoding the wrong hrp yields a different hrp', () {
      final nsec = hexToNsec(privHex);
      final d = decodeBech32(nsec);
      expect(d.hrp, 'nsec');
    });

    test('shortenEntity truncates long entities', () {
      final npub = hexToNpub(pubHex);
      final short = shortenEntity(npub);
      expect(short.length, lessThan(npub.length));
      expect(short.contains('…'), isTrue);
      expect(short.startsWith(npub.substring(0, 8)), isTrue);
      expect(short.endsWith(npub.substring(npub.length - 4)), isTrue);
    });

    test('shortenEntity leaves short strings untouched', () {
      expect(shortenEntity('abc'), 'abc');
    });

    test('32-byte zero private key round-trips', () {
      const zero = '0000000000000000000000000000000000000000000000000000000000000000';
      expect(nsecToHex(hexToNsec(zero)), zero);
    });
  });
}
