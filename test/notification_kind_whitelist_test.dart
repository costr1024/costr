// Regression tests for the notification kind whitelist ("kind-30000 列表变成
// @通知" bug): a spammer re-published a parameterized-replaceable kind-30000
// people-list (same `d` tag, empty content) every few minutes with dozens of
// p-tags; the events reached the notification listener (relay output is
// untrusted — a misbehaving relay can push events no filter requested) and
// the p-tag check alone classified them as "在帖子里 @了你", each revision
// opening into an empty non-post. The listener must only classify the four
// kinds it understands: 1 / 3 / 6 / 7.

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

/// Fake relay that EOSEs every REQ and lets the test push arbitrary events
/// into the pool's raw stream (simulating a relay delivering events no
/// subscription filter requested).
class _PushRelay implements RelayConnection {
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
    _onConnected?.call();
  }

  @override
  void request(String subId, Map<String, dynamic> filter) => _eose.add(subId);

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

Future<ProviderContainer> _containerWith(RelayPool pool) async {
  final container = ProviderContainer(
    overrides: [
      relayPoolProvider.overrideWith((ref) => pool),
      identityProvider.overrideWith(() => _Id()),
      eventStoreProvider.overrideWith(() => _FixedStore(const [])),
      myMuteSetProvider.overrideWith((ref) => const MuteSet()),
    ],
  );
  addTearDown(container.dispose);
  await container.read(relayPoolProvider).connect();
  final sub = container.listen(
    notificationsProvider(Identity.fromPrivkeyHex(_priv).pubkeyHex),
    (_, _) {},
  );
  addTearDown(sub.close);
  await Future<void>.delayed(const Duration(milliseconds: 20));
  return container;
}

void main() {
  test('kind-30000 people-list with p-tag = me is NOT a mention', () async {
    final me = Identity.fromPrivkeyHex(_priv).pubkeyHex;
    const spammer =
        '961105c055afe7a01454fb802d6334f2ae3dce6b6404da9c8ecc6a71ab38ffdb';
    final relay = _PushRelay();
    final container = await _containerWith(RelayPool([relay]));

    // The real attack payload: parameterized-replaceable list, empty
    // content, dozens of p-tags. Re-published revisions (new id, same d)
    // must not spawn notifications either.
    for (var i = 0; i < 3; i++) {
      relay.emit(
        _ev(
          kind: 30000,
          id: '$i${'a' * 63}',
          pubkey: spammer,
          createdAt: 1700000000 + i * 60,
          tags: [
            ['d', 'dce1155a-be91-4093-9945-1f55887c4113'],
            ['name', 'porn'],
            ['p', me],
            ['p', 'b' * 64],
          ],
        ),
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 600));

    final list = container.read(notificationsProvider(me)).value;
    expect(list, isNotNull);
    expect(list, isEmpty, reason: 'non 1/3/6/7 kinds must never notify');
  });

  test('other foreign kinds (e.g. 0, 10002, 9735) with p-tag = me are NOT '
      'mentions', () async {
    final me = Identity.fromPrivkeyHex(_priv).pubkeyHex;
    const other =
        'abababababababababababababababababababababababababababababababab';
    final relay = _PushRelay();
    final container = await _containerWith(RelayPool([relay]));

    for (final kind in [0, 4, 10002, 9735, 30023]) {
      relay.emit(
        _ev(
          kind: kind,
          id: '${kind.toRadixString(16).padLeft(4, '0')}${'c' * 60}',
          pubkey: other,
          createdAt: 1700000000,
          tags: [
            ['p', me],
          ],
        ),
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 600));

    final list = container.read(notificationsProvider(me)).value;
    expect(list, isNotNull);
    expect(list, isEmpty);
  });

  test('a genuine kind-1 mention still notifies', () async {
    final me = Identity.fromPrivkeyHex(_priv).pubkeyHex;
    const friend =
        'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff';
    final relay = _PushRelay();
    final container = await _containerWith(RelayPool([relay]));

    relay.emit(
      _ev(
        kind: 1,
        id: 'd' * 64,
        pubkey: friend,
        createdAt: 1700000000,
        content: 'hello nostr:$me',
        tags: [
          ['p', me],
        ],
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 600));

    final list = container.read(notificationsProvider(me)).value;
    expect(list, isNotNull);
    final mentions = list!
        .where((n) => n.type == NotificationType.mention)
        .toList();
    expect(mentions, hasLength(1));
    expect(mentions.single.pubkeys, [friend]);
  });
}
