// Regression: quote/repost/ancestor lookups await eventByIdProvider's
// `.future`, which used to WATCH the event store. The live store flushes a
// new list every ~200ms while events arrive → every flush REBUILT
// eventByIdProvider → the awaiting lookup RESTARTED from scratch → on a busy
// feed the relay fetch never ran to completion and quote cards sat on
// 「加载引用…」 forever ("这个事件引用的帖子还是显示加载引用…"). The store tier
// is now a one-shot read, so a flush must not restart an in-flight lookup.

import 'package:costr/app/providers.dart';
import 'package:costr/models/event.dart';
import 'package:costr/nostr/event_store.dart';
import 'package:costr/nostr/relay_pool.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _LiveStore extends EventStoreNotifier {
  @override
  final EventStore store = EventStore();

  @override
  List<Event> build() => store.events;

  void add(Event e) {
    if (store.add(e)) state = store.events;
  }
}

Event _post(String id, int createdAt) => Event(
      id: id,
      pubkey: 'a' * 64,
      createdAt: createdAt,
      kind: 1,
      tags: const [],
      content: 'x',
      sig: 's' * 128,
    );

ProviderContainer _buildContainer(_LiveStore store) {
  return ProviderContainer(
    overrides: [
      relayPoolProvider.overrideWith((ref) => RelayPool(const [])),
      indexerPoolProvider.overrideWith((ref) => RelayPool(const [])),
      searchPoolProvider.overrideWith((ref) => RelayPool(const [])),
      eventStoreProvider.overrideWith(() => store),
    ],
  );
}

void main() {
  test('store flushes do not restart an in-flight eventById lookup',
      () async {
    final store = _LiveStore();
    final container = _buildContainer(store);
    addTearDown(container.dispose);

    const missing =
        'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
    // Start the lookup (it will sit in the capped relay tier — the exact
    // window that the restart loop used to interrupt).
    final f1 = container.read(eventByIdProvider(missing).future);

    // Live events keep flushing while the lookup is in flight.
    for (var i = 0; i < 5; i++) {
      store.add(_post('live$i', 100000 + i));
      await Future<void>.delayed(const Duration(milliseconds: 60));
    }

    final f2 = container.read(eventByIdProvider(missing).future);
    expect(identical(f1, f2), isTrue,
        reason: 'store flushes must not rebuild/restart the lookup — the '
            'pending future must stay the SAME across flushes');
  });

  test('store flushes do not restart an in-flight quote lookup', () async {
    final store = _LiveStore();
    final container = _buildContainer(store);
    addTearDown(container.dispose);

    const missing =
        'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
    final f1 = container.read(quotedEventProvider(missing).future);

    for (var i = 0; i < 5; i++) {
      store.add(_post('live$i', 100000 + i));
      await Future<void>.delayed(const Duration(milliseconds: 60));
    }

    final f2 = container.read(quotedEventProvider(missing).future);
    expect(identical(f1, f2), isTrue,
        reason: 'the quote lookup must survive live store flushes');
  });

  test('store hit still resolves the lookup instantly', () async {
    final store = _LiveStore();
    final container = _buildContainer(store);
    addTearDown(container.dispose);

    const present =
        'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd';
    container.read(eventStoreProvider); // build the notifier first
    store.add(_post(present, 500));
    // A widget (quote card / detail page) always WATCHES the provider — the
    // listener keeps it alive exactly like in the app.
    final sub = container.listen(eventByIdProvider(present), (_, _) {});
    addTearDown(sub.close);
    final hit = await container.read(eventByIdProvider(present).future);
    expect(hit, isNotNull);
    expect(hit!.id, present);
  });
}
