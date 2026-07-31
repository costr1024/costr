import 'dart:async';

import 'package:costr/models/event.dart';
import 'package:costr/nostr/identity.dart';
import 'package:costr/nostr/relay_client.dart';
import 'package:costr/nostr/relay_pool.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fake relay connection for pool tests — no network, manually emit frames.
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
    await _events.close();
    await _eose.close();
    await _notices.close();
    await _oks.close();
    await _auths.close();
  }

  void emit(Event e) => _events.add(e);
  void emitEose(String subId) => _eose.add(subId);
  void emitOk(RelayOk ok) => _oks.add(ok);
  void emitAuth(String challenge) => _auths.add(challenge);
  void markDisconnected() {
    _connected = false;
    _onDisconnected?.call();
  }
}

Event _event(String id, {String content = 'x'}) => Event(
  id: id,
  pubkey: 'p' * 64,
  createdAt: 1,
  kind: 1,
  tags: const [],
  content: content,
  sig: 's' * 128,
);

void main() {
  group('RelayPool', () {
    test('connect() connects all relays and wires merged stream', () async {
      final a = _FakeRelay('wss://a');
      final b = _FakeRelay('wss://b');
      final pool = RelayPool([a, b]);
      await pool.connect();
      expect(a.isConnected, isTrue);
      expect(b.isConnected, isTrue);
      await pool.dispose();
    });

    test('request() sends REQ to every connected relay', () async {
      final a = _FakeRelay('wss://a');
      final b = _FakeRelay('wss://b');
      final pool = RelayPool([a, b]);
      await pool.connect();
      pool.request('costr:feed:1', {
        'kinds': [1],
        'limit': 200,
      });
      expect(a.sent, [
        [
          'REQ',
          'costr:feed:1',
          {
            'kinds': [1],
            'limit': 200,
          },
        ],
      ]);
      expect(b.sent, [
        [
          'REQ',
          'costr:feed:1',
          {
            'kinds': [1],
            'limit': 200,
          },
        ],
      ]);
      await pool.dispose();
    });

    test('NIP-42: signs kind-22242 + sendAuth on AUTH challenge', () async {
      final a = _FakeRelay('wss://relay.bostr.online/');
      final pool = RelayPool([a]);
      final id = Identity.fromPrivkeyHex(
        '0000000000000000000000000000000000000000000000000000000000000001',
      );
      pool.identityGetter = () => id;
      await pool.connect();

      a.emitAuth('challenge-xyz');
      await Future<void>.delayed(Duration.zero);

      final authMsg = a.sent.where((m) => m[0] == 'AUTH').toList();
      expect(authMsg.length, 1);
      final ev = authMsg[0][1] as Map<String, dynamic>;
      expect(ev['kind'], 22242);
      expect(ev['content'], '');
      expect(ev['tags'], [
        ['relay', 'wss://relay.bostr.online/'],
        ['challenge', 'challenge-xyz'],
      ]);
      expect((ev['sig'] as String).length, 128);
      expect(
        id.verifyEventSignature(
          id: ev['id'] as String,
          sig: ev['sig'] as String,
        ),
        isTrue,
      );
      await pool.dispose();
    });

    test('closeSubscription() sends CLOSE to every relay', () async {
      final a = _FakeRelay('wss://a');
      final pool = RelayPool([a]);
      await pool.connect();
      pool.request('s', {
        'kinds': [1],
      });
      pool.closeSubscription('s');
      expect(a.sent.last, ['CLOSE', 's']);
      await pool.dispose();
    });

    test('merged stream dedups events by id across relays', () async {
      final a = _FakeRelay('wss://a');
      final b = _FakeRelay('wss://b');
      final pool = RelayPool([a, b]);
      await pool.connect();
      final received = <Event>[];
      final sub = pool.events.listen(received.add);

      a.emit(_event('id1'));
      b.emit(_event('id1')); // duplicate
      a.emit(_event('id2'));
      await Future<void>.delayed(Duration.zero);

      expect(received.map((e) => e.id), ['id1', 'id2']);
      await sub.cancel();
      await pool.dispose();
    });

    test(
      'rawEvents re-emits an event already seen on the deduped stream',
      () async {
        // Regression for bug 3: the profile 关注/关注者 tabs re-fetch a user's
        // kind-3, but the global feed already saw it → the deduped `events`
        // stream swallowed the re-send → empty follows list. rawEvents must
        // re-emit it so targeted fetches work.
        final a = _FakeRelay('wss://a');
        final pool = RelayPool([a]);
        await pool.connect();
        final deduped = <String>[];
        final raw = <String>[];
        final s1 = pool.events.listen((e) => deduped.add(e.id));
        final s2 = pool.rawEvents.listen((e) => raw.add(e.id));

        a.emit(_event('id1'));
        await Future<void>.delayed(Duration.zero);
        // A second subscription re-sends the same event.
        a.emit(_event('id1'));
        await Future<void>.delayed(Duration.zero);

        expect(deduped, ['id1']); // deduped stream: only once
        expect(raw, ['id1', 'id1']); // raw stream: every send
        await s1.cancel();
        await s2.cancel();
        await pool.dispose();
      },
    );

    test('reconnect re-issues active subscriptions to that relay', () async {
      final a = _FakeRelay('wss://a');
      final pool = RelayPool([a]);
      await pool.connect();
      pool.request('costr:feed:9', {
        'kinds': [1],
      });
      a.sent.clear();

      // Simulate a drop + reconnect.
      a.markDisconnected();
      await a.connect(); // reconnect triggers onConnected → _resendActive
      expect(a.sent, [
        [
          'REQ',
          'costr:feed:9',
          {
            'kinds': [1],
          },
        ],
      ]);
      await pool.dispose();
    });

    test('relays down during request get the sub on later connect', () async {
      final a = _FakeRelay('wss://a');
      final pool = RelayPool([a]);
      // Issue a sub while a is NOT connected (don't call pool.connect first).
      pool.request('costr:feed:5', {
        'kinds': [1],
      });
      expect(a.sent, isEmpty); // a wasn't connected, so nothing sent yet

      await pool
          .connect(); // wires onConnected; a.connect() → onConnected → resend active
      expect(a.sent, [
        [
          'REQ',
          'costr:feed:5',
          {
            'kinds': [1],
          },
        ],
      ]);
      await pool.dispose();
    });

    test('closeOnEose closes only after ALL relays EOSE', () async {
      final a = _FakeRelay('wss://a');
      final b = _FakeRelay('wss://b');
      final pool = RelayPool([a, b]);
      await pool.connect();
      pool.request('costr:feed:7', {
        'kinds': [1],
        'limit': 200,
      }, closeOnEose: true);

      // First EOSE (from a) does NOT close — b hasn't EOSE'd yet.
      a.emitEose('costr:feed:7');
      await Future<void>.delayed(Duration.zero);
      expect(a.sent.where((m) => m[0] == 'CLOSE'), isEmpty);

      // Once all relays EOSE, the sub closes everywhere.
      b.emitEose('costr:feed:7');
      await Future<void>.delayed(Duration.zero);
      expect(a.sent.last, ['CLOSE', 'costr:feed:7']);
      expect(b.sent.last, ['CLOSE', 'costr:feed:7']);
      await pool.dispose();
    });
  });
}
