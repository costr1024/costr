// NIP-65 inbox delivery: replies/mentions/reactions/reposts are published to
// the recipients' own WRITE (inbox) relays so they actually reach users whose
// client reads its own outbox (which may not overlap the sender's relays).

import 'dart:async';

import 'package:costr/app/providers.dart';
import 'package:costr/models/event.dart';
import 'package:costr/nostr/relay_client.dart';
import 'package:costr/nostr/relay_pool.dart';
import 'package:flutter_test/flutter_test.dart';

/// Base fake relay: immediate EOSE, no events.
class _EmptyRelay implements RelayConnection {
  _EmptyRelay(this.url);

  @override
  final String url;
  final StreamController<Event> _events = StreamController<Event>.broadcast();
  final StreamController<String> _eose = StreamController<String>.broadcast();
  final StreamController<String> _notices =
      StreamController<String>.broadcast();
  final StreamController<RelayOk> _oks = StreamController<RelayOk>.broadcast();
  final StreamController<String> _auths = StreamController<String>.broadcast();

  bool _connected = false;
  bool get connected => _connected;

  @override
  bool get isConnected => _connected;
  @override
  Stream<Event> get events => _events.stream;
  @override
  Stream<(String, Event)> get taggedEvents =>
      _events.stream.map((e) => ('fake', e));
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
  }

  @override
  void request(String subId, Map<String, dynamic> filter) {
    scheduleMicrotask(() {
      if (!_eose.isClosed) _eose.add(subId);
    });
  }

  @override
  void closeSubscription(String subId) {}
  @override
  void publish(Event event) {}
  @override
  void sendAuth(Event event) {}
  @override
  void setOnConnected(void Function() cb) {}
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

/// Inbox relay that ACKs any publish with ok:true and records what it got.
class _InboxRelay extends _EmptyRelay {
  _InboxRelay(super.url);
  final List<Event> received = [];

  @override
  void publish(Event event) {
    received.add(event);
    scheduleMicrotask(() {
      if (!_oks.isClosed) _oks.add(RelayOk(event.id, true, null, url: url));
    });
  }
}

const _me = 'memememememememememememememememememememememememememememememememe';
const _alice =
    'alicealicealicealicealicealicealicealicealicealicealicealicealicea';
const _bob = 'bobbobbobbobbobbobbobbobbobbobbobbobbobbobbobbobbobbobbobbobbob';

Event _reply(List<List<dynamic>> tags) => Event(
  id: 'r' * 64,
  pubkey: _me,
  createdAt: 1700000000,
  kind: 1,
  tags: tags,
  content: 'a reply',
  sig: 's' * 128,
);

void main() {
  group('RelayPool.publishToUrls', () {
    test('dials transient relays, publishes, returns the accepted urls', () async {
      final relays = <String, _InboxRelay>{};
      final pool = RelayPool([_EmptyRelay('wss://pool')]);
      pool.makeClient = (url) => relays.putIfAbsent(url, () => _InboxRelay(url));

      final ev = _reply([
        ['p', _alice],
      ]);
      final accepted = await pool.publishToUrls(
        ev,
        ['wss://inbox-a', 'wss://inbox-b', 'not-a-relay'],
      );

      expect(accepted.toSet(), {'wss://inbox-a', 'wss://inbox-b'});
      expect(relays['wss://inbox-a']!.received.single.id, ev.id);
      expect(relays['wss://inbox-b']!.received.single.id, ev.id);
      // Transient clients were disposed after the delivery.
      expect(relays['wss://inbox-a']!.isConnected, isTrue);
    });

    test('empty url list returns nothing', () async {
      final pool = RelayPool([_EmptyRelay('wss://pool')]);
      expect(await pool.publishToUrls(_reply(const []), const []), isEmpty);
    });
  });

  group('deliverToInboxes', () {
    test('publishes to every p-tagged recipient\'s write relays', () async {
      final relays = <String, _InboxRelay>{};
      final pool = RelayPool([_EmptyRelay('wss://pool')]);
      pool.makeClient = (url) => relays.putIfAbsent(url, () => _InboxRelay(url));

      final ev = _reply([
        ['e', 'p' * 64, '', 'reply'],
        ['p', _alice],
        ['p', _bob],
      ]);
      await deliverToInboxes(
        pool,
        ev,
        resolveRelayList: (pk) async => RelayList(
          read: const ['wss://read.example'],
          write: ['wss://inbox-$pk'],
        ),
      );

      expect(relays.keys, containsAll(['wss://inbox-$_alice', 'wss://inbox-$_bob']));
      expect(relays['wss://inbox-$_alice']!.received.single.id, ev.id);
    });

    test('never delivers to self', () async {
      final relays = <String, _InboxRelay>{};
      final pool = RelayPool([_EmptyRelay('wss://pool')]);
      pool.makeClient = (url) => relays.putIfAbsent(url, () => _InboxRelay(url));

      // p-tags include the sender themself (e.g. self-reply) + one other.
      final ev = _reply([
        ['p', _me],
        ['p', _alice],
      ]);
      await deliverToInboxes(
        pool,
        ev,
        resolveRelayList: (pk) async => RelayList(write: ['wss://inbox-$pk']),
      );

      expect(relays.containsKey('wss://inbox-$_me'), isFalse);
      expect(relays['wss://inbox-$_alice']!.received, hasLength(1));
    });

    test('no p-tags → nothing is delivered', () async {
      final relays = <String, _InboxRelay>{};
      final pool = RelayPool([_EmptyRelay('wss://pool')]);
      pool.makeClient = (url) => relays.putIfAbsent(url, () => _InboxRelay(url));

      await deliverToInboxes(
        pool,
        _reply(const []),
        resolveRelayList: (pk) async => RelayList(write: ['wss://inbox-$pk']),
      );
      expect(relays, isEmpty);
    });

    test('recipient without write relays is skipped, others still delivered',
        () async {
      final relays = <String, _InboxRelay>{};
      final pool = RelayPool([_EmptyRelay('wss://pool')]);
      pool.makeClient = (url) => relays.putIfAbsent(url, () => _InboxRelay(url));

      final ev = _reply([
        ['p', _alice], // no relay list at all
        ['p', _bob],   // has write relays
      ]);
      await deliverToInboxes(
        pool,
        ev,
        resolveRelayList: (pk) async =>
            pk == _bob ? RelayList(write: const ['wss://inbox-bob']) : null,
      );

      expect(relays.keys, ['wss://inbox-bob']);
    });
  });
}
