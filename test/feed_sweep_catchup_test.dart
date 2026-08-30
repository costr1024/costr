// Regression test: the following-feed catch-up sweep must heal a feed whose
// live subscriptions died silently — strictly-newer own + followee posts are
// fetched over one-shot REQs routed straight into the store ("关注流停更，刷
// 新无效，重启才好" root-cause safety net).

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

/// Hand a provider Ref to the test (runFollowingCatchUp takes a Ref).
final _refHolder = Provider<Ref>((ref) => ref);

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
  void set(FeedMode m) => state = m;
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
  Duration timeout = const Duration(seconds: 12),
}) async {
  final sw = Stopwatch()..start();
  while (true) {
    final v = probe();
    if (v != null) return v;
    if (sw.elapsed > timeout) fail('condition not met within $timeout');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

void main() {
  test('sweep catches up own + followee posts missed by dead live subs',
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

    final sub = container.listen(currentFeedEventsProvider, (_, _) {});
    addTearDown(sub.close);
    // The store wipes itself when identity resolves (account-switch guard),
    // so seed only AFTER the identity is settled.
    await container.read(identityProvider.future);
    final store = container.read(eventStoreProvider.notifier);

    // Seed: the store holds an older own post + followee post (the sweep's
    // `since` cursors).
    await store.ingest(_note(id: 'own-old', pubkey: me, createdAt: 100));
    await store.ingest(
      _note(id: 'foll-old', pubkey: _followee, createdAt: 200),
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));

    // The live subs are "dead": only the sweep's one-shot REQs can bring the
    // newer posts. Run the sweep and answer its REQs as the relay would.
    final sweepFuture = runFollowingCatchUp(
      container.read(_refHolder),
      Identity.fromPrivkeyHex(_priv),
      const [_followee],
    );

    // 1. Own-post catch-up REQ → deliver the newer own post.
    final sweepMe = await _pollFor(() => relayC.subIdFor('sweep-me'));
    relayC.emitTagged(
      sweepMe,
      _note(id: 'own-new', pubkey: me, createdAt: 300),
    );
    relayC.emitEose(sweepMe);

    // 2. Followee catch-up (followee has no kind-10002 → relay-list lookup
    //    times out → default bucket) → deliver the newer followee post.
    final sweepFb = await _pollFor(() => relayC.subIdFor('sweep-follows'));
    relayC.emitTagged(
      sweepFb,
      _note(id: 'foll-new', pubkey: _followee, createdAt: 400),
    );
    relayC.emitEose(sweepFb);

    await sweepFuture;
    await Future<void>.delayed(const Duration(milliseconds: 300));

    final ids = container
        .read(currentFeedEventsProvider)
        .map((e) => e.id)
        .toList();
    expect(ids, containsAll(['own-new', 'foll-new']),
        reason: 'sweep must heal the feed with the missed posts');
  }, timeout: const Timeout(Duration(seconds: 60)));
}
