// Notification category toggles (回复与提及 / 喜欢与转发 / 新关注者, DESIGN §5.3):
// each switch gates its event types out of the notification list entirely.
// Default all-ON preserves existing behavior; turning one OFF drops only its
// category while the others keep notifying.

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
const _myPostId =
    'pppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppp';
const _friend =
    'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff';

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

class _LikesOff extends NotifyLikesRepostsNotifier {
  @override
  bool build() => false;
}

class _RepliesOff extends NotifyRepliesMentionsNotifier {
  @override
  bool build() => false;
}

/// Fake relay that EOSEs every REQ and lets the test push events directly.
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

Future<ProviderContainer> _containerWith(
  RelayPool pool, {
  bool likesOff = false,
  bool repliesOff = false,
}) async {
  final me = Identity.fromPrivkeyHex(_priv).pubkeyHex;
  final container = ProviderContainer(
    overrides: [
      relayPoolProvider.overrideWith((ref) => pool),
      identityProvider.overrideWith(() => _Id()),
      // Own post in the store so a reaction/reply on it is gated IN.
      eventStoreProvider.overrideWith(
        () => _FixedStore([
          _ev(kind: 1, id: _myPostId, pubkey: me, createdAt: 1699999999),
        ]),
      ),
      myMuteSetProvider.overrideWith((ref) => const MuteSet()),
      if (likesOff)
        notifyLikesRepostsProvider.overrideWith(() => _LikesOff()),
      if (repliesOff)
        notifyRepliesMentionsProvider.overrideWith(() => _RepliesOff()),
    ],
  );
  addTearDown(container.dispose);
  await container.read(relayPoolProvider).connect();
  final sub = container.listen(notificationsProvider(me), (_, _) {});
  addTearDown(sub.close);
  await Future<void>.delayed(const Duration(milliseconds: 20));
  return container;
}

void main() {
  final me = Identity.fromPrivkeyHex(_priv).pubkeyHex;

  Event reaction(String id) => _ev(
    kind: 7,
    id: id,
    pubkey: _friend,
    createdAt: 1700000001,
    content: '+',
    tags: [
      ['e', _myPostId],
      ['p', me],
    ],
  );

  Event reply(String id) => _ev(
    kind: 1,
    id: id,
    pubkey: _friend,
    createdAt: 1700000002,
    content: 'nice post',
    tags: [
      ['e', _myPostId, '', 'root'],
      ['p', me],
    ],
  );

  test('all ON (default): both a like and a reply notify', () async {
    final relay = _PushRelay();
    final container = await _containerWith(RelayPool([relay]));
    relay.emit(reaction('a' * 64));
    relay.emit(reply('b' * 64));
    await Future<void>.delayed(const Duration(milliseconds: 600));

    final list = container.read(notificationsProvider(me)).value!;
    expect(list.where((n) => n.type == NotificationType.reaction), hasLength(1));
    expect(list.where((n) => n.type == NotificationType.reply), hasLength(1));
  });

  test('喜欢与转发 OFF: likes dropped, replies still notify', () async {
    final relay = _PushRelay();
    final container = await _containerWith(RelayPool([relay]), likesOff: true);
    relay.emit(reaction('a' * 64));
    relay.emit(reply('b' * 64));
    await Future<void>.delayed(const Duration(milliseconds: 600));

    final list = container.read(notificationsProvider(me)).value!;
    expect(
      list.where((n) => n.type == NotificationType.reaction),
      isEmpty,
      reason: 'likes/reposts category is off',
    );
    expect(list.where((n) => n.type == NotificationType.reply), hasLength(1));
  });

  test('回复与提及 OFF: replies dropped, likes still notify', () async {
    final relay = _PushRelay();
    final container = await _containerWith(
      RelayPool([relay]),
      repliesOff: true,
    );
    relay.emit(reaction('a' * 64));
    relay.emit(reply('b' * 64));
    await Future<void>.delayed(const Duration(milliseconds: 600));

    final list = container.read(notificationsProvider(me)).value!;
    expect(list.where((n) => n.type == NotificationType.reaction), hasLength(1));
    expect(
      list.where((n) => n.type == NotificationType.reply),
      isEmpty,
      reason: 'replies/mentions category is off',
    );
  });
}
