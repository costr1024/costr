// Regression test for the "已读通知复活" (read notifications resurrect on the
// next launch) bug. Reply/mention classification gates e-tags against the
// user's own-post snapshot, which hydrates asynchronously from SQLite at cold
// start. Judging an event BEFORE hydration lands yields mention:<eventId>;
// AFTER yields reply:<myPostId> — a different item id, so the persisted
// read-set misses on the next launch and cleared notifications resurface as
// unread. The generator must await event-store hydration so the item id is
// identical whichever way the relay-vs-SQLite race goes.

import 'dart:async';

import 'package:costr/app/providers.dart';
import 'package:costr/features/notifications/notifications_page.dart';
import 'package:costr/models/event.dart';
import 'package:costr/models/mute_set.dart';
import 'package:costr/nostr/identity.dart';
import 'package:costr/nostr/relay_client.dart';
import 'package:costr/nostr/relay_pool.dart';
import 'package:costr/services/local_cache.dart' as cache;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _priv =
    '0000000000000000000000000000000000000000000000000000000000000001';

class _Id extends IdentityNotifier {
  @override
  Future<Identity?> build() async => Identity.fromPrivkeyHex(_priv);
}

/// Store whose own-post snapshot lands LATE (relay wins the cold-start race:
/// the mention is pushed before SQLite hydration completes).
class _LateHydratedStore extends EventStoreNotifier {
  _LateHydratedStore(this.myPost);
  final Event myPost;
  final gate = Completer<void>();

  @override
  Future<void> get hydrated => gate.future;

  @override
  List<Event> build() {
    Timer(const Duration(milliseconds: 80), () {
      state = [myPost];
      gate.complete();
    });
    return const [];
  }
}

/// Store hydrated BEFORE any relay event (SQLite wins the race).
class _ReadyStore extends EventStoreNotifier {
  _ReadyStore(this.myPost);
  final Event myPost;

  @override
  List<Event> build() => [myPost];
}

/// Store holding NO events at all — the DB own-post snapshot is the only
/// source of myEventIds.
class _EmptyStore extends EventStoreNotifier {
  @override
  List<Event> build() => const [];
}

/// Relay that pushes the served events once on connect (the cold-start push,
/// before the notification generator is listening) and RE-serves them in
/// answer to every #p / #e REQ — exactly what real relays do on subscription.
class _ServingRelay implements RelayConnection {
  _ServingRelay(this.served);
  final List<Event> served;

  @override
  final String url = 'wss://fake/';
  final StreamController<Event> _events = StreamController<Event>.broadcast();
  final StreamController<String> _eose = StreamController<String>.broadcast();
  final StreamController<String> _notices =
      StreamController<String>.broadcast();
  final StreamController<RelayOk> _oks = StreamController<RelayOk>.broadcast();
  final StreamController<String> _auths = StreamController<String>.broadcast();

  bool _connected = false;
  void Function()? _onConnected;

  @override
  bool get isConnected => _connected;

  @override
  Stream<Event> get events => _events.stream;
  @override
  Stream<String> get eose => _eose.stream;
  @override
  Stream<String> get notices => _notices.stream;
  @override
  Stream<RelayOk> get oks => _oks.stream;
  @override
  Stream<String> get auths => _auths.stream;

  @override
  Future<void> connect() async {
    _connected = true;
    _onConnected?.call();
    // The cold-start push: lands while the generator is still awaiting
    // hydration (or not yet listening at all) — the pre-fix race window.
    for (final e in served) {
      _events.add(e);
    }
  }

  @override
  void request(String subId, Map<String, dynamic> filter) {
    if (filter.containsKey('#p') || filter.containsKey('#e')) {
      for (final e in served) {
        _events.add(e);
      }
    }
    _eose.add(subId);
  }

  @override
  void closeSubscription(String subId) {}

  @override
  void publish(Event event) {}

  @override
  void sendAuth(Event event) {}

  @override
  void setOnConnected(void Function() cb) => _onConnected = cb;
  @override
  void setOnDisconnected(void Function() cb) {}

  @override
  Future<void> dispose() async {
    await _events.close();
    await _eose.close();
    await _notices.close();
    await _oks.close();
    await _auths.close();
  }
}

Event _ev({
  required int kind,
  required String id,
  required String pubkey,
  required int createdAt,
  String content = '',
  List<List<dynamic>> tags = const [],
}) => Event(
  id: id,
  pubkey: pubkey,
  createdAt: createdAt,
  kind: kind,
  tags: tags,
  content: content,
  sig: 's' * 64,
);

