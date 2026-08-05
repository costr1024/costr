/// NIP-65 outbox routing for the **following** feed.
///
/// The main [RelayPool] broadcasts every REQ to its fixed set of 8 default
/// relays. That works for the global firehose, but the following feed needs
/// events from each followee's OWN outbox relays (their kind-10002 `read`
/// markers) — a followee who posts only to relays outside our defaults would
/// otherwise never appear. [OutboxRouter] opens a DYNAMIC set of persistent
/// [RelayConnection]s to followees' outbox relays (grouped: many followees
/// share a relay, so the union stays small), sends per-relay authors-scoped
/// REQs, and forwards deduped events to a caller callback (which feeds them
/// into [EventStoreNotifier.ingest] so the existing following-mode filter sees
/// them with no UI change).
///
/// Two tiers:
/// - [start] — PERSISTENT live subscriptions (no close on EOSE) so new kind-1
///   posts + kind-7 reactions + kind-0 metadata stream in real time while the
///   following tab is active. Mirrors [RelayPool._resendActive]: on reconnect
///   (RelayClient re-opens the socket on backoff but does NOT re-issue REQs)
///   the router re-sends each relay's REQs.
/// - [fetchOnce] — one-shot pagination (close on EOSE), used by feed "load
///   more" with an `until` cursor. Mirrors [RelayPool.fetchFromUrls] but with
///   per-relay authors instead of a broadcast filter.
///
/// Pure-Dart (no Flutter/Riverpod) so it unit-tests with the same
/// `_FakeRelay` pattern used in `test/relay_pool_test.dart`.
library;

import 'dart:async';

import '../models/event.dart';
import 'identity.dart';
import 'relay_client.dart';

/// Maximum persistent outbox connections opened by [OutboxRouter.start]. The
/// provider ranks relays by followee count and keeps the top-N; followees
/// whose relays all fell out of the top-N fall back to a default-relay
/// broadcast (handled in the provider, not here). 30 + the 8 default relays
/// = 38 total, within typical Nostr client limits.
const int maxOutboxConnections = 30;

/// Chunk size for the `authors` array in a single REQ. Some relays reject very
/// large `authors` arrays; 200 is conservative. A relay hosting >200 followees
/// gets multiple REQs (subIds) of ≤200 each with the same kinds/since.
const int authorsChunkSize = 200;

class _OwnedRelay {
  _OwnedRelay(this.client, this.authorsChunks, this.since, this.limit);
  final RelayConnection client;
  final List<List<String>> authorsChunks;
  final int? since;
  final int limit;
  final List<String> subIds = [];
}

class OutboxRouter {
  OutboxRouter({
    RelayConnection Function(String url)? makeClient,
    Identity? Function()? identityGetter,
  }) : _makeClient = makeClient ?? RelayClient.new,
       _identityGetter = identityGetter ?? (() => null);

  final RelayConnection Function(String url) _makeClient;
  final Identity? Function() _identityGetter;

  final List<_OwnedRelay> _relays = [];
  final Set<String> _seen = {};
  final Map<String, StreamSubscription<Event>> _eventSubs = {};
  final Map<String, StreamSubscription<String>> _authSubs = {};
  int _seq = 0;
  bool _closed = false;

  /// Open persistent live subscriptions to each relay in [relayToAuthors].
  /// Events (deduped by id across ALL relays) are streamed to [onEvent] AS THEY
  /// ARRIVE — live, no close on EOSE. [since], when set, makes this an
  /// incremental refresh: only events newer than [since] are requested, and
  /// the per-REQ `limit` is raised (a prolific followee's many new posts
  /// aren't truncated the way the cold-load 200 cap would). Reconnects re-send
  /// each relay's REQs automatically (RelayClient only re-opens the socket).
  Future<void> start(
    Map<String, List<String>> relayToAuthors, {
    int? since,
    void Function(Event)? onEvent,
  }) async {
    // Per-relay page size. 500 (was 200 on cold load): kinds 0/1/6/7 are
    // mixed in one REQ and reactions dominate, so 200 bought only a few
    // hours of posts ("也就9个小时前的帖子" on the first page). The store
    // cap is now 20000, so the deeper cold page is affordable.
    const limit = 500;
    for (final entry in relayToAuthors.entries) {
      final url = entry.key;
      final chunks = _chunkAuthors(entry.value);
      final owned = _OwnedRelay(_makeClient(url), chunks, since, limit);
      _wireRelay(owned, url, onEvent);
      _relays.add(owned);
      // connect() fires _onConnected (wired in _wireRelay) → _issueReqs, so
      // REQs are sent both on initial connect AND on backoff reconnects
      // (RelayClient only re-opens the socket; re-issuing REQs is our job).
      // A failed handshake leaves _onConnected unfired → nothing sent until
      // a reconnect succeeds (don't send to a dead relay).
      await owned.client.connect().catchError((Object _) {});
    }
  }

