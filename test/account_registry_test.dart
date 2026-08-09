// Unit tests for the multi-account registry model (AccountSet / AccountEntry):
// JSON round-trip, upsert/switch/remove invariants, malformed-input tolerance.

import 'package:costr/nostr/identity.dart';
import 'package:costr/services/account_registry.dart';
import 'package:flutter_test/flutter_test.dart';

const _privA =
    '0000000000000000000000000000000000000000000000000000000000000001';
const _privB =
    '0000000000000000000000000000000000000000000000000000000000000002';

AccountEntry _entry(String privHex) =>
    AccountEntry.fromIdentity(Identity.fromPrivkeyHex(privHex));

void main() {
  final a = _entry(_privA);
  final b = _entry(_privB);

  group('AccountEntry', () {
    test('fromIdentity carries pubkey/nsec/npub', () {
      final id = Identity.fromPrivkeyHex(_privA);
      expect(a.pubkeyHex, id.pubkeyHex);
      expect(a.nsec, id.nsec);
      expect(a.npub, id.npub);
      expect(a.toString(), isNot(contains(id.nsec))); // redacted
    });

    test('tryFromJson rejects malformed entries', () {
      expect(AccountEntry.tryFromJson(null), isNull);
      expect(AccountEntry.tryFromJson('x'), isNull);
      expect(AccountEntry.tryFromJson({'pubkey': 'p'}), isNull);
      expect(AccountEntry.tryFromJson({'pubkey': 'p', 'nsec': 5}), isNull);
    });
  });

  group('AccountSet', () {
    test('upsert adds and activates', () {
      final set = const AccountSet().upsert(a, activate: true);
      expect(set.accounts, [a]);
      expect(set.activePubkey, a.pubkeyHex);
      expect(set.active, a);
    });

    test('upsert same pubkey replaces instead of duplicating', () {
      final set = const AccountSet()
          .upsert(a, activate: true)
          .upsert(b, activate: true)
          .upsert(a, activate: false); // re-add A without activation
      expect(set.accounts.length, 2);
      // B stayed active (activate: false on the re-add).
      expect(set.activePubkey, b.pubkeyHex);
    });

    test('withActive switches; unknown pubkey is a no-op', () {
      final set = const AccountSet()
          .upsert(a, activate: true)
          .upsert(b, activate: false);
      expect(set.withActive(b.pubkeyHex).activePubkey, b.pubkeyHex);
      final switched = set.withActive(b.pubkeyHex);
      expect(identical(switched, set), isFalse);
      expect(set.withActive('unknown'), same(set)); // no-op returns this
      expect(set.withActive('unknown').activePubkey, a.pubkeyHex);
    });

    test('remove active falls back to the next stored account', () {
      final set = const AccountSet()
          .upsert(a, activate: true)
          .upsert(b, activate: false);
      final after = set.remove(a.pubkeyHex);
      expect(after.accounts, [b]);
      expect(after.activePubkey, b.pubkeyHex);
    });

    test('remove last account leaves an empty, logged-out set', () {
      final after = const AccountSet()
          .upsert(a, activate: true)
          .remove(a.pubkeyHex);
      expect(after.isEmpty, isTrue);
      expect(after.activePubkey, isNull);
      expect(after.active, isNull);
    });

    test('remove non-active keeps the active one', () {
      final set = const AccountSet()
          .upsert(a, activate: true)
          .upsert(b, activate: false);
      final after = set.remove(b.pubkeyHex);
      expect(after.accounts, [a]);
      expect(after.activePubkey, a.pubkeyHex);
    });

    test('remove unknown pubkey is a no-op', () {
      final set = const AccountSet().upsert(a, activate: true);
      expect(set.remove('unknown'), same(set));
    });

    test('toJson/fromJson round-trip', () {
      final set = const AccountSet()
          .upsert(a, activate: true)
          .upsert(b, activate: false);
      final decoded = AccountSet.tryFromJson(set.toJson());
      expect(decoded, set);
      expect(decoded.activePubkey, set.activePubkey);
    });

    test('tryFromJson tolerates malformed blobs', () {
      expect(AccountSet.tryFromJson(null), const AccountSet());
      expect(AccountSet.tryFromJson('junk'), const AccountSet());
      expect(AccountSet.tryFromJson({'accounts': 'x'}), const AccountSet());
      // Duplicate pubkeys collapse; dangling active pointer falls back.
      final decoded = AccountSet.tryFromJson({
        'accounts': [a.toJson(), a.toJson(), b.toJson()],
        'active': 'gone',
      });
      expect(decoded.accounts.length, 2);
      expect(decoded.activePubkey, a.pubkeyHex); // first stored account
    });

    test('equality compares accounts + active', () {
      final s1 = const AccountSet().upsert(a, activate: true);
      final s2 = const AccountSet().upsert(a, activate: true);
      expect(s1, s2);
      expect(s1 == s2.withActive(a.pubkeyHex), isTrue);
    });
  });
}
