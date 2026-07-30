import 'package:costr/utils/nip19.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('entityToPubkeyHex nostr: prefix', () {
    const np =
        'nprofile1qy2hwumn8ghj7un9d3shjtnyd968gmewwp6kyqpq065768plld8t4syhcwftum9fnhujf03hjenprv7kuuj42furfhfq3zyh73';
    const pk =
        '7ea9ed1c3ffb4ebac097c392be6ca99df924be37966611b3d6e7255527834dd2';

    test('decodes bare nprofile', () {
      expect(entityToPubkeyHex(np), pk);
    });

    test('decodes nostr:-prefixed nprofile (NIP-27 mention form)', () {
      expect(entityToPubkeyHex('nostr:$np'), pk);
    });

    test('case-insensitive nostr: prefix', () {
      expect(entityToPubkeyHex('Nostr:$np'), pk);
    });

    test('returns null for non-pubkey entity', () {
      expect(entityToPubkeyHex('note1qrst'), isNull);
    });
  });
}
