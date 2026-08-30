// End-to-end repro harness for the "following feed permanently stopped"
// report: exercises the REAL followingOutboxProvider → EventStoreNotifier →
// currentFeedEventsProvider chain (no overrides on the core chain) against a
// fake relay, including 关注↔全球 tab switches and publish echoes.

import 'dart:async';

import 'package:costr/app/providers.dart';
import 'package:costr/models/event.dart';
import 'package:costr/models/mute_set.dart';
import 'package:costr/nostr/identity.dart';
import 'package:costr/nostr/relay_client.dart';
import 'package:costr/nostr/relay_pool.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _priv =
    '0000000000000000000000000000000000000000000000000000000000000001';
const _followee =
    'feed000000000000000000000000000000000000000000000000000000000';

class _FakeRelay implements RelayConnection {
  _FakeRelay(this.url);

  @override
  final String url;
  final StreamController<Event> _events = StreamController<Event>.broadcast();
  final StreamController<(String, Event)> _tagged =
      StreamController<(String, Event)>.broadcast();
  final StreamController<String> _eose = StreamController<String>.broadcast();
  final StreamController<String> _notices =
      StreamController<String>.broadcast();
  final StreamController<RelayOk> _oks = StreamController<RelayOk>.broadcast();
  final StreamController<String> _auths = StreamController<String>.broadcast();

  final List<List<dynamic>> sent = [];
  bool _connected = false;
  void Function()? _onConnected;

  @override
  bool get isConnected => _connected;
  @override
  Stream<Event> get events => _events.stream;
  @override
  Stream<(String, Event)> get taggedEvents => _tagged.stream;
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
  void request(String subId, Map<String, dynamic> filter) =>
      sent.add(['REQ', subId, filter]);

  @override
  void closeSubscription(String subId) => sent.add(['CLOSE', subId]);

  @override
  void publish(Event event) => sent.add(['EVENT', event.toWireObject()]);

  @override
  void sendAuth(Event event) => sent.add(['AUTH', event.toWireObject()]);

  @override
  void setOnConnected(void Function() cb) => _onConnected = cb;
  @override
  void setOnDisconnected(void Function() cb) {}

  @override
  Future<void> dispose() async {
    await _events.close();
    await _tagged.close();
    await _eose.close();
    await _notices.close();
    await _oks.close();
    await _auths.close();
  }

  void emitTagged(String subId, Event e) {
    _events.add(e);
    if (!_tagged.isClosed) _tagged.add((subId, e));
  }

  void emitEose(String subId) => _eose.add(subId);

  String? subIdFor(String hint) {
    for (final f in sent.reversed) {
      if (f[0] == 'REQ' && (f[1] as String).contains(hint)) {
        return f[1] as String;
      }
    }
    return null;
  }
}

class _Id extends IdentityNotifier {
  @override
  Future<Identity?> build() async => Identity.fromPrivkeyHex(_priv);
}

class _Follows extends FollowingNotifier {
  @override
  Future<List<String>> build() async => const [_followee];
}

class _Mode extends FeedModeNotifier {
  @override
  FeedMode build() => FeedMode.following;
  @override
  void set(FeedMode m) => state = m; // no SQLite persist in tests
}

Event _note({
  required String id,
  required String pubkey,
  required int createdAt,
}) => Event(
  id: id,
  pubkey: pubkey,
  createdAt: createdAt,
  kind: 1,
  tags: const [],
  content: 'hello',
  sig: 's' * 128,
);

Future<T> _pollFor<T>(
  T? Function() probe, {
  Duration timeout = const Duration(seconds: 8),
}) async {
  final sw = Stopwatch()..start();
  while (true) {
    final v = probe();
    if (v != null) return v;
    if (sw.elapsed > timeout) {
      fail('condition not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

void main() {
  test(
    'following feed: meSub + default bucket + echo all reach the feed, '
    'surviving 关注→全球→关注 switches',
    () async {
      final me = Identity.fromPrivkeyHex(_priv).pubkeyHex;
      final relayC = _FakeRelay('wss://fake');
      final poolC = RelayPool([relayC]);
      final container = ProviderContainer(
        overrides: [
          relayPoolProvider.overrideWith((ref) => poolC),
          indexerPoolProvider.overrideWith((ref) => RelayPool(const [])),
          localCacheProvider.overrideWith(
            (ref) async => throw StateError('no db in repro'),
          ),
          identityProvider.overrideWith(() => _Id()),
          followingStateProvider.overrideWith(() => _Follows()),
          feedModeProvider.overrideWith(() => _Mode()),
          myMuteSetProvider.overrideWith((ref) => const MuteSet()),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(poolC.dispose);
      await poolC.connect();

      // Keep the full chain alive.
      final sub = container.listen(currentFeedEventsProvider, (_, _) {});
      addTearDown(sub.close);

      // 1. The feed-me REQ must be issued (synchronously at provider build).
      final meSub = await _pollFor(() => relayC.subIdFor('feed-me'));

      // 2. Relay delivers the user's own post on feed-me → into feed.
      relayC.emitTagged(meSub, _note(id: 'own-old', pubkey: me, createdAt: 100));
      await _pollFor(() =>
          container.read(currentFeedEventsProvider).any((e) => e.id == 'own-old')
              ? true
              : null);

      // 3. Default-bucket sub appears (after the ~5s relay-list timeout, since
      //    the followee has no published kind-10002) and delivers a followee
      //    post → into feed.
      final fbSub = await _pollFor(() => relayC.subIdFor('feed-follows'));
      relayC.emitTagged(
        fbSub,
        _note(id: 'foll-1', pubkey: _followee, createdAt: 200),
      );
      await _pollFor(() =>
          container.read(currentFeedEventsProvider).any((e) => e.id == 'foll-1')
              ? true
              : null);

      // 4. PUBLISH ECHO: publishAndWait echoes into the merged stream; the
      //    own post must show in the following feed.
      poolC.publish(_note(id: 'own-new', pubkey: me, createdAt: 300));
      await _pollFor(() =>
          container.read(currentFeedEventsProvider).any((e) => e.id == 'own-new')
              ? true
              : null);

      // 5. TAB SWITCH 关注→全球→关注 — followingOutboxProvider rebuilds; new
      //    feed-me + default-bucket REQs must be issued and keep delivering.
      container.read(feedModeProvider.notifier).set(FeedMode.global);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      container.read(feedModeProvider.notifier).set(FeedMode.following);

      final meSub2 = await _pollFor(() {
        final s = relayC.subIdFor('feed-me');
        return (s != null && s != meSub) ? s : null;
      });
      relayC.emitTagged(
        meSub2,
        _note(id: 'own-newer', pubkey: me, createdAt: 400),
      );
      final fbSub2 = await _pollFor(() {
        final s = relayC.subIdFor('feed-follows');
        return (s != null && s != fbSub) ? s : null;
      });
      relayC.emitTagged(
        fbSub2,
        _note(id: 'foll-2', pubkey: _followee, createdAt: 500),
      );
      await _pollFor(() => container
              .read(currentFeedEventsProvider)
              .any((e) => e.id == 'own-newer')
          ? true
          : null);
      await _pollFor(() => container
              .read(currentFeedEventsProvider)
              .any((e) => e.id == 'foll-2')
          ? true
          : null);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
