/// Relay pool: manages N [RelayConnection]s, merges their event streams with
/// per-id dedup, tracks active subscriptions per relay, and re-issues them on
/// (re)connect. Exposes relay connection state for the UI.
///
/// v1 does not auto-CLOSE on EOSE for the global feed (live, capped by the
/// EventStore); the EOSE stream is surfaced for future use.
library;

import 'dart:async';
import 'dart:collection';

import '../models/event.dart';
import 'identity.dart';
import 'relay_client.dart';

enum RelayStatus { connecting, connected, disconnected, error }

class RelayState {
  const RelayState(this.url, this.status, [this.error]);
  final String url;
  final RelayStatus status;
  final String? error;

  @override
  String toString() =>
      'RelayState($url: $status${error == null ? '' : ' — $error'})';
}

class RelayPool {
  /// Build a pool backed by real WebSocket [RelayClient]s from [urls].
  factory RelayPool.fromUrls(List<String> urls) =>
      RelayPool(urls.map((u) => RelayClient(u)).toList());

  /// Construct with explicit connections (allows test injection of fakes).
  RelayPool(List<RelayConnection> connections)
    : _connections = List<RelayConnection>.of(connections);

  /// Mutable on purpose: [updateUrls] hot-swaps the connection set when the
  /// user edits their server list, WITHOUT replacing the pool instance — the
  /// app's providers (event store, feed, outbox) hold onto this pool via
  /// `ref.watch(relayPoolProvider)` and must keep their subscriptions.
  final List<RelayConnection> _connections;
  final Map<String, Map<String, dynamic>> _activeSubs = {};
  final Set<String> _closeOnEose = {};
  final Map<String, int> _eoseCount = {};
  final LinkedHashSet<String> _seenIds = LinkedHashSet();

  /// Subscription-scoped event routes: subId → handler. Events arriving under
  /// a routed subId go ONLY to its handler — they never reach the [events] /
  /// [rawEvents] merged streams, so the capped EventStore (reserved for the
  /// following feed + related events) never sees the global firehose. The
  /// global feed's ephemeral window subscribes this way.
  final Map<String, void Function(Event)> _routeSubs = {};
  bool _mergedWired = false;
  bool _connecting = false;
  int _fetchSeq = 0;

  /// Lazily returns the current identity, used to sign NIP-42 AUTH responses.
  /// Set by the app so the pool can auth after login (identity may arrive
  /// after the pool is created).
  Identity? Function() identityGetter = () => null;

  /// Factory for the TRANSIENT [RelayConnection]s opened by [fetchFromUrls].
  /// Defaults to real WebSocket [RelayClient]s; tests inject a fake to avoid
  /// network I/O.
  RelayConnection Function(String url) makeClient = RelayClient.new;

  final StreamController<Event> _merged = StreamController<Event>.broadcast();
  final StreamController<Event> _raw = StreamController<Event>.broadcast();
  final StreamController<RelayOk> _oks = StreamController<RelayOk>.broadcast();
  final StreamController<String> _eose = StreamController<String>.broadcast();
  // late so the initializer can reference the instance method _emitStatus.
  late final StreamController<List<RelayState>> _status =
      StreamController<List<RelayState>>.broadcast(
        onListen: () => scheduleMicrotask(_emitStatus),
      );

  /// Merged, deduped stream of all events from all relays.
  ///
  /// Use for the live global feed (where the same event arriving from multiple
  /// relays should be processed once). For short-lived targeted fetches that
  /// RE-FETCH an event already seen on the global feed (e.g. a user's kind-3
  /// contact list, which was already received when the app loaded the
  /// following list), use [rawEvents] instead — the dedup set would otherwise
  /// swallow the re-sent event and the fetch would return empty.
  Stream<Event> get events => _merged.stream;

