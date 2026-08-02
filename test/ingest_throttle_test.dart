// Verifies EventStoreNotifier.ingest throttles state emissions (≤1 per 200ms
// burst) via _scheduleFlush, instead of rebuilding synchronously per event.
// The following-feed outbox router can burst hundreds of events on load; an
// unthrottled ingest would jank the ListView.

import 'package:costr/app/providers.dart';
import 'package:costr/models/event.dart';
import 'package:costr/nostr/relay_pool.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Event _e(String id) => Event(
  id: id,
  pubkey: 'p' * 64,
  createdAt: 1,
  kind: 1,
  tags: const [],
  content: 'c',
  sig: 's' * 128,
);

void main() {
  test('ingest batches state emissions to ≤1 per 200ms burst', () async {
    // Empty pool (not connected — build() only listens to pool.events, which
    // never emits). localCacheProvider overridden to throw so _cache stays
    // null: _hydrate returns without touching SQLite, and cacheThreadEvent /
    // _persist early-return on null db → pure in-memory store, no DB access.
    final container = ProviderContainer(
      overrides: [
        relayPoolProvider.overrideWith((ref) => RelayPool(const [])),
        localCacheProvider.overrideWith(
          (ref) async => throw StateError('stub'),
        ),
      ],
    );
    addTearDown(container.dispose);

    var emissions = 0;
    final sub = container.listen(
      eventStoreProvider,
      (_, _) => emissions++,
      fireImmediately: false,
    );
    addTearDown(sub.close);
    // Reading the notifier builds the provider (wires the pool listener);
    // keep the subscription alive for the duration of the test.
    final store = container.read(eventStoreProvider.notifier);
    // Burst 50 distinct events synchronously. An unthrottled ingest would fire
    // 50 state updates; the throttled one batches into a single 200ms flush.
    for (var i = 0; i < 50; i++) {
      await store.ingest(_e('e$i'));
    }
    // Before the flush timer fires, no rebuilds should have been emitted.
    expect(emissions, 0);
    // Let the 200ms throttle fire.
    await Future<void>.delayed(const Duration(milliseconds: 260));
    expect(emissions, 1);

    // The store actually holds all 50 (ingest added them even when batching).
    expect(container.read(eventStoreProvider).length, 50);
  });
}
