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
  final StreamController<(String, Event)> _tagged =
      StreamController<(String, Event)>.broadcast();
  final StreamController<String> _eose = StreamController<String>.broadcast();
  final StreamController<String> _notices =
      StreamController<String>.broadcast();
  final StreamController<RelayOk> _oks = StreamController<RelayOk>.broadcast();
  final StreamController<String> _auths = StreamController<String>.broadcast();

  final List<List<dynamic>> sent = [];
  bool _connected = false;
  bool wasDisposed = false;
  void Function()? _onConnected;
  void Function()? _onDisconnected;

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
  void setOnDisconnected(void Function() cb) => _onDisconnected = cb;

  @override
  Future<void> dispose() async {
    wasDisposed = true;
    await _events.close();
    await _tagged.close();
    await _eose.close();
    await _notices.close();
    await _oks.close();
    await _auths.close();
  }

  void emit(Event e) {
    _events.add(e);
    if (!_tagged.isClosed) _tagged.add(('sub', e));
  }

  /// Emit under an explicit subId — lets tests exercise the pool's
  /// subscription-scoped routing ([RelayPool.request] `onEvent`).
  void emitTagged(String subId, Event e) {
    _events.add(e);
    if (!_tagged.isClosed) _tagged.add((subId, e));
  }

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

  group('fetchFromUrls (NIP-65 outbox routing)', () {
    test('empty urls → no fetch, empty result', () async {
      final pool = RelayPool([]);
      expect(
        await pool.fetchFromUrls({
          'kinds': [1],
        }, const []),
        isEmpty,
      );
      await pool.dispose();
    });

    test('non-ws urls are skipped', () async {
      final pool = RelayPool([]);
      expect(
        await pool.fetchFromUrls(
          {
            'kinds': [1],
          },
          const ['http://x', 'ftp://y'],
        ),
        isEmpty,
      );
      await pool.dispose();
    });

    test('collects events + dedups by id + closes on EOSE', () async {
      final fake = _FakeRelay('wss://a');
      final pool = RelayPool([])..makeClient = (url) => fake;
      final fut = pool.fetchFromUrls(
        {
          'kinds': [1],
        },
        const ['wss://a'],
      );
      // Let connect() + request() run (async).
      await Future<void>.delayed(Duration.zero);
      final req = fake.sent.where((m) => m[0] == 'REQ').single;
      final subId = req[1] as String;
      fake.emit(_event('e1', content: 'hi'));
      fake.emit(_event('e1')); // dup — deduped
      fake.emitEose(subId);
      final result = await fut;
      expect(result.map((e) => e.id), ['e1']);
      // The transient client was closed + disposed.
      expect(fake.sent.last, ['CLOSE', subId]);
      await pool.dispose();
    });

    test(
      'no EOSE → timeout returns whatever was collected, still disposes',
      () async {
        final fake = _FakeRelay('wss://a');
        final pool = RelayPool([])..makeClient = (url) => fake;
        final fut = pool.fetchFromUrls(
          {
            'kinds': [1],
          },
          const ['wss://a'],
          timeout: const Duration(milliseconds: 50),
        );
        await Future<void>.delayed(Duration.zero);
        // Emit an event but never EOSE.
        fake.emit(_event('e1'));
        final result = await fut;
        expect(result.map((e) => e.id), ['e1']);
        expect(fake.sent.last[0], 'CLOSE'); // disposed regardless
        await pool.dispose();
      },
    );
  });

  group('publishAndWait (per-relay retry spec)', () {
    test('one relay accepts → success, single EVENT send (no retry)', () async {
      final a = _FakeRelay('wss://a');
      final pool = RelayPool([a]);
      await pool.connect();
      final ev = _event('e1');
      final fut = pool.publishAndWait(
        ev,
        retryDelays: const [Duration(milliseconds: 50)],
        perRoundTimeout: const Duration(milliseconds: 200),
      );
      await Future<void>.delayed(Duration.zero);
      a.emitOk(RelayOk(ev.id, true, '', url: 'wss://a'));
      final ok = await fut;
      expect(ok.ok, isTrue);
      expect(a.sent.where((m) => m[0] == 'EVENT').length, 1);
      await pool.dispose();
    });

    test(
      'all relays timeout → foreground retries then fails (4 sends)',
      () async {
        final a = _FakeRelay('wss://a');
        final pool = RelayPool([a]);
        await pool.connect();
        final ev = _event('e1');
        final ok = await pool.publishAndWait(
          ev,
          retryDelays: const [
            Duration(milliseconds: 20),
            Duration(milliseconds: 20),
            Duration(milliseconds: 20),
          ],
          perRoundTimeout: const Duration(milliseconds: 30),
        );
        expect(ok.ok, isFalse);
        // initial round + 3 retries = 4 EVENT sends.
        expect(a.sent.where((m) => m[0] == 'EVENT').length, 4);
        await pool.dispose();
      },
    );

    test('auth-required rejection → foreground retry succeeds', () async {
      final a = _FakeRelay('wss://a');
      final pool = RelayPool([a]);
      await pool.connect();
      final ev = _event('e1');
      final fut = pool.publishAndWait(
        ev,
        retryDelays: const [
          Duration(milliseconds: 30),
          Duration(milliseconds: 30),
          Duration(milliseconds: 30),
        ],
        perRoundTimeout: const Duration(milliseconds: 100),
      );
      await Future<void>.delayed(Duration.zero);
      // Round 0: reject with auth-required (transient).
      a.emitOk(
        RelayOk(ev.id, false, 'auth-required: please auth', url: 'wss://a'),
      );
      // Let the foreground retry delay (30ms) pass + round 1 start.
      await Future<void>.delayed(const Duration(milliseconds: 45));
      a.emitOk(RelayOk(ev.id, true, '', url: 'wss://a'));
      final ok = await fut;
      expect(ok.ok, isTrue);
      expect(
        a.sent.where((m) => m[0] == 'EVENT').length,
        2,
      ); // initial + 1 retry
      await pool.dispose();
    });

    test(
      'no-progress settle: reject + a silent relay does NOT wait the full '
      'round window',
      () async {
        // The «回复偶尔卡几秒» root cause: a connected-but-silent relay keeps
        // `_pending` non-empty, so `early` used to ride out the FULL
        // per-round window before any retry. With the no-progress settle, as
        // soon as one relay has verdicted (rejected) and none accepted, the
        // round settles early and the silent relay is retried right away.
        final rej = _FakeRelay('wss://rej');
        final silent = _FakeRelay('wss://silent');
        final pool = RelayPool([rej, silent]);
        await pool.connect();
        final ev = _event('np1');
        final sw = Stopwatch()..start();
        final fut = pool.publishAndWait(
          ev,
          retryDelays: const [Duration(milliseconds: 20)],
          perRoundTimeout: const Duration(seconds: 5), // long window
          noProgressTimeout: const Duration(milliseconds: 60), // short
        );
        await Future<void>.delayed(Duration.zero);
        // Round 1: rej rejects (non-auth → unrecoverable), silent stays mute.
        rej.emitOk(RelayOk(ev.id, false, 'rate-limited', url: 'wss://rej'));
        // Wait until the retry round re-publishes to the silent relay — this
        // must happen soon after the 60ms no-progress settle, NOT after the
        // 5s window.
        final deadline = DateTime.now().add(const Duration(seconds: 2));
        while (silent.sent.where((m) => m[0] == 'EVENT').length < 2) {
          if (DateTime.now().isAfter(deadline)) break;
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        silent.emitOk(RelayOk(ev.id, true, '', url: 'wss://silent'));
        final ok = await fut;
        sw.stop();
        expect(ok.ok, isTrue);
        // Finished far before the 5s per-round window → early settle worked.
        expect(sw.elapsed, lessThan(const Duration(seconds: 2)));
        // silent got round 1 + the retry round = 2 EVENTs.
        expect(silent.sent.where((m) => m[0] == 'EVENT').length, 2);
        await pool.dispose();
      },
    );

    test(
      'all-auth round retries after the short auth cap, not the long delay',
      () async {
        // The other «卡 1~2s» root cause: an all-auth round waited the FULL
        // configured foreground delay (1s in prod) even though the AUTH
        // handshake completes in ~1 RTT. Now the delay is capped at 300ms.
        final a = _FakeRelay('wss://a');
        final pool = RelayPool([a]);
        await pool.connect();
        final ev = _event('au1');
        final sw = Stopwatch()..start();
        final fut = pool.publishAndWait(
          ev,
          retryDelays: const [Duration(seconds: 3)], // long normal delay
          perRoundTimeout: const Duration(seconds: 5),
          noProgressTimeout: const Duration(seconds: 4),
        );
        await Future<void>.delayed(Duration.zero);
        // Round 1: the single relay rejects with auth-required → all-auth.
        a.emitOk(RelayOk(ev.id, false, 'auth-required', url: 'wss://a'));
        // The retry must land ~300ms later (auth cap), not ~3s later.
        final deadline = DateTime.now().add(const Duration(seconds: 2));
        while (a.sent.where((m) => m[0] == 'EVENT').length < 2) {
          if (DateTime.now().isAfter(deadline)) break;
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        sw.stop();
        a.emitOk(RelayOk(ev.id, true, '', url: 'wss://a'));
        final ok = await fut;
        expect(ok.ok, isTrue);
        expect(sw.elapsed, lessThan(const Duration(seconds: 2)));
        expect(a.sent.where((m) => m[0] == 'EVENT').length, 2);
        await pool.dispose();
      },
    );

    test('unrecoverable rejection → no retry (relay dropped)', () async {
      final a = _FakeRelay('wss://a');
      final pool = RelayPool([a]);
      await pool.connect();
      final ev = _event('e1');
      final fut = pool.publishAndWait(
        ev,
        retryDelays: const [
          Duration(milliseconds: 20),
          Duration(milliseconds: 20),
          Duration(milliseconds: 20),
        ],
        perRoundTimeout: const Duration(milliseconds: 100),
      );
      await Future<void>.delayed(Duration.zero);
      // Explicit non-auth rejection → unrecoverable → no retry.
      a.emitOk(RelayOk(ev.id, false, 'blocked: spam', url: 'wss://a'));
      final ok = await fut;
      expect(ok.ok, isFalse);
      expect(a.sent.where((m) => m[0] == 'EVENT').length, 1); // no retry
      await pool.dispose();
    });

    test(
      'success returns on the FIRST relay ack, not after the slowest',
      () async {
        // Regression for the "发帖/回帖要等 1～3s" latency: the verdict round
        // used to wait for EVERY relay's verdict (or the full per-round cap),
        // so one slow/silent relay made the whole send wait even after a fast
        // relay acked within ~RTT. Now `_PublishRound.early` resolves on the
        // first effective ok.
        final fast = _FakeRelay('wss://fast');
        final slow = _FakeRelay('wss://slow'); // never acks
        final pool = RelayPool([fast, slow]);
        await pool.connect();
        final ev = _event('latency1');
        final sw = Stopwatch()..start();
        final fut = pool.publishAndWait(
          ev,
          retryDelays: const [Duration(milliseconds: 20)],
          perRoundTimeout: const Duration(milliseconds: 250),
        );
        await Future<void>.delayed(Duration.zero);
        fast.emitOk(RelayOk(ev.id, true, '', url: 'wss://fast'));
        final ok = await fut;
        sw.stop();
        expect(ok.ok, isTrue);
        // Pre-fix this blocked until the 250ms round cap waiting for the silent
        // relay; with the fix it returns right after the fast relay's ack.
        expect(sw.elapsed, lessThan(const Duration(milliseconds: 120)));
        await pool.dispose();
      },
    );

    test('failed publish does NOT echo (no phantom); success echoes', () async {
      // Echo must happen ONLY on success. A failed publish used to echo
      // unconditionally → a phantom post in the feed; on retry (new event
      // id) the user saw two identical posts. The fix moves the echo to
      // the success path.
      final a = _FakeRelay('wss://a');
      final pool = RelayPool([a]);
      await pool.connect();
      final echoed = <String>[];
      pool.events.listen((e) => echoed.add(e.id));

      // All-failed publish → no echo.
      final evFail = _event('fail1');
      final okFail = await pool.publishAndWait(
        evFail,
        retryDelays: const [Duration(milliseconds: 10)],
        perRoundTimeout: const Duration(milliseconds: 20),
      );
      expect(okFail.ok, isFalse);
      expect(echoed, isEmpty, reason: 'failed publish must not echo a phantom');

      // Successful publish → echoes the event id.
      final evOk = _event('ok1');
      final fut = pool.publishAndWait(
        evOk,
        retryDelays: const [Duration(milliseconds: 50)],
        perRoundTimeout: const Duration(milliseconds: 200),
      );
      await Future<void>.delayed(Duration.zero);
      a.emitOk(RelayOk(evOk.id, true, '', url: 'wss://a'));
      final okResult = await fut;
      expect(okResult.ok, isTrue, reason: 'success path must be reached');
      // The echo is delivered on a microtask (broadcast controller is async);
      // pump once so the listener drains before we assert.
      await Future<void>.delayed(Duration.zero);
      expect(echoed, contains(evOk.id));
      await pool.dispose();
    });

    test('onWriteVerdict records explicit accept/reject; silent relays NOT '
        'recorded', () async {
      // Write success-rate statistics must only count EXPLICIT verdicts:
      // publishAndWait returns early on the first accept, so a relay without
      // a verdict was usually just slower — recording it as a failure would
      // frame every healthy-but-slow relay as broken. Verdicts are recorded
      // as they arrive (_PublishRound), including ones landing just before
      // the first accept closes the round.
      final a = _FakeRelay('wss://a');
      final b = _FakeRelay('wss://b');
      final silent = _FakeRelay('wss://silent');
      final pool = RelayPool([a, b, silent]);
      await pool.connect();
      final verdicts = <String, bool>{};
      pool.onWriteVerdict = (url, ok, reason) => verdicts[url] = ok;
      final ev = _event('wv1');
      final fut = pool.publishAndWait(
        ev,
        retryDelays: const [Duration(milliseconds: 20)],
        perRoundTimeout: const Duration(milliseconds: 60),
      );
      await Future<void>.delayed(Duration.zero);
      // Rejection FIRST so it lands in the round before a's accept closes
      // it (the accept ends the round asynchronously; whatever is still in
      // the delivery chain at that instant is a race the test must not
      // depend on).
      b.emitOk(RelayOk(ev.id, false, 'blocked', url: 'wss://b'));
      a.emitOk(RelayOk(ev.id, true, '', url: 'wss://a'));
      final ok = await fut;
      expect(ok.ok, isTrue);
      expect(verdicts, {'wss://a': true, 'wss://b': false});
      expect(
        verdicts.containsKey('wss://silent'),
        isFalse,
        reason: 'no verdict in the window ≠ failure',
      );
      await pool.dispose();
    });

    test('onWriteVerdict: timeout-only rounds record nothing', () async {
      // A relay that never acks makes the publish fail, but the stats stay
      // empty — unreachable relays surface as 离线 on the node page instead;
      // the success-rate warning is for relays that REJECT writes.
      final a = _FakeRelay('wss://a');
      final pool = RelayPool([a]);
      await pool.connect();
      final verdicts = <String, bool>{};
      pool.onWriteVerdict = (url, ok, reason) => verdicts[url] = ok;
      final ev = _event('wv2');
      final ok = await pool.publishAndWait(
        ev,
        retryDelays: const [Duration(milliseconds: 10)],
        perRoundTimeout: const Duration(milliseconds: 20),
      );
      expect(ok.ok, isFalse);
      expect(verdicts, isEmpty);
      await pool.dispose();
    });

    test(
      'onWriteVerdict: NIP-42 auth-required is NOT recorded (transient)',
      () async {
        // An auth-required rejection is the NIP-42 handshake, not a write
        // failure: the pool answers the AUTH challenge and retries. Counting it
        // against the relay is what made healthy auth-gated relays (e.g. the
        // user's own relay.bostr.online) show a falsely-low 发帖成功率.
        final fast = _FakeRelay('wss://fast');
        final auth = _FakeRelay('wss://auth');
        final pool = RelayPool([fast, auth]);
        await pool.connect();
        final verdicts = <String, bool>{};
        pool.onWriteVerdict = (url, ok, reason) => verdicts[url] = ok;
        final ev = _event('wv3');
        final fut = pool.publishAndWait(
          ev,
          retryDelays: const [Duration(milliseconds: 30)],
          perRoundTimeout: const Duration(milliseconds: 60),
        );
        await Future<void>.delayed(Duration.zero);
        // fast accepts (success); auth rejects with auth-required (transient).
        fast.emitOk(RelayOk(ev.id, true, '', url: 'wss://fast'));
        auth.emitOk(
          RelayOk(
            ev.id,
            false,
            'auth-required: please auth',
            url: 'wss://auth',
          ),
        );
        final ok = await fut;
        expect(ok.ok, isTrue);
        // Only fast's acceptance is recorded; the auth rejection is skipped.
        expect(verdicts, {'wss://fast': true});
        expect(verdicts.containsKey('wss://auth'), isFalse);
        await pool.dispose();
      },
    );

    test(
      'onWriteVerdict: duplicate:false counts as success (event stored)',
      () async {
        // A relay answering ok:false with a `duplicate:` reason already HAS the
        // event (NIP-20) — that is a successful publish outcome, not a failure,
        // and must not be retried.
        final fast = _FakeRelay('wss://fast');
        final dup = _FakeRelay('wss://dup');
        final pool = RelayPool([fast, dup]);
        await pool.connect();
        final verdicts = <String, bool>{};
        pool.onWriteVerdict = (url, ok, reason) => verdicts[url] = ok;
        final ev = _event('wv4');
        final fut = pool.publishAndWait(
          ev,
          retryDelays: const [Duration(milliseconds: 30)],
          perRoundTimeout: const Duration(milliseconds: 60),
        );
        await Future<void>.delayed(Duration.zero);
        fast.emitOk(RelayOk(ev.id, true, '', url: 'wss://fast'));
        dup.emitOk(
          RelayOk(ev.id, false, 'duplicate: have this event', url: 'wss://dup'),
        );
        final ok = await fut;
        expect(ok.ok, isTrue);
        // dup's duplicate:false lands a hair after fast's accept closed the
        // round early; flush the delivery chain so it is recorded.
        await Future<void>.delayed(const Duration(milliseconds: 5));
        // dup's duplicate:false is normalized to success (effectiveOk).
        expect(verdicts, {'wss://fast': true, 'wss://dup': true});
        // dup was published exactly once — a duplicate is never re-sent.
        expect(dup.sent.where((m) => m[0] == 'EVENT').length, 1);
        await pool.dispose();
      },
    );

    test('slow relay late verdict is recorded and NOT re-sent', () async {
      // After the first relay accepts, publishAndWait returns early but keeps
      // collecting until the round window closes. A slower relay whose OK
      // lands within that window must be recorded as a success and must NOT
      // receive a duplicate background re-send (the old behavior re-sent to
      // every relay that was merely slower than the fastest).
      final fast = _FakeRelay('wss://fast');
      final slow = _FakeRelay('wss://slow');
      final pool = RelayPool([fast, slow]);
      await pool.connect();
      final verdicts = <String, bool>{};
      pool.onWriteVerdict = (url, ok, reason) => verdicts[url] = ok;
      final ev = _event('wv5');
      final fut = pool.publishAndWait(
        ev,
        retryDelays: const [Duration(milliseconds: 10)],
        perRoundTimeout: const Duration(milliseconds: 80),
      );
      await Future<void>.delayed(Duration.zero);
      fast.emitOk(RelayOk(ev.id, true, '', url: 'wss://fast'));
      final ok = await fut;
      expect(ok.ok, isTrue);
      // The slow relay answers a moment later, still inside the 80ms window.
      await Future<void>.delayed(const Duration(milliseconds: 5));
      slow.emitOk(RelayOk(ev.id, true, '', url: 'wss://slow'));
      // Let the settled-window continuation run.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(verdicts, {'wss://fast': true, 'wss://slow': true});
      // slow was published exactly once — NO duplicate background re-send.
      expect(slow.sent.where((m) => m[0] == 'EVENT').length, 1);
      await pool.dispose();
    });
  });

  group('updateUrls (hot-swap of the relay set)', () {
    test(
      'kept URLs reuse the SAME connection; removed ones are disposed',
      () async {
        final a = _FakeRelay('wss://a');
        final b = _FakeRelay('wss://b');
        final pool = RelayPool([a, b]);
        await pool.connect();
        await pool.updateUrls(['wss://a']);
        // dispose fires via unawaited → pump once.
        await Future<void>.delayed(Duration.zero);
        expect(pool.states.map((s) => s.url), ['wss://a']);
        expect(a.isConnected, isTrue, reason: 'kept relay must not reconnect');
        expect(a.wasDisposed, isFalse);
        expect(b.wasDisposed, isTrue, reason: 'removed relay must be disposed');
        await pool.dispose();
      },
    );

    test(
      'on a wired pool: new URL connects, joins merged stream, re-gets subs',
      () async {
        final a = _FakeRelay('wss://a');
        final pool = RelayPool([a]);
        await pool.connect();
        pool.request('costr:feed:1', {
          'kinds': [1],
        });

        final fresh = _FakeRelay('wss://n');
        pool.makeClient = (url) => fresh;
        await pool.updateUrls(['wss://a', 'wss://n']);

        // New connection was connected...
        expect(fresh.isConnected, isTrue);
        // ...and the active subscription was re-issued to it on connect.
        expect(fresh.sent, [
          [
            'REQ',
            'costr:feed:1',
            {
              'kinds': [1],
            },
          ],
        ]);
        // Its events reach the pool's merged stream.
        final got = <String>[];
        final sub = pool.events.listen((e) => got.add(e.id));
        fresh.emit(_event('from-new'));
        await Future<void>.delayed(Duration.zero);
        expect(got, ['from-new']);
        await sub.cancel();
        await pool.dispose();
      },
    );

    test(
      'never-connected pool: plain swap, later connect() covers new set',
      () async {
        final a = _FakeRelay('wss://a');
        final pool = RelayPool([a]);
        final fresh = _FakeRelay('wss://n');
        pool.makeClient = (url) => fresh;

        await pool.updateUrls(['wss://n']);
        expect(fresh.isConnected, isFalse, reason: 'no premature connect');
        await Future<void>.delayed(Duration.zero);
        expect(a.wasDisposed, isTrue);

        await pool.connect();
        expect(fresh.isConnected, isTrue);
        expect(pool.states.map((s) => s.url), ['wss://n']);
        await pool.dispose();
      },
    );

    test('status stream emits the new set', () async {
      final pool = RelayPool([_FakeRelay('wss://a')]);
      await pool.connect();
      final snapshots = <List<String>>[];
      final sub = pool.statusStream.listen(
        (list) => snapshots.add(list.map((s) => s.url).toList()),
      );
      await Future<void>.delayed(Duration.zero); // initial snapshot

      pool.makeClient = (url) => _FakeRelay(url);
      await pool.updateUrls(['wss://x', 'wss://y']);
      await Future<void>.delayed(Duration.zero);

      expect(snapshots.isNotEmpty, isTrue);
      expect(snapshots.last, ['wss://x', 'wss://y']);
      await sub.cancel();
      await pool.dispose();
    });

    test('whitespace/duplicate entries collapse; empties dropped', () async {
      final a = _FakeRelay('wss://a');
      final pool = RelayPool([a]);
      await pool.connect();
      var created = 0;
      pool.makeClient = (url) {
        created++;
        return _FakeRelay(url);
      };
      await pool.updateUrls(['wss://a', ' wss://a ', '', '   ']);
      expect(created, 0, reason: 'no new connection for dup/blank entries');
      expect(pool.states.map((s) => s.url), ['wss://a']);
      expect(a.wasDisposed, isFalse);
      await pool.dispose();
    });
  });

  group('subscription-scoped routing (onEvent)', () {
    // The global firehose must NEVER reach the merged streams: the capped
    // EventStore is reserved for the following feed + related events. A
    // request() with onEvent routes every event arriving under that subId to
    // the handler ONLY.
    test(
      'routed sub events go to the handler, not to events/rawEvents',
      () async {
        final a = _FakeRelay('wss://a');
        final pool = RelayPool([a]);
        await pool.connect();
        final routed = <String>[];
        final merged = <String>[];
        final raw = <String>[];
        final s1 = pool.events.listen((e) => merged.add(e.id));
        final s2 = pool.rawEvents.listen((e) => raw.add(e.id));

        pool.request('costr:global:1', {
          'kinds': [1],
        }, onEvent: (e) => routed.add(e.id));
        a.emitTagged('costr:global:1', _event('firehose1'));
        await Future<void>.delayed(Duration.zero);

        expect(routed, ['firehose1']);
        expect(
          merged,
          isEmpty,
          reason: 'routed events must skip merged stream',
        );
        expect(raw, isEmpty, reason: 'routed events must skip raw stream');
        await s1.cancel();
        await s2.cancel();
        await pool.dispose();
      },
    );

    test('unrouted subs still flow to the merged streams', () async {
      final a = _FakeRelay('wss://a');
      final pool = RelayPool([a]);
      await pool.connect();
      final routed = <String>[];
      final merged = <String>[];
      final s1 = pool.events.listen((e) => merged.add(e.id));

      pool.request('costr:global:1', {
        'kinds': [1],
      }, onEvent: (e) => routed.add(e.id));
      pool.request('costr:feed:1', {
        'kinds': [1],
      });
      // Same event arrives under BOTH subs (relays echo one EVENT frame per
      // matching subscription): the routed arrival is handler-only, the
      // unrouted arrival takes the normal merged path.
      a.emitTagged('costr:global:1', _event('dup1'));
      a.emitTagged('costr:feed:1', _event('dup1'));
      await Future<void>.delayed(Duration.zero);

      expect(routed, ['dup1']);
      expect(merged, ['dup1']);
      await s1.cancel();
      await pool.dispose();
    });

    test(
      'closeSubscription removes the route (later events merge normally)',
      () async {
        final a = _FakeRelay('wss://a');
        final pool = RelayPool([a]);
        await pool.connect();
        final routed = <String>[];
        final merged = <String>[];
        final s1 = pool.events.listen((e) => merged.add(e.id));

        pool.request('costr:global:1', {
          'kinds': [1],
        }, onEvent: (e) => routed.add(e.id));
        pool.closeSubscription('costr:global:1');
        a.emitTagged('costr:global:1', _event('late1'));
        await Future<void>.delayed(Duration.zero);

        expect(routed, isEmpty, reason: 'route must be gone after CLOSE');
        expect(merged, ['late1']);
        await s1.cancel();
        await pool.dispose();
      },
    );

    test(
      'closeOnEose still closes a routed sub after ALL relays EOSE',
      () async {
        final a = _FakeRelay('wss://a');
        final b = _FakeRelay('wss://b');
        final pool = RelayPool([a, b]);
        await pool.connect();
        pool.request(
          'costr:global:9',
          {
            'kinds': [1],
          },
          closeOnEose: true,
          onEvent: (e) {},
        );

        a.emitEose('costr:global:9');
        await Future<void>.delayed(Duration.zero);
        expect(a.sent.where((m) => m[0] == 'CLOSE'), isEmpty);

        b.emitEose('costr:global:9');
        await Future<void>.delayed(Duration.zero);
        expect(a.sent.last, ['CLOSE', 'costr:global:9']);
        expect(b.sent.last, ['CLOSE', 'costr:global:9']);
        await pool.dispose();
      },
    );

    test(
      'request without onEvent UN-routes a previously routed subId',
      () async {
        final a = _FakeRelay('wss://a');
        final pool = RelayPool([a]);
        await pool.connect();
        final routed = <String>[];
        final merged = <String>[];
        final s1 = pool.events.listen((e) => merged.add(e.id));

        pool.request('s', {
          'kinds': [1],
        }, onEvent: (e) => routed.add(e.id));
        // Re-issue without a handler (e.g. a code path that re-requests the
        // same id as a normal store-bound sub).
        pool.request('s', {
          'kinds': [1],
        });
        a.emitTagged('s', _event('x1'));
        await Future<void>.delayed(Duration.zero);

        expect(routed, isEmpty);
        expect(merged, ['x1']);
        await s1.cancel();
        await pool.dispose();
      },
    );
  });
}