  /// Merged, UN-deduped stream of all events from all relays. Each event is
  /// emitted every time a relay sends it, even if it was already seen on
  /// another relay or in an earlier subscription. Consumers MUST dedup by id
  /// themselves (a `Set<String>` of seen ids). Use this for one-shot targeted
  /// fetches (a specific user's kind-3, a kind-3 #p followers query, NIP-50
  /// search) so that re-fetching an event the global feed already saw still
  /// returns it. The global feed should keep using [events].
  Stream<Event> get rawEvents => _raw.stream;

  /// Merged stream of OK acks from all relays (publish verdicts).
  Stream<RelayOk> get oks => _oks.stream;

  /// Merged stream of EOSE subIds (a subId is emitted when any relay EOSEs it).
  Stream<String> get eoseStream => _eose.stream;

  /// Stream of relay connection states (emits current state on subscribe, and
  /// on every connect/disconnect thereafter).
  Stream<List<RelayState>> get statusStream => _status.stream;

  List<RelayState> get states => _connections
      .map(
        (c) => RelayState(
          c.url,
          c.isConnected ? RelayStatus.connected : RelayStatus.disconnected,
        ),
      )
      .toList();

  /// Measure real WS round-trip latency for [url] via its [RelayClient].
  /// Returns null if the URL isn't in the pool or isn't a real client. The
  /// measurement is a REQ→EOSE round-trip with an impossible filter (≈ network
  /// RTT, not ICMP ping); see [RelayClient.measureRtt].
  Future<int?> measureRttFor(String url, {List<int> kinds = const [1]}) async {
    for (final c in _connections) {
      if (c.url == url && c is RelayClient) {
        return c.measureRtt(kinds: kinds);
      }
    }
    return null;
  }

  /// One-shot fetch against [urls] (NIP-65 outbox routing): open a TRANSIENT
  /// [RelayClient] per URL, send REQ [filter], collect events until every
  /// relay EOSEs (or [timeout] elapses), then close + dispose — leaving the
  /// pool's persistent connection set + active-subscription map untouched.
  /// Lets a profile/posts fetch target the author's own outbox relays (from
  /// their kind-10002) instead of broadcasting to the whole pool. Events are
  /// deduped by id across relays.
  ///
  /// [onEvent], if given, is invoked for each freshly-seen event AS IT ARRIVES
  /// (before this future resolves) — so callers can stream events into the UI
  /// with a debounce instead of waiting for the whole batch. The transient
  /// clients don't emit to the pool's [rawEvents] stream, so without this hook
  /// the caller would only see the final list.
  Future<List<Event>> fetchFromUrls(
    Map<String, dynamic> filter,
    List<String> urls, {
    Duration timeout = const Duration(seconds: 10),
    void Function(Event)? onEvent,
  }) async {
    final cleaned = urls
        .map((u) => u.trim())
        .where(
          (u) =>
              u.isNotEmpty && (u.startsWith('ws://') || u.startsWith('wss://')),
        )
        .toSet();
    if (cleaned.isEmpty) return const <Event>[];
    final subId = 'costr:fetch:${_fetchSeq++}';
    final results = <Event>[];
    final seen = <String>{};
    await Future.wait(
      cleaned.map((url) async {
        final client = makeClient(url);
        late StreamSubscription<Event> evSub;
        late StreamSubscription<String> eoseSub;
        final done = Completer<void>();
        evSub = client.events.listen((e) {
          if (seen.add(e.id)) {
            results.add(e);
            onEvent?.call(e);
          }
        });
        eoseSub = client.eose.where((s) => s == subId).listen((_) {
          if (!done.isCompleted) done.complete();
        });
        try {
          // connect() awaits the WS/TLS handshake (up to 10s internally);
          // cap at 5s so a silent black-hole relay doesn't stall the fetch.
          await client.connect().timeout(const Duration(seconds: 5));
          if (!client.isConnected) return; // handshake failed — skip
          client.request(subId, filter);
          await done.future.timeout(timeout);
        } catch (_) {
          // connect failed or fetch timed out — results so far are kept.
        } finally {
          await evSub.cancel();
          await eoseSub.cancel();
          try {
            client.closeSubscription(subId);
          } catch (_) {}
          await client.dispose();
        }
      }),
    );
    return results;
  }

