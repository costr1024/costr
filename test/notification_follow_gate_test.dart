// Regression tests for the follow-notification gate ("重复关注通知" bug):
// a long-time follower re-publishes their contact list (kind 3) whenever they
// follow anyone; the #p subscription surfaced EVERY revision as a fresh
// "X 开始关注你". The fix judges only the author's newest revision and skips
// it when their previous revision already listed me.

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

class _FixedStore extends EventStoreNotifier {
  _FixedStore(this.events);
  final List<Event> events;

  @override
  List<Event> build() => events;
}

/// Fake relay that SERVES the stored contact-list history in answer to the
/// gate's `kinds:[3], authors:[X], until:` REQ (and EOSEs everything else).
class _HistoryRelay implements RelayConnection {
  _HistoryRelay(this.contactLists);
  final List<Event> contactLists;

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
  }

  @override
  void request(String subId, Map<String, dynamic> filter) {
    // Only the gate's historical-contact-list REQ gets answers; the live
    // notification subscriptions (kinds [1,3] #p / [1,7,6] #e) stay silent so
    // the test controls exactly which events arrive.
    final kinds = filter['kinds'];
    final authors = filter['authors'];
    if (kinds is List &&
        kinds.length == 1 &&
        kinds[0] == 3 &&
        authors is List &&
        authors.isNotEmpty) {
      final author = authors[0];
      final until = filter['until'];
      for (final e in contactLists) {
        if (e.pubkey != author) continue;
        if (until is int && e.createdAt > until) continue;
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

  void emit(Event e) => _events.add(e);
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
  sig: 's' * 128,
);

void main() {
  test('contactListContains — p-tag membership', () {
    final cl = _ev(
      kind: 3,
      id: 'cl',
      pubkey: 'f' * 64,
      createdAt: 1,
      tags: [
        ['p', 'a' * 64],
        ['p', 'b' * 64],
      ],
    );
    expect(contactListContains(cl, 'b' * 64), isTrue);
    expect(contactListContains(cl, 'c' * 64), isFalse);
  });

  test(
    'contact-list REVISION by an existing follower is NOT a new follow',
    () async {
      final me = Identity.fromPrivkeyHex(_priv).pubkeyHex;
      const follower =
          'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff';
      // History: the follower's OLD list (3 days ago) already lists me.
      final oldList = _ev(
        kind: 3,
        id: 'k3_old',
        pubkey: follower,
        createdAt: 1700000000,
        tags: [
          ['p', me],
          ['p', 'a' * 64],
        ],
      );
      final relay = _HistoryRelay([oldList]);
      final container = ProviderContainer(
        overrides: [
          relayPoolProvider.overrideWith((ref) => RelayPool([relay])),
          identityProvider.overrideWith(() => _Id()),
          eventStoreProvider.overrideWith(() => _FixedStore(const [])),
          myMuteSetProvider.overrideWith((ref) => const MuteSet()),
        ],
      );
      addTearDown(container.dispose);
      await container.read(relayPoolProvider).connect();
      final sub = container.listen(notificationsProvider(me), (_, _) {});
      addTearDown(sub.close);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // The follower re-publishes their list (followed someone new) — still
      // listing me. Must NOT produce a "开始关注你" notification.
      relay.emit(
        _ev(
          kind: 3,
          id: 'k3_new',
          pubkey: follower,
          createdAt: 1700200000,
          tags: [
            ['p', me],
            ['p', 'a' * 64],
            ['p', 'b' * 64],
          ],
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 600));

      final list = container.read(notificationsProvider(me)).value;
      expect(list, isNotNull);
      expect(
        list!.where((n) => n.type == NotificationType.follow),
        isEmpty,
        reason: 'revision by an existing follower must not notify',
      );
    },
  );

  test('a GENUINELY new follow still notifies', () async {
    final me = Identity.fromPrivkeyHex(_priv).pubkeyHex;
    const newFollower =
        'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee';
    // History: this author's only older list does NOT contain me.
    final oldList = _ev(
      kind: 3,
      id: 'k3_old2',
      pubkey: newFollower,
      createdAt: 1700000000,
      tags: [
        ['p', 'a' * 64],
      ],
    );
    final relay = _HistoryRelay([oldList]);
    final container = ProviderContainer(
      overrides: [
        relayPoolProvider.overrideWith((ref) => RelayPool([relay])),
        identityProvider.overrideWith(() => _Id()),
        eventStoreProvider.overrideWith(() => _FixedStore(const [])),
        myMuteSetProvider.overrideWith((ref) => const MuteSet()),
      ],
    );
    addTearDown(container.dispose);
    await container.read(relayPoolProvider).connect();
    final sub = container.listen(notificationsProvider(me), (_, _) {});
    addTearDown(sub.close);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    // First-ever list that includes me → new follow → notification.
    relay.emit(
      _ev(
        kind: 3,
        id: 'k3_new2',
        pubkey: newFollower,
        createdAt: 1700200000,
        tags: [
          ['p', me],
          ['p', 'a' * 64],
        ],
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 600));

    final list = container.read(notificationsProvider(me)).value;
    expect(list, isNotNull);
    final follows = list!
        .where((n) => n.type == NotificationType.follow)
        .toList();
    expect(follows, hasLength(1));
    expect(follows.single.pubkeys, [newFollower]);
  });
}
