// Regression tests for notification tap targets:
//   1. A reaction (like) on one of the user's OLDER posts — outside the
//      recent-200 in-memory window that seeds myEventIds — must still
//      navigate to the LIKED POST. Previously the gated referencedId missed,
//      targetEventId stayed null, and the tap fell back to the kind-7
//      reaction event itself ("点赞通知跳到点赞事件本身" bug).
//   2. notificationNavTarget: reply/mention open the incoming post
//      (sourceEventId); reaction/repost open the interacted own post
//      (targetEventId).

import 'dart:async';

import 'package:costr/app/providers.dart';
import 'package:costr/features/notifications/notifications_page.dart';
import 'package:costr/models/event.dart';
import 'package:costr/models/mute_set.dart';
import 'package:costr/nostr/identity.dart';
import 'package:costr/nostr/relay_client.dart';
import 'package:costr/nostr/relay_pool.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _priv =
    '0000000000000000000000000000000000000000000000000000000000000001';

class _Id extends IdentityNotifier {
  @override
  Future<Identity?> build() async => Identity.fromPrivkeyHex(_priv);
}

/// Fixed in-memory store (no SQLite / relay wiring in unit tests).
class _FixedStore extends EventStoreNotifier {
  _FixedStore(this.events);
  final List<Event> events;

  @override
  List<Event> build() => events;
}

/// Fake relay connection — no network, manually emit events.
class _FakeRelay implements RelayConnection {
  _FakeRelay(this.url);

  @override
  final String url;
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
  }

  @override
  void request(String subId, Map<String, dynamic> filter) {}

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

  void emit(Event e) => _events.add(e);
}

Event _ev({
  required int kind,
  required String id,
  required String pubkey,
  String content = '',
  List<List<dynamic>> tags = const [],
}) => Event(
  id: id,
  pubkey: pubkey,
  createdAt: 1700000000,
  kind: kind,
  tags: tags,
  content: content,
  sig: 's' * 128,
);