  Future<void> connect() async {
    if (_connecting || _mergedWired) return;
    _connecting = true;
    _wireMerged();
    // Connect all relays concurrently (not sequentially) so a blocked relay
    // (RelayClient.connect awaits a 10s ready timeout) doesn't stall reachable
    // relays behind it.
    await Future.wait(
      _connections.map((c) async {
        c.setOnConnected(() {
          _resendActive(c);
          _emitStatus();
        });
        c.setOnDisconnected(_emitStatus);
        await c.connect().catchError((Object _) {});
      }),
    );
    _connecting = false;
    _emitStatus();
  }

  /// Reconnect any connections that have dropped, WITHOUT clearing the
  /// in-memory event store. Called by the app's lifecycle observer when the
  /// app returns to the foreground (the OS suspends websockets while
  /// backgrounded) so the user sees their already-cached feed instantly and
  /// only incremental new events are fetched — not a full reload.
  Future<void> reconnect() async {
    for (final c in _connections) {
      if (!c.isConnected) await c.connect().catchError((Object _) {});
    }
    _emitStatus();
  }

  void _wireMerged() {
    if (_mergedWired) return;
    _mergedWired = true;
    for (final c in _connections) {
      _wireConnection(c);
    }
  }

  /// Wire ONE connection's streams into the pool's merged streams. Used by
  /// [_wireMerged] on first connect AND by [updateUrls] for connections added
  /// to an already-wired pool.
  void _wireConnection(RelayConnection c) {
    c.taggedEvents.listen((arrival) {
      final subId = arrival.$1;
      final e = arrival.$2;
      // Subscription-scoped route (the ephemeral global-feed window): the
      // handler alone sees these events — they never enter the merged/raw
      // streams, so the capped store (following feed + related events only)
      // is never flooded by the firehose. Relay EVENT frames carry the subId,
      // so the same event arriving under ANOTHER (unrouted) sub still takes
      // the normal merged path on its own arrival.
      final route = _routeSubs[subId];
      if (route != null) {
        route(e);
        return;
      }
      // Raw stream: always emit (consumers dedup themselves) so targeted
      // re-fetches work even when the global feed already saw the event.
      if (!_raw.isClosed) _raw.add(e);
      if (_seenIds.add(e.id)) {
        _merged.add(e);
      }
      // Bound the dedup set to avoid unbounded memory growth on long sessions.
      if (_seenIds.length > 10000) {
        _seenIds.remove(_seenIds.first);
      }
    });
    c.eose.listen((String subId) {
      if (!_eose.isClosed) _eose.add(subId);
      // closeOnEose subs close only after ALL connected relays have EOSE'd —
      // closing on the first relay's EOSE loses events from slower relays
      // (this caused the follow-list wipe: a relay without the user's kind-3
      // EOSE'd first, the kind-3 from a slower relay was dropped, and a new
      // kind-3 with only the new pubkey was published — clearing follows).
      if (_closeOnEose.contains(subId)) {
        final n = (_eoseCount[subId] ?? 0) + 1;
        _eoseCount[subId] = n;
        if (n >= _connections.length) {
          _closeOnEose.remove(subId);
          _eoseCount.remove(subId);
          closeSubscription(subId);
        }
      }
    });
    c.oks.listen((RelayOk ok) {
      if (!_oks.isClosed) _oks.add(ok);
    });
    c.auths.listen((String challenge) async {
      // NIP-42: sign a kind-22242 auth event with [relay, url] + [challenge,
      // challenge] tags and send it back. Lazy-fetch identity so it works
      // after a login that happened post-connect.
      final id = identityGetter();
      if (id == null) return;
      final auth = id.signEvent(
        kind: 22242,
        content: '',
        tags: [
          ['relay', c.url],
          ['challenge', challenge],
        ],
      );
      c.sendAuth(auth);
    });
  }

