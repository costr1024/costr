import 'package:costr/app/providers.dart';
import 'package:flutter_test/flutter_test.dart';

const _pk = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _other =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

Future<Object?> _empty(Uri _) async => <String, dynamic>{};

void main() {
  group('verifyNip05', () {
    test('empty identifier → none', () async {
      expect(await verifyNip05('', _pk, _empty), Nip05Status.none);
    });

    test('malformed (no @) → failed', () async {
      expect(await verifyNip05('nodomain', _pk, _empty), Nip05Status.failed);
      expect(await verifyNip05('foo@', _pk, _empty), Nip05Status.failed);
      expect(await verifyNip05('@domain', _pk, _empty), Nip05Status.failed);
    });

    test('names map matches pubkey → verified', () async {
      expect(
        await verifyNip05('alice@example.com', _pk, (uri) async {
          expect(uri.host, 'example.com');
          expect(uri.queryParameters['name'], 'alice');
          return {
            'names': {'alice': _pk},
          };
        }),
        Nip05Status.verified,
      );
    });

    test('names map has different pubkey → failed', () async {
      expect(
        await verifyNip05(
          'alice@example.com',
          _pk,
          (uri) async => {
            'names': {'alice': _other},
          },
        ),
        Nip05Status.failed,
      );
    });

    test('localpart absent from names → failed', () async {
      expect(
        await verifyNip05(
          'alice@example.com',
          _pk,
          (uri) async => {
            'names': {'bob': _pk},
          },
        ),
        Nip05Status.failed,
      );
    });

    test('"_" local-part falls back to root pubkey field → verified', () async {
      expect(
        await verifyNip05('_@example.com', _pk, (uri) async => {'pubkey': _pk}),
        Nip05Status.verified,
      );
    });

    test('non-Map response → failed', () async {
      expect(
        await verifyNip05('alice@example.com', _pk, (uri) async => 42),
        Nip05Status.failed,
      );
    });

    test('fetch throws → unknown (inconclusive)', () async {
      expect(
        await verifyNip05('alice@example.com', _pk, (uri) async => throw 'net'),
        Nip05Status.unknown,
      );
    });

    test('case-insensitive pubkey + handle match', () async {
      expect(
        await verifyNip05(
          'ALICE@Example.com',
          _pk,
          (uri) async => {
            'names': {'ALICE': _pk.toUpperCase()},
          },
        ),
        Nip05Status.verified,
      );
    });
  });
}