/// Runs the notification generator against [store] and returns the item ids
/// produced for the reply-mention.
Future<List<NotificationItem>> _run(Event myPost, EventStoreNotifier store) async {
  final me = Identity.fromPrivkeyHex(_priv).pubkeyHex;
  final replyMention = _ev(
    kind: 1,
    id: 'their_reply',
    pubkey: 'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd',
    createdAt: 2000,
    content: '回复并@你',
    tags: [
      ['e', 'my_post', '', 'reply'],
      ['p', me],
    ],
  );
  final relay = _ServingRelay([replyMention]);
  final container = ProviderContainer(
    overrides: [
      relayPoolProvider.overrideWith((ref) => RelayPool([relay])),
      identityProvider.overrideWith(() => _Id()),
      eventStoreProvider.overrideWith(() => store),
      myMuteSetProvider.overrideWith((ref) => const MuteSet()),
    ],
  );
  addTearDown(container.dispose);
  await container.read(relayPoolProvider).connect();
  final sub = container.listen(notificationsProvider(me), (_, _) {});
  addTearDown(sub.close);
  await Future<void>.delayed(const Duration(milliseconds: 700));
  return container.read(notificationsProvider(me)).value ?? const [];
}

void main() {
  test(
    'item id is identical whether the relay or SQLite wins the cold-start race',
    () async {
      final me = Identity.fromPrivkeyHex(_priv).pubkeyHex;
      final myPost = _ev(
        kind: 1,
        id: 'my_post',
        pubkey: me,
        createdAt: 1000,
        content: '我的帖子',
      );

      // Relay wins: the reply-mention is pushed before hydration lands.
      final late = await _run(myPost, _LateHydratedStore(myPost));
      // SQLite wins: the own-post snapshot is ready before any relay event.
      final ready = await _run(myPost, _ReadyStore(myPost));

      for (final (name, items) in [('late', late), ('ready', ready)]) {
        expect(
          items.where((i) => i.id == 'mention:their_reply'),
          isEmpty,
          reason: '$name: pre-hydration mention classification must not occur',
        );
        expect(items.length, 1, reason: '$name: exactly one aggregated item');
        expect(items.single.type, NotificationType.reply);
        expect(items.single.id, 'reply:my_post');
      }
      // The persisted read-set key from one launch therefore matches the
      // next launch's item id — read state survives cold starts.
      expect(late.single.id, ready.single.id);
    },
  );

  test(
    'own post known ONLY from SQLite still classifies reply (stable key)',
    () async {
      // RC2 regression: the in-memory store snapshot only carries the global
      // newest-1000 feed window, so an OLD own post can be absent from
      // myEventIds at cold start. Without the stable SQLite own-post snapshot
      // the reply would classify as mention:<eventId> — a different key than a
      // warm session produces (reply:<myPostId>) — and the persisted read-set
      // would miss on the next launch (resurrection). The generator must seed
      // myEventIds from queryUserPosts.
      final me = Identity.fromPrivkeyHex(_priv).pubkeyHex;
      final oldPostRow = cache.EventRow(
        id: 'my_old_post',
        pubkey: me,
        kind: 1,
        createdAt: 500,
        content: '很旧的帖子',
        sig: 's' * 64,
        raw: '{}',
        tagsJson: '[]',
        receivedAt: 0,
      );
      final stub = _PostsCache([oldPostRow]);
      final replyMention = _ev(
        kind: 1,
        id: 'their_reply2',
        pubkey: 'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd',
        createdAt: 2000,
        content: '回复你的旧帖',
        tags: [
          ['e', 'my_old_post', '', 'reply'],
          ['p', me],
        ],
      );
      final relay = _ServingRelay([replyMention]);
      final container = ProviderContainer(
        overrides: [
          relayPoolProvider.overrideWith((ref) => RelayPool([relay])),
          identityProvider.overrideWith(() => _Id()),
          // Store holds NO own posts — the DB snapshot is the only source.
          eventStoreProvider.overrideWith(() => _EmptyStore()),
          myMuteSetProvider.overrideWith((ref) => const MuteSet()),
          localCacheProvider.overrideWith((ref) async => stub),
        ],
      );
      addTearDown(container.dispose);
      await container.read(relayPoolProvider).connect();
      final sub = container.listen(notificationsProvider(me), (_, _) {});
      addTearDown(sub.close);
      await Future<void>.delayed(const Duration(milliseconds: 700));
      final items =
          container.read(notificationsProvider(me)).value ??
          const <NotificationItem>[];

      expect(
        items.where((i) => i.id == 'mention:their_reply2'),
        isEmpty,
        reason: 'own post from SQLite must gate the reply classification',
      );
      expect(items, hasLength(1));
      expect(items.single.id, 'reply:my_old_post');
    },
  );
}

/// Minimal LocalCache stand-in for the own-post snapshot read.
class _PostsCache implements cache.LocalCache {
  _PostsCache(this.posts);
  final List<cache.EventRow> posts;

  @override
  Future<List<cache.EventRow>> queryUserPosts(
    String pubkey, {
    int limit = 100,
  }) async => posts;

  @override
  Future<String?> readConfig(String key) async => null;

  @override
  Future<void> writeConfig(String key, String value) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