  /// Hot-swap the pool's relay set to [urls] (the user edited their server
  /// list). Connections whose URL is kept stay untouched (no reconnect);
  /// removed ones are disposed; new ones are created via [makeClient]. The
  /// pool instance itself NEVER changes — that's the point: providers watching
  /// this pool keep their subscriptions, only the underlying sockets change.
  ///
  /// Callers pass normalized URLs (see server_list_rules.dart); matching is
  /// exact-string. If the pool is already wired (connected at least once), new
  /// connections are wired into the merged streams immediately, get ALL active
  /// subscriptions re-issued on connect (via the onConnected hook set here),
  /// and connect right away. If it was never connected, this is a plain list
  /// swap and the later [connect] covers the new set.
  ///
  /// The list itself is swapped in ONE synchronous step (never mutated while
  /// other code iterates it); removed connections are disposed afterwards. A
  /// removed connection may still be mid-handshake — RelayClient.connect
  /// checks its disposed flag after the WS handshake and bails, so disposing
  /// an in-flight connect is safe.
  Future<void> updateUrls(List<String> urls) async {
    final wanted = <String>[];
    final seen = <String>{};
    for (final raw in urls) {
      final u = raw.trim();
      if (u.isEmpty || !seen.add(u)) continue;
      wanted.add(u);
    }
    final byUrl = <String, RelayConnection>{
      for (final c in _connections) c.url: c,
    };
    final next = <RelayConnection>[];
    final fresh = <RelayConnection>[];
    for (final url in wanted) {
      final existing = byUrl.remove(url);
      if (existing != null) {
        next.add(existing);
      } else {
        final c = makeClient(url);
        next.add(c);
        fresh.add(c);
      }
    }
    final removed = byUrl.values.toList();
    // Single synchronous swap — iterations elsewhere (request/publish/states)
    // must never observe a half-edited list.
    _connections
      ..clear()
      ..addAll(next);
    if (_mergedWired) {
      for (final c in fresh) {
        _wireConnection(c);
        c.setOnConnected(() {
          _resendActive(c);
          _emitStatus();
        });
        c.setOnDisconnected(_emitStatus);
        unawaited(c.connect().catchError((Object _) {}));
      }
    }
    for (final c in removed) {
      unawaited(c.dispose().catchError((Object _) {}));
    }
    _emitStatus();
  }

  void _resendActive(RelayConnection c) {
    for (final entry in _activeSubs.entries) {
      c.request(entry.key, entry.value);
    }
  }

  /// Issue a REQ to every connected relay; re-issues to relays that reconnect
  /// later. [subId] must be unique per logical subscription.
  ///
  /// If [closeOnEose] is true (used for the global feed), the subscription is
  /// CLOSED on the first EOSE from any relay, bounding it to a recent snapshot
  /// instead of an unbounded live firehose.
  ///
  /// If [onEvent] is given, the subscription is ROUTED: every event arriving
  /// under [subId] is delivered to the handler ONLY — it never enters the
  /// merged [events] / [rawEvents] streams. Used by the global feed to keep
  /// the firehose out of the capped EventStore (following feed + related
  /// events only). The route is removed by [closeSubscription].
  void request(
    String subId,
    Map<String, dynamic> filter, {
    bool closeOnEose = false,
    void Function(Event)? onEvent,
  }) {
    _activeSubs[subId] = filter;
    if (closeOnEose) _closeOnEose.add(subId);
    if (onEvent != null) {
      _routeSubs[subId] = onEvent;
    } else {
      _routeSubs.remove(subId);
    }
    for (final c in _connections) {
      if (c.isConnected) c.request(subId, filter);
    }
  }

  /// Close a subscription on every connected relay and stop tracking it.
  void closeSubscription(String subId) {
    _activeSubs.remove(subId);
    _closeOnEose.remove(subId);
    _eoseCount.remove(subId);
    _routeSubs.remove(subId);
    for (final c in _connections) {
      if (c.isConnected) c.closeSubscription(subId);
    }
  }

