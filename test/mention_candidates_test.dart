// Regression: @-mention candidates come from the store's EVICTION-PROOF
// metadata index, not the capped event list. Before the fix,
// knownUsersProvider scanned the capped list for kind-0 — once over-cap
// eviction ran (priority 7 → 0 → 6 → 1), users' metadata fell out of the
// list mid-session and they vanished from the autocomplete panel (even
// followees lost their NAME, matching only by npub prefix). A restart
// re-hydrated ALL cached metadata from SQLite, which is why "重启就好了".

import 'dart:convert';

import 'package:costr/app/providers.dart';
import 'package:costr/models/event.dart';
import 'package:costr/nostr/identity.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _priv =
    '0000000000000000000000000000000000000000000000000000000000000001';

class _Id extends IdentityNotifier {
  @override
  Future<Identity?> build() async => Identity.fromPrivkeyHex(_priv);
}

class _Follows extends FollowingNotifier {
  _Follows(this.list);
  final List<String> list;

  @override
  Future<List<String>> build() async => list;
}

/// Store-backed notifier: the exposed state list is irrelevant here — the
/// test drives the notifier's REAL [EventStore] (and its metadata index)
/// directly.
class _StoreNotifier extends EventStoreNotifier {
  @override
  List<Event> build() => store.events;
}

/// Same, but the exposed state list is ALWAYS empty — simulates the held
/// list AFTER over-cap eviction dropped every kind-0 while the eviction-proof
/// index still remembers them.
class _EmptyListNotifier extends EventStoreNotifier {
  @override
  List<Event> build() => const <Event>[];
}

Event _meta(String pubkey, int createdAt, Map<String, dynamic> json) => Event(
  id: 'k0-$pubkey',
  pubkey: pubkey,
  createdAt: createdAt,
  kind: 0,
  tags: const [],
  content: jsonEncode(json),
  sig: 's' * 128,
);

void main() {
  test(
    'candidates resolve names from the eviction-proof metadata index',
    () async {
      final notifier = _StoreNotifier();
      final alice = 'a' * 64;
      final followee = 'f' * 64;
      // Alice's kind-0 sits ONLY in the metadata index — put a followee
      // kind-0 in too so both paths (index + follows) are exercised.
      notifier.store.add(_meta(alice, 100, {'name': 'Alice'}));
      notifier.store.add(_meta(followee, 90, {'display_name': '小傅'}));

      final container = ProviderContainer(
        overrides: [
          identityProvider.overrideWith(() => _Id()),
          followingStateProvider.overrideWith(() => _Follows([followee])),
          eventStoreProvider.overrideWith(() => notifier),
        ],
      );
      addTearDown(container.dispose);

      // Let the async overrides (identity / follows) resolve; the provider
      // rebuilds lazily on the next read.
      await container.read(identityProvider.future);
      await container.read(followingStateProvider.future);

      final users = container.read(knownUsersProvider);
      final byPk = {for (final u in users) u.pubkey: u};

      // Alice is not followed — she is a candidate purely via the index,
      // with her display name resolved.
      expect(byPk[alice]?.label, 'Alice');
      // Followee resolved via the index carries the name too (before the
      // fix, an evicted followee degraded to a bare npub prefix and could
      // not be matched by typing the name).
      expect(byPk[followee]?.label, '小傅');
      // Self is always present.
      final me = Identity.fromPrivkeyHex(_priv).pubkeyHex;
      expect(byPk.containsKey(me), isTrue);
    },
  );

  test(
    'a user whose kind-0 left the held LIST (eviction) is still a candidate',
    () async {
      // _EmptyListNotifier exposes an EMPTY held list — the exact shape after
      // over-cap eviction dropped the kind-0 from the capped store — while
      // the eviction-proof index still remembers it. The old list-scan
      // provider returned nothing here; the index-backed one must resolve.
      final notifier = _EmptyListNotifier();
      final alice = 'a' * 64;
      notifier.store.add(_meta(alice, 100, {'name': 'Alice'}));

      final container = ProviderContainer(
        overrides: [
          identityProvider.overrideWith(() => _Id()),
          followingStateProvider.overrideWith(() => _Follows(const [])),
          eventStoreProvider.overrideWith(() => notifier),
        ],
      );
      addTearDown(container.dispose);
      await container.read(identityProvider.future);
      await container.read(followingStateProvider.future);

      // Sanity: the exposed held list is empty (post-eviction shape) while
      // the eviction-proof index still remembers Alice.
      expect(container.read(eventStoreProvider), isEmpty);
      expect(notifier.metadataByPubkey.keys, [alice]);

      final users = container.read(knownUsersProvider);
      expect(users.where((u) => u.pubkey == alice).single.label, 'Alice');
    },
  );
}