void main() {
  group('primaryETagTarget — un-gated e-tag target', () {
    test('resolves ids NOT in myEventIds (older own posts)', () {
      final reaction = _ev(
        kind: 7,
        id: 'like_ev',
        pubkey: 'b' * 64,
        content: '+',
        tags: [
          ['e', 'old_post'],
          ['p', 'a' * 64],
        ],
      );
      // Gated: misses (old_post not in the window).
      expect(notificationReferencedId(reaction, const {}), isNull);
      // Un-gated: the liked post.
      expect(primaryETagTarget(reaction), 'old_post');
    });

    test('NIP-10 marker precedence reply > positional > root', () {
      final e = _ev(
        kind: 7,
        id: 'x',
        pubkey: 'b' * 64,
        tags: const [
          ['e', 'root_id', '', 'root'],
          ['e', 'reply_id', '', 'reply'],
        ],
      );
      expect(primaryETagTarget(e), 'reply_id');
    });
  });

  group('Amethyst reactions — pubkey in the NIP-10 marker slot', () {
    // Real-world shape (Amethyst): ["e", <liked-id>, <relay>, <author-pubkey>]
    // — the 4th field is a pubkey, NOT a root/reply/mention marker. The old
    // parser matched no branch and returned null → the tap fell back to the
    // reaction event itself.
    const liked =
        'ef8b760789d80e8f8e96618057d004af6475c09da884bc6041cf8fa4299ad4a4';
    const author =
        'd26761d144210054851d0707b0f06a51f8d65ddcf47c9b925545a8db07348f24';

    test('un-gated target resolves the liked post', () {
      final reaction = _ev(
        kind: 7,
        id: 'like_ev',
        pubkey: '9' * 64,
        content: '💪',
        tags: [
          ['e', liked, 'wss://relay.gulugulu.moe/', author],
          ['p', author, 'wss://relay.gulugulu.moe/'],
          ['k', '1'],
          ['client', 'Amethyst'],
        ],
      );
      expect(primaryETagTarget(reaction), liked);
    });

    test('gated resolution finds it when the liked post is in myEventIds', () {
      final reaction = _ev(
        kind: 7,
        id: 'like_ev',
        pubkey: '9' * 64,
        content: '+',
        tags: [
          ['e', liked, '', author],
          ['p', author],
        ],
      );
      expect(notificationReferencedId(reaction, {liked}), liked);
    });

    test('mention marker is still excluded', () {
      final e = _ev(
        kind: 1,
        id: 'n',
        pubkey: 'b' * 64,
        tags: const [
          ['e', 'm_id', '', 'mention'],
        ],
      );
      expect(primaryETagTarget(e), isNull);
    });
  });

  group('notificationNavTarget', () {
    NotificationItem item(NotificationType t, {String? target, String? source}) =>
        NotificationItem(
          type: t,
          pubkeys: ['b' * 64],
          extraCount: 0,
          time: 1,
          targetEventId: target,
          sourceEventId: source,
          id: 'k',
          unread: true,
        );

    test('reaction opens the liked post, not the like event', () {
      final i = item(
        NotificationType.reaction,
        target: 'liked_post',
        source: 'like_event',
      );
      expect(notificationNavTarget(i), 'liked_post');
    });

    test('reaction falls back to source only when target is null', () {
      final i = item(NotificationType.reaction, source: 'like_event');
      expect(notificationNavTarget(i), 'like_event');
    });

    test('reply opens the incoming reply, not the own post', () {
      final i = item(
        NotificationType.reply,
        target: 'my_post',
        source: 'their_reply',
      );
      expect(notificationNavTarget(i), 'their_reply');
    });

    test('repost opens the reposted own post', () {
      final i = item(
        NotificationType.repost,
        target: 'my_post',
        source: 'repost_event',
      );
      expect(notificationNavTarget(i), 'my_post');
    });

    test('follow has no post target', () {
      final i = item(NotificationType.follow, source: 'kind3_id');
      expect(notificationNavTarget(i), isNull);
    });
  });

  test(
    'like on an older own post (not in myEventIds) targets the liked post',
    () async {
      final me = Identity.fromPrivkeyHex(_priv).pubkeyHex;
      final relay = _FakeRelay('wss://fake/');
      final container = ProviderContainer(
        overrides: [
          relayPoolProvider.overrideWith((ref) => RelayPool([relay])),
          identityProvider.overrideWith(() => _Id()),
          // EMPTY store → myEventIds holds nothing; the liked post is
          // exactly the "older post outside the window" case.
          eventStoreProvider.overrideWith(() => _FixedStore(const [])),
          myMuteSetProvider.overrideWith((ref) => const MuteSet()),
        ],
      );
      addTearDown(container.dispose);

      // Wire the pool's merged/raw streams (the notification generator reads
      // rawEvents, which is only populated after connect()).
      await container.read(relayPoolProvider).connect();

      final sub = container.listen(notificationsProvider(me), (_, _) {});
      addTearDown(sub.close);

      // Initial empty emission settles.
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // A kind-7 reaction in REAL Amethyst wire shape: the e-tag's 4th field
      // is the liked post's author PUBKEY (not a NIP-10 root/reply marker),
      // plus a ["k","1"] kind tag. e-tag → an OLD own post (not in
      // myEventIds), p-tag → me (passes the mention gate).
      relay.emit(
        _ev(
          kind: 7,
          id: 'like_event_1',
          pubkey: 'c' * 64,
          content: '💪',
          tags: [
            ['e', 'old_own_post', 'wss://relay.example/', me],
            ['p', me, 'wss://relay.example/'],
            ['k', '1'],
            ['client', 'Amethyst'],
          ],
        ),
      );

      // Wait for the debounced emit (300ms flush timer + margin).
      await Future<void>.delayed(const Duration(milliseconds: 600));

      final list = container.read(notificationsProvider(me)).value;
      expect(list, isNotNull);
      expect(list, hasLength(1));
      final n = list!.single;
      expect(n.type, NotificationType.reaction);
      // The crux: targetEventId is the LIKED POST — not null (which used to
      // make the tap fall back to the reaction event itself).
      expect(n.targetEventId, 'old_own_post');
      expect(notificationNavTarget(n), 'old_own_post');
    },
  );
}