  /// Publish a signed event to every connected relay (`["EVENT", ...]`).
  /// Also echoes it locally so the author sees their post in the feed
  /// immediately (relays only ack with OK, they don't echo EVENT on publish).
  void publish(Event event) {
    for (final c in _connections) {
      if (c.isConnected) c.publish(event);
    }
    if (!_merged.isClosed) _merged.add(event);
  }

  /// Publish and wait for relay OK verdicts, retrying per the project spec:
  /// - Send EVENT to every connected relay, wait for each relay's OK (per-round
  ///   timeout).
  /// - If **any** relay accepts → resolve success immediately; relays still
  ///   silent (or stuck in NIP-42 auth) when the round window closes keep
  ///   retrying in the BACKGROUND (delays 1s/2s/3s) so the caller isn't
  ///   blocked. Relays that merely answered SLOWER than the fastest are NOT
  ///   re-sent — their late OK still lands in the verdict window (re-sending
  ///   stored events is duplicate spam and, on relays that answer duplicates
  ///   with ok:false, produced spurious write-failure statistics).
  /// - If **all** relays fail a round → retry in the FOREGROUND (blocking)
  ///   with delays 1s/2s/3s. Give up on a relay only when it's confirmed
  ///   unreachable (disconnects) or returns an unrecoverable rejection (OK
  ///   false with a non-`auth` reason). A timeout (no ack) is always retried.
  /// - NIP-42: relays that reject with `auth-required` are retried (the
  ///   pool auto-signs kind-22242 on AUTH challenges); the retry lands after
  ///   the auth round-trip. The auth rejection itself is a protocol
  ///   handshake, NOT a write failure — it is never counted in the
  ///   write-success statistics (only the post-auth verdict is).
  /// - Duplicates: a relay answering ok:false with a `duplicate:` reason
  ///   already HAS the event — that is a successful publish outcome for both
  ///   statistics and retry (NIP-20).
  /// - If background retries are exhausted with relays still failing, the
  ///   optional [onPublishExhausted] hook is invoked (the app saves the event
  ///   to the drafts table for a next-launch retry to the missing relays).
  Future<RelayOk> publishAndWait(
    Event event, {
    Duration timeout = const Duration(seconds: 15),
    List<Duration> retryDelays = const [
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 3),
    ],
    Duration perRoundTimeout = const Duration(seconds: 5),
  }) async {
    final expected = event.id;
    final delays = retryDelays;
    final perRound = perRoundTimeout;

    // NOTE: the optimistic local echo used to happen here (before any relay
    // accepted). It now happens ONLY on the success path (just before
    // `return accepted.first` below). Echoing a publish that ultimately
    // failed left a phantom post in the feed; when the user retried (a new
    // event id, since each sign uses a fresh created_at), the retry echoed
    // separately → two identical posts visible. See compose retry path.
    var targets = _connections.where((c) => c.isConnected).toList();
    if (targets.isEmpty) {
      return RelayOk(expected, false, 'no connected relay');
    }

    for (var attempt = 0; attempt <= delays.length; attempt++) {
      final round = _PublishRound(this, event, targets, perRound);
      final verdicts = await round.early;
      final accepted = verdicts.values.where(_effectiveOk).toList();
      if (accepted.isNotEmpty) {
        // Some relays accepted → return success now. Detached, keep
        // collecting verdicts until the round window closes: slower relays'
        // OKs still reach the write statistics, and ONLY relays with no
        // verdict at all (or still stuck in NIP-42 auth) get a background
        // retry — never the ones that simply answered late.
        final roundTargets = targets;
        unawaited(() async {
          final all = await round.settled;
          final missing = <RelayConnection>[];
          for (final c in roundTargets) {
            final v = all[c.url];
            if (v == null) {
              if (c.isConnected) missing.add(c); // silent → real retry
            } else if (!_effectiveOk(v) && _isAuthRejection(v)) {
              missing.add(c); // auth in flight → retry after AUTH
            }
          }
          if (missing.isNotEmpty) {
            _backgroundRetryPublish(event, missing, delays, perRound);
          }
        }());
        // Echo locally ONLY now that at least one relay accepted — so the
        // author sees the post instantly (relays only ack OK, they don't
        // echo EVENT back on publish) WITHOUT leaving a phantom for
        // publishes that failed on every relay.
        if (!_merged.isClosed) _merged.add(event);
        // Report success as a raw ok:true verdict whenever one exists. When
        // the ONLY acceptance is a NIP-20 duplicate (ok:false, event already
        // stored — e.g. a draft re-publish), synthesize ok:true so callers
        // never misread a stored-event publish as a failure.
        final rawTrue = accepted.where((v) => v.ok);
        return rawTrue.isNotEmpty
            ? rawTrue.first
            : RelayOk(expected, true, 'duplicate');
      }
      // All failed this round. Keep only transiently-failed relays for the
      // next round; drop unrecoverable (explicit non-auth rejection) and
      // disconnected ones.
      final all = await round.settled;
      final next = <RelayConnection>[];
      for (final c in targets) {
        final v = all[c.url];
        if (v == null) {
          if (c.isConnected) next.add(c); // timeout, still connected
        } else if (!_effectiveOk(v) && _isAuthRejection(v)) {
          next.add(c);
        }
        // else: explicit unrecoverable rejection OR accepted (n/a here) → drop.
      }
      if (next.isEmpty) break; // all unrecoverable — no point retrying
      targets = next;
      if (attempt < delays.length) {
        await Future.delayed(delays[attempt]);
      }
    }
    return RelayOk(
      expected,
      false,
      'all relays failed after ${delays.length} retries',
    );
  }

  /// NIP-42 `auth-required` rejection — a transient protocol step, not a
  /// write failure (the pool answers the AUTH challenge and retries).
  static bool _isAuthRejection(RelayOk v) =>
      (v.reason ?? '').toLowerCase().contains('auth');

  /// NIP-20 duplicate answer: the relay ALREADY STORED the event (ok:false +
  /// `duplicate:` happens on relays that refuse to re-ack a stored event with
  /// ok:true). The publish goal — the event being stored — is achieved.
  static bool _isDuplicateOk(RelayOk v) =>
      !v.ok && (v.reason ?? '').toLowerCase().contains('duplicate');

  /// Did this verdict achieve the publish goal (accepted OR already stored)?
  static bool _effectiveOk(RelayOk v) => v.ok || _isDuplicateOk(v);

  /// Background (detached) retry of still-missing relays after a publish
  /// already resolved success elsewhere. Retries with [delays], dropping
  /// relays that disconnect or return an unrecoverable rejection. On
  /// exhaustion, invokes [onPublishExhausted] if set (app saves a draft).
  void _backgroundRetryPublish(
    Event event,
    List<RelayConnection> relays,
    List<Duration> delays,
    Duration perRound,
  ) {
    () async {
      var targets = relays;
      for (
        var attempt = 0;
        attempt < delays.length && targets.isNotEmpty;
        attempt++
      ) {
        await Future.delayed(delays[attempt]);
        targets = targets.where((c) => c.isConnected).toList();
        if (targets.isEmpty) break;
        final round = _PublishRound(this, event, targets, perRound);
        final verdicts = await round.settled;
        final still = <RelayConnection>[];
        for (final c in targets) {
          final v = verdicts[c.url];
          if (v == null) {
            if (c.isConnected) still.add(c);
          } else if (!_effectiveOk(v) && _isAuthRejection(v)) {
            still.add(c);
          }
          // accepted (incl. duplicate) or unrecoverable → drop.
        }
        targets = still;
      }
      if (targets.isNotEmpty) {
        _onPublishExhausted?.call(event);
      }
    }();
  }

  /// Optional hook invoked when a publish's background retries are exhausted
  /// with relays still failing (the event was accepted by at least one relay,
  /// so it IS published, but not to all). The app sets this to save the event
  /// to the drafts table for a later retry to the missing relays.
  void Function(Event event)? _onPublishExhausted;
  set onPublishExhausted(void Function(Event event)? fn) =>
      _onPublishExhausted = fn;

  /// Per-relay WRITE verdict hook for send success-rate statistics (the
  /// 服务器节点 page flags relays whose writes keep failing). Invoked once per
  /// relay that returns an EXPLICIT verdict in a publish round: `ok` is the
  /// EFFECTIVE outcome (accepted, or a NIP-20 `duplicate:` answer — the event
  /// is stored either way) and [reason] is the relay's raw OK reason string
  /// (for diagnostics, e.g. "blocked: …" / "rate-limited: …"). NIP-42
  /// `auth-required` rejections are NEVER reported — they are a transient
  /// handshake retried automatically, not a write failure. Relays with no
  /// verdict in the window are NOT reported — a timeout is not evidence of
  /// failure (see [_PublishRound]). Read paths are deliberately never
  /// measured: a relay that accepts writes can almost always be read from.
  void Function(String url, bool ok, String? reason)? onWriteVerdict;

  void _emitStatus() {
    if (!_status.isClosed) {
      _status.add(states);
    }
  }

  Future<void> dispose() async {
    for (final c in _connections) {
      await c.dispose();
    }
    await _merged.close();
    await _raw.close();
    await _oks.close();
    await _eose.close();
    await _status.close();
  }
}