  /// One-shot fetch: open a TRANSIENT client per relay, send chunked REQs with
  /// `until`/`since`, collect until EVERY relay EOSEs its subIds (or [timeout]
  /// elapses), then close + dispose — leaving nothing persistent behind.
  /// Mirrors [RelayPool.fetchFromUrls]. Events stream to [onEvent] as they
  /// arrive; the final list is also returned.
  ///
  /// [kinds] defaults to the live-feed set; backward pagination passes
  /// `[1, 6]` so the per-relay `limit` is spent on POSTS, not on the far
  /// higher-volume kind-7 reactions (which used to eat most of every page,
  /// stalling the `until` cursor a few hours deep).
  Future<List<Event>> fetchOnce(
    Map<String, List<String>> relayToAuthors, {
    int? until,
    int? since,
    List<int> kinds = const [0, 1, 6, 7],
    Duration timeout = const Duration(seconds: 10),
    void Function(Event)? onEvent,
  }) async {
    final results = <Event>[];
    final seen = <String>{};
    await Future.wait(
      relayToAuthors.entries.map((entry) async {
        final url = entry.key;
        final client = _makeClient(url);
        final chunks = _chunkAuthors(entry.value);
        final subIds = <String>[
          for (int i = 0; i < chunks.length; i++) _nextSubId('obx'),
        ];
        final pending = subIds.toSet();
        final done = Completer<void>();
        late StreamSubscription<Event> evSub;
        late StreamSubscription<String> eoseSub;
        evSub = client.events.listen((e) {
          if (!seen.add(e.id)) return;
          results.add(e);
          onEvent?.call(e);
        });
        eoseSub = client.eose.where((s) => subIds.contains(s)).listen((s) {
          pending.remove(s);
          if (pending.isEmpty && !done.isCompleted) done.complete();
        });
        try {
          await client.connect().timeout(const Duration(seconds: 5));
          if (!client.isConnected) return; // handshake failed — skip
          for (var i = 0; i < chunks.length; i++) {
            client.request(
              subIds[i],
              _filter(
                chunks[i],
                until: until,
                since: since,
                kinds: kinds,
                limit: 200,
              ),
            );
          }
          await done.future.timeout(timeout);
        } catch (_) {
          // connect failed or fetch timed out — results so far are kept.
        } finally {
          await evSub.cancel();
          await eoseSub.cancel();
          for (final sid in subIds) {
            try {
              client.closeSubscription(sid);
            } catch (_) {}
          }
          await client.dispose();
        }
      }),
    );
    return results;
  }

  /// Close every persistent subscription + dispose all owned clients.
  /// Safe to call multiple times.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final owned in _relays) {
      for (final sid in owned.subIds) {
        try {
          owned.client.closeSubscription(sid);
        } catch (_) {}
      }
      await owned.client.dispose();
    }
    for (final s in _eventSubs.values) {
      await s.cancel();
    }
    for (final s in _authSubs.values) {
      await s.cancel();
    }
    _relays.clear();
  }

  // --- internals ----------------------------------------------------------

  String _nextSubId(String purpose) => 'costr:$purpose:${_seq++}';

  /// Split [authors] into chunks of [authorsChunkSize] so no single REQ's
  /// `authors` array exceeds what relays accept. A relay hosting ≤200
  /// followees → one chunk (the common case).
  List<List<String>> _chunkAuthors(List<String> authors) {
    if (authors.isEmpty) return const [[]];
    final chunks = <List<String>>[];
    for (var i = 0; i < authors.length; i += authorsChunkSize) {
      chunks.add(
        authors.sublist(
          i,
          i + authorsChunkSize > authors.length
              ? authors.length
              : i + authorsChunkSize,
        ),
      );
    }
    return chunks;
  }

  Map<String, dynamic> _filter(
    List<String> authors, {
    int? since,
    int? until,
    List<int> kinds = const [0, 1, 6, 7],
    required int limit,
  }) {
    final f = <String, dynamic>{
      'kinds': kinds,
      'authors': authors,
      'limit': limit,
    };
    if (since != null) f['since'] = since;
    if (until != null) f['until'] = until;
    return f;
  }

  /// Wire a persistent relay's event + AUTH streams, and its reconnect hook.
  void _wireRelay(
    _OwnedRelay owned,
    String url,
    void Function(Event)? onEvent,
  ) {
    final c = owned.client;
    // Re-issue this relay's REQs on (re)connect — RelayClient re-opens the
    // socket on backoff but does NOT replay REQs (that's the pool's job for
    // the main pool; here we own the client, so we do it). Without this, a
    // network blip would silently kill the following feed until refresh.
    c.setOnConnected(() => _issueReqs(owned));
    _eventSubs[url] = c.events.listen((e) {
      if (_closed) return;
      // Dedup across ALL outbox relays (an event may live on several) before
      // forwarding — EventStore.add dedups too, but skipping here avoids
      // flooding ingest with duplicates during a burst load.
      if (!_seen.add(e.id)) return;
      onEvent?.call(e);
    });
    // NIP-42: some outbox relays require AUTH to serve REQs. Sign a kind-22242
    // challenge response with the lazy identity getter (mirror RelayPool).
    _authSubs[url] = c.auths.listen((challenge) {
      final id = _identityGetter();
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

  /// Send (or re-send) this relay's chunked REQs. Idempotent per subId set:
  /// allocates subIds once on first call; reconnects reuse the same subIds
  /// (re-sending a REQ with an existing subId is the standard Nostr refresh).
  void _issueReqs(_OwnedRelay owned) {
    if (_closed || !owned.client.isConnected) return;
    if (owned.subIds.isEmpty) {
      for (var i = 0; i < owned.authorsChunks.length; i++) {
        owned.subIds.add(_nextSubId('obx'));
      }
    }
    for (var i = 0; i < owned.authorsChunks.length; i++) {
      owned.client.request(
        owned.subIds[i],
        _filter(owned.authorsChunks[i], since: owned.since, limit: owned.limit),
      );
    }
  }
}
