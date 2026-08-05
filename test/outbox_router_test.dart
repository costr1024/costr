// Tests for the following-feed NIP-65 outbox router. Reuses the _FakeRelay
// pattern from relay_pool_test.dart — no network I/O; frames are emitted
// manually.

import 'dart:async';

import 'package:costr/models/event.dart';
import 'package:costr/nostr/identity.dart';
import 'package:costr/nostr/outbox_router.dart';
import 'package:costr/nostr/relay_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fake relay connection for OutboxRouter tests — no network, manual frames.
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

  final List<List<dynamic>> sent = [];
  bool _connected = false;
  bool disposed = false;
  void Function()? _onConnected;
  void Function()? _onDisconnected;

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
  void setOnDisconnected(void Function() cb) => _onDisconnected = cb;

  @override
  Future<void> dispose() async {
    disposed = true;
    _connected = false;
    await _events.close();
    await _eose.close();
    await _notices.close();
    await _oks.close();
    await _auths.close();
  }

  void emit(Event e) => _events.add(e);
  void emitEose(String subId) => _eose.add(subId);
  void emitAuth(String challenge) => _auths.add(challenge);
  void markDisconnected() {
    _connected = false;
    _onDisconnected?.call();
  }

  /// The subIds of all REQ frames sent so far (in send order).
  List<String> get reqSubIds =>
      sent.where((m) => m[0] == 'REQ').map((m) => m[1] as String).toList();
}

Event _event(String id, {String pubkey = 'pk'}) => Event(
  id: id,
  pubkey: pubkey,
  createdAt: 1,
  kind: 1,
  tags: const [],
  content: 'c',
  sig: 's' * 128,
);

/// Build an OutboxRouter whose clients are the provided fakes, keyed by URL.
({OutboxRouter router, Map<String, _FakeRelay> fakes}) _router(
  Map<String, _FakeRelay> fakes,
) {
  final r = OutboxRouter(
    makeClient: (url) => fakes[url]!,
    identityGetter: () => null,
  );
  return (router: r, fakes: fakes);
}