/// One publish round: sends [event] to [relays] and collects their OK
/// verdicts into [verdicts].
///
/// [early] resolves the moment the outcome is decided — the FIRST effective
/// acceptance, every relay verdicted, or the per-round window elapsing — so
/// the caller (the user's send button) never waits on the slowest relay (the
/// «发帖要等 1～3s» fix). [settled] resolves when every relay has verdicted
/// or the window elapsed: it keeps collecting AFTER [early] so a slower
/// relay's genuine verdict still lands in the write statistics and decides
/// whether that relay really needs a retry — instead of re-sending to every
/// relay that was merely slower than the fastest one (the old immediate
/// retry re-sent the event to all of them ~1s later: duplicate spam, plus
/// spurious failure samples from relays that answer duplicates with ok:false
/// — the «发帖成功率很低» false alarm on healthy relays).
///
/// Write statistics ([RelayPool.onWriteVerdict]) are recorded HERE, once per
/// relay per round, as verdicts arrive — including the late ones — and never
/// for NIP-42 `auth-required` rejections (a transient handshake retried
/// automatically; only the post-auth verdict is a real sample).
class _PublishRound {
  _PublishRound(this._pool, this.event, this.relays, Duration perRound) {
    _pending = relays.map((c) => c.url).toSet();
    _sub = _pool.oks.listen(_onOk);
    _timer = Timer(perRound, _settle);
    for (final c in relays) {
      c.publish(event);
    }
  }

