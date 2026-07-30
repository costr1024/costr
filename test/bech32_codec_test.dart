import 'package:costr/utils/bech32_codec.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('encodeBech32 / decodeBech32', () {
    test('BIP-173 vector: A12UEL5L decodes to empty data', () {
      final d = decodeBech32('A12UEL5L');
      expect(d.hrp, 'a');
      expect(d.data, isEmpty);
    });

    test('BIP-173 vector: lowercase a12uel5l', () {
      final d = decodeBech32('a12uel5l');
      expect(d.hrp, 'a');
      expect(d.data, isEmpty);
    });

    test('BIP-173 vector: ?1ezyfcl', () {
      final d = decodeBech32('?1ezyfcl');
      expect(d.hrp, '?');
      expect(d.data, isEmpty);
    });

    test('BIP-173 vector: split1check... round-trips', () {
      const s = 'split1checkupstagehandshakeupstreamerranterredcaperred2y9e3w';
      final d = decodeBech32(s);
      expect(d.hrp, 'split');
      expect(encodeBech32(d.hrp, d.data), s);
    });

    test('BIP-173 vector: abcdef1qpzry9... round-trips', () {
      const s = 'abcdef1qpzry9x8gf2tvdw0s3jn54khce6mua7lmqqqxw';
      final d = decodeBech32(s);
      expect(d.hrp, 'abcdef');
      expect(encodeBech32(d.hrp, d.data), s);
    });

    test('32-byte all-zero payload round-trips', () {
      final bytes = List<int>.filled(32, 0);
      final enc = encodeBech32('npub', bytes);
      final d = decodeBech32(enc);
      expect(d.hrp, 'npub');
      expect(d.data, bytes);
    });

    test('32-byte all-0xFF payload round-trips', () {
      final bytes = List<int>.filled(32, 0xFF);
      final enc = encodeBech32('nsec', bytes);
      expect(decodeBech32(enc).data, bytes);
    });

    test('uppercase decodes same as lowercase', () {
      final lower = encodeBech32('npub', List<int>.filled(32, 1));
      final d = decodeBech32(lower.toUpperCase());
      expect(d.data, List<int>.filled(32, 1));
    });

    test('corrupted checksum is rejected', () {
      final enc = encodeBech32('npub', List<int>.filled(32, 0));
      // Flip the last character to a different charset char.
      final last = enc.substring(enc.length - 1);
      final nextChar = last == 'q' ? 'p' : 'q';
      final bad = '${enc.substring(0, enc.length - 1)}$nextChar';
      expect(() => decodeBech32(bad), throwsA(isA<Bech32Exception>()));
    });

    test('mixed case is rejected', () {
      expect(() => decodeBech32('npub1A'), throwsA(isA<Bech32Exception>()));
    });

    test('no separator is rejected', () {
      expect(
        () => decodeBech32('pzry9x0s0muk'),
        throwsA(isA<Bech32Exception>()),
      );
    });

    test('empty hrp is rejected', () {
      expect(
        () => decodeBech32('1pzry9x0s0muk'),
        throwsA(isA<Bech32Exception>()),
      );
    });

    test('too-short data is rejected', () {
      expect(() => decodeBech32('li1dgmt3'), throwsA(isA<Bech32Exception>()));
    });
  });
}