void main() {
  group('OutboxRouter.start', () {
    test('groups authors per relay (2 relays x 3 authors)', () async {
      final fakes = {
        'wss://a': _FakeRelay('wss://a'),
        'wss://b': _FakeRelay('wss://b'),
      };
      final r = _router(fakes).router;
      await r.start({
        'wss://a': ['a1', 'a2', 'a3'],
        'wss://b': ['b1', 'b2', 'b3'],
      });

      final aReq = fakes['wss://a']!.sent.where((m) => m[0] == 'REQ').single;
      expect(aReq[2]['authors'], ['a1', 'a2', 'a3']);
      expect(aReq[2]['limit'], 500); // cold page deepened (was 200)

      final bReq = fakes['wss://b']!.sent.where((m) => m[0] == 'REQ').single;
      expect(bReq[2]['authors'], ['b1', 'b2', 'b3']);
      await r.close();
    });

    test('chunks authors at 200 per REQ (500 authors → 3 REQs)', () async {
      final fakes = {'wss://a': _FakeRelay('wss://a')};
      final r = _router(fakes).router;
      final authors = [for (var i = 0; i < 500; i++) 'pk$i'];
      await r.start({'wss://a': authors});
      final reqs = fakes['wss://a']!.sent.where((m) => m[0] == 'REQ').toList();
      expect(reqs.length, 3);
      expect((reqs[0][2]['authors'] as List).length, 200);
      expect((reqs[1][2]['authors'] as List).length, 200);
      expect((reqs[2][2]['authors'] as List).length, 100);
      await r.close();
    });

    test('since raises limit to 500 (incremental refresh)', () async {
      final fakes = {'wss://a': _FakeRelay('wss://a')};
      final r = _router(fakes).router;
      await r.start({
        'wss://a': ['pk'],
      }, since: 12345);
      final req = fakes['wss://a']!.sent.where((m) => m[0] == 'REQ').single;
      expect(req[2]['limit'], 500);
      expect(req[2]['since'], 12345);
      await r.close();
    });

    test(
      'dedups the same event arriving from two relays (onEvent once)',
      () async {
        final fakes = {
          'wss://a': _FakeRelay('wss://a'),
          'wss://b': _FakeRelay('wss://b'),
        };
        final r = _router(fakes).router;
        final seen = <Event>[];
        await r.start({
          'wss://a': ['pa'],
          'wss://b': ['pb'],
        }, onEvent: seen.add);
        final ev = _event('shared', pubkey: 'pa');
        fakes['wss://a']!.emit(ev);
        fakes['wss://b']!.emit(ev); // duplicate from the other relay
        await Future<void>.delayed(Duration.zero);
        expect(seen.length, 1);
        await r.close();
      },
    );

    test('live: no CLOSE sent on EOSE (subscription stays open)', () async {
      final fakes = {'wss://a': _FakeRelay('wss://a')};
      final r = _router(fakes).router;
      await r.start({
        'wss://a': ['pk'],
      });
      final subId = fakes['wss://a']!.reqSubIds.single;
      fakes['wss://a']!.emitEose(subId);
      await Future<void>.delayed(Duration.zero);
      expect(fakes['wss://a']!.sent.where((m) => m[0] == 'CLOSE'), isEmpty);
      await r.close();
    });

    test('reconnect re-issues REQs (setOnConnected hook)', () async {
      final fakes = {'wss://a': _FakeRelay('wss://a')};
      final r = _router(fakes).router;
      await r.start({
        'wss://a': ['pk'],
      });
      expect(fakes['wss://a']!.reqSubIds.length, 1);
      // Network blip → socket drops, then reconnects. RelayClient only re-opens
      // the socket; the router's setOnConnected hook must re-send the REQ.
      fakes['wss://a']!.markDisconnected();
      await fakes['wss://a']!.connect(); // triggers _onConnected → _issueReqs
      expect(fakes['wss://a']!.reqSubIds.length, 2); // original + re-issue
      // Same subId reused (Nostr refresh semantics), not a new id.
      expect(fakes['wss://a']!.reqSubIds.toSet().length, 1);
      await r.close();
    });
  });

  group('OutboxRouter.fetchOnce', () {
    test('closes on EOSE and returns collected events', () async {
      final fakes = {'wss://a': _FakeRelay('wss://a')};
      final r = _router(fakes).router;
      final seen = <Event>[];
      final done = r.fetchOnce(
        {
          'wss://a': ['pk'],
        },
        until: 99,
        onEvent: seen.add,
      );
      // The REQ should carry the `until` cursor.
      await Future<void>.delayed(Duration.zero);
      final req = fakes['wss://a']!.sent.where((m) => m[0] == 'REQ').single;
      expect(req[2]['until'], 99);
      fakes['wss://a']!.emit(_event('e1', pubkey: 'pk'));
      fakes['wss://a']!.emitEose(req[1] as String);
      final result = await done;
      expect(result.length, 1);
      expect(seen.length, 1); // streamed via onEvent too
      // Subscription closed after EOSE.
      expect(fakes['wss://a']!.sent.where((m) => m[0] == 'CLOSE'), isNotEmpty);
      expect(fakes['wss://a']!.disposed, isTrue);
    });

    test('kinds defaults to the live set; pagination narrows to posts',
        () async {
      final fakes = {'wss://a': _FakeRelay('wss://a')};
      final r = _router(fakes).router;
      final done = r.fetchOnce({
        'wss://a': ['pk'],
      }, until: 99);
      await Future<void>.delayed(Duration.zero);
      var req = fakes['wss://a']!.sent.where((m) => m[0] == 'REQ').single;
      expect(req[2]['kinds'], [0, 1, 6, 7]);
      fakes['wss://a']!.emitEose(req[1] as String);
      await done;

      // Backward pagination spends the per-relay limit on POSTS only.
      final fakes2 = {'wss://a': _FakeRelay('wss://a')};
      final r2 = _router(fakes2).router;
      final done2 = r2.fetchOnce({
        'wss://a': ['pk'],
      }, until: 99, kinds: const [1, 6]);
      await Future<void>.delayed(Duration.zero);
      req = fakes2['wss://a']!.sent.where((m) => m[0] == 'REQ').single;
      expect(req[2]['kinds'], [1, 6]);
      fakes2['wss://a']!.emitEose(req[1] as String);
      await done2;
    });

    test('dedups across relays within a one-shot fetch', () async {
      final fakes = {
        'wss://a': _FakeRelay('wss://a'),
        'wss://b': _FakeRelay('wss://b'),
      };
      final r = _router(fakes).router;
      final done = r.fetchOnce({
        'wss://a': ['pa'],
        'wss://b': ['pb'],
      });
      await Future<void>.delayed(Duration.zero);
      final aSub = fakes['wss://a']!.reqSubIds.single;
      final bSub = fakes['wss://b']!.reqSubIds.single;
      final ev = _event('shared', pubkey: 'pa');
      fakes['wss://a']!.emit(ev);
      fakes['wss://b']!.emit(ev);
      fakes['wss://a']!.emitEose(aSub);
      fakes['wss://b']!.emitEose(bSub);
      final result = await done;
      expect(result.length, 1);
    });
  });

  group('OutboxRouter.close', () {
    test('closes every subId + disposes every client', () async {
      final fakes = {
        'wss://a': _FakeRelay('wss://a'),
        'wss://b': _FakeRelay('wss://b'),
      };
      final r = _router(fakes).router;
      await r.start({
        'wss://a': ['pa'],
        'wss://b': ['pb', 'pc'],
      });
      await r.close();
      for (final f in fakes.values) {
        expect(f.disposed, isTrue);
        expect(
          f.sent.where((m) => m[0] == 'CLOSE').length,
          f.reqSubIds.toSet().length,
        );
      }
    });
  });

  group('OutboxRouter NIP-42 AUTH', () {
    test('signs kind-22242 challenge with the identity getter', () async {
      // Identity with a fixed privkey so the signature is deterministic-ish.
      final identity = Identity.fromPrivkeyHex('1' * 64);
      final fakes = {'wss://a': _FakeRelay('wss://a')};
      final r = OutboxRouter(
        makeClient: (url) => fakes[url]!,
        identityGetter: () => identity,
      );
      await r.start({
        'wss://a': ['pk'],
      });
      fakes['wss://a']!.emitAuth('challenge-xyz');
      await Future<void>.delayed(Duration.zero);
      final authFrame = fakes['wss://a']!.sent
          .where((m) => m[0] == 'AUTH')
          .single;
      final ev = authFrame[1] as Map<String, dynamic>;
      expect(ev['kind'], 22242);
      // Tags carry the relay url + the challenge.
      final tags = (ev['tags'] as List).cast<List>();
      expect(tags.any((t) => t[0] == 'relay' && t[1] == 'wss://a'), isTrue);
      expect(
        tags.any((t) => t[0] == 'challenge' && t[1] == 'challenge-xyz'),
        isTrue,
      );
      await r.close();
    });
  });
}
