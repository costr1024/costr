import 'dart:convert';

import 'package:bip340/bip340.dart' as bip340;
import 'package:costr/utils/nip44.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const sec1 =
      '0000000000000000000000000000000000000000000000000000000000000001';
  const sec2 =
      '0000000000000000000000000000000000000000000000000000000000000002';
  final pub1 = bip340.getPublicKey(sec1);
  final pub2 = bip340.getPublicKey(sec2);

  group('NIP-44', () {
    test('official vector: decrypt(sec2, pub1, payload) == "a"', () {
      const payload =
          'AgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABee0G5VSK0/9YypIObAtDKfYEAjD35uVkHyB0F4DwrcNaCXlCWZKaArsGrY6M9wnuTMxWfp1RTN9Xga8no+kF5Vsb';
      expect(nip44Decrypt(sec2, pub1, payload), 'a');
    });

    test('encrypt -> decrypt round-trip (random nonce)', () {
      const msg = 'hello costr 私密书签 🔥';
      final payload = nip44Encrypt(sec1, pub2, msg);
      expect(nip44Decrypt(sec2, pub1, payload), msg);
    });

    test('round-trip with longer text (multi-block padding)', () {
      final msg = 'x' * 200;
      final payload = nip44Encrypt(sec1, pub2, msg);
      expect(nip44Decrypt(sec2, pub1, payload), msg);
    });

    test('tampered mac rejected', () {
      final payload = nip44Encrypt(sec1, pub2, 'secret');
      final bytes = base64.decode(payload).toList();
      bytes[bytes.length - 1] ^= 0x01;
      final tampered = base64.encode(bytes);
      expect(
        () => nip44Decrypt(sec2, pub1, tampered),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