  final RelayPool _pool;
  final Event event;
  final List<RelayConnection> relays;
  final Map<String, RelayOk> verdicts = {};
  final Completer<Map<String, RelayOk>> _early = Completer();
  final Completer<Map<String, RelayOk>> _settled = Completer();
  late final StreamSubscription<RelayOk> _sub;
  late final Timer _timer;
  late final Set<String> _pending;

  Future<Map<String, RelayOk>> get early => _early.future;
  Future<Map<String, RelayOk>> get settled => _settled.future;

  void _onOk(RelayOk ok) {
    if (ok.id != event.id || ok.url == null) return;
    if (!_pending.contains(ok.url!)) return;
    verdicts[ok.url!] = ok;
    _pending.remove(ok.url!);
    final hook = _pool.onWriteVerdict;
    if (hook != null && !RelayPool._isAuthRejection(ok)) {
      hook(ok.url!, RelayPool._effectiveOk(ok), ok.reason);
    }
    if (!_early.isCompleted &&
        (RelayPool._effectiveOk(ok) || _pending.isEmpty)) {
      _early.complete(Map.of(verdicts));
    }
    if (_pending.isEmpty) _settle();
  }

  void _settle() {
    _timer.cancel();
    _sub.cancel();
    if (!_early.isCompleted) _early.complete(Map.of(verdicts));
    if (!_settled.isCompleted) _settled.complete(Map.of(verdicts));
  }
}
