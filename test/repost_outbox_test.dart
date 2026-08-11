// Regression test: a repost whose target note is NOT embedded (empty NIP-18
// content), NOT on the user's connected relays, and carries NO e-tag relay
// hint must still resolve — via the reposted AUTHOR's NIP-65 outbox relays
// (repostedEventProvider tier 4). Before that tier existed such reposts
// rendered "转发内容不可用" permanently (the FutureProvider caches its null).
//
// Harness mirrors reply_visibility_test.dart: fake relays answer every REQ
// with an immediate EOSE and no events (the default pool has nothing), and a
// LocalCache double serves the repost + the author's kind-10002 relay list.
// RelayPool.makeClient is overridden so fetchFromUrls "dials" an in-memory
// seeded relay instead of a real WebSocket.

import 'dart:async';
import 'dart:convert';

import 'package:costr/app/providers.dart';
import 'package:costr/models/event.dart';
import 'package:costr/nostr/identity.dart';
import 'package:costr/nostr/relay_client.dart';
import 'package:costr/nostr/relay_pool.dart';
import 'package:costr/services/local_cache.dart' as cache;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fake relay: immediate EOSE, no events — "this relay has nothing".
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

/// Fake relay that serves seeded events to `ids` REQs — the reposted author's
/// outbox relay where the reposted note lives.
class _SeededRelay extends _EmptyRelay {
  _SeededRelay(super.url, this.seeded);
  final List<Event> seeded;

  @override
  void request(String subId, Map<String, dynamic> filter) {
    final ids = filter['ids'];
    scheduleMicrotask(() {
      if (ids is List) {
        for (final e in seeded) {
          if (ids.contains(e.id) && !_events.isClosed) _events.add(e);
        }
      }
      if (!_eose.isClosed) _eose.add(subId);
    });
  }
}

final _sig = 's' * 128;

Event _note(
  String id, {
  String content = 'the reposted note',
  String? pubkey,
}) => Event(
  id: id,
  pubkey: pubkey ?? 'a' * 64,
  createdAt: 1700000000,
  kind: 1,
  tags: const [],
  content: content,
  sig: _sig,
);

cache.EventRow _row(Event e) => cache.EventRow(
  id: e.id,
  pubkey: e.pubkey,
  kind: e.kind,
  createdAt: e.createdAt,
  content: e.content,
  sig: e.sig,
  raw: jsonEncode(e.toWireObject()),
  tagsJson: jsonEncode(e.tags),
  receivedAt: 0,
);

/// LocalCache double: serves the repost row by id + the reposted author's
/// kind-10002 relay list (pointing at the seeded outbox relay). Everything
/// else misses.
class _RepostCache implements cache.LocalCache {
  _RepostCache({required this.repost, required this.authorRelayList});
  final Event repost;
  final Event authorRelayList;

  @override
  Future<cache.EventRow?> queryEventById(String id) async =>
      id == repost.id ? _row(repost) : null;

  @override
  Future<cache.ReplaceableEvent?> queryReplaceable(
    String pubkey,
    int kind, {
    String dTag = '',
  }) async {
    if (pubkey != authorRelayList.pubkey || kind != 10002) return null;
    return cache.ReplaceableEvent(
      pubkey: authorRelayList.pubkey,
      kind: 10002,
      dTag: '',
      id: authorRelayList.id,
      createdAt: authorRelayList.createdAt,
      content: '',
      sig: _sig,
      raw: '{}',
      tagsJson: jsonEncode(authorRelayList.tags),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NullId extends IdentityNotifier {
  @override
  Future<Identity?> build() async => null;
}

void main() {
  test('repost without embedded JSON / relay hint resolves via the reposted '
      'author outbox (tier 4)', () async {
    const authorPk =
        'a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5'
        'a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5';
    final note = _note('note1', pubkey: authorPk);
    // Kind-6 repost: EMPTY content (no NIP-18 embed) + e tag WITHOUT a relay
    // hint + p tag of the reposted author. The worst case for the old code.
    final repost = Event(
      id: 'rp1',
      pubkey: 'r' * 64,
      createdAt: 1700000001,
      kind: 6,
      tags: [
        ['e', 'note1', '', ''],
        ['p', authorPk],
      ],
      content: '',
      sig: _sig,
    );
    final relayList = Event(
      id: 'k10002',
      pubkey: authorPk,
      createdAt: 1699999999,
      kind: 10002,
      tags: [
        ['r', 'wss://outbox.example'],
      ],
      content: '',
      sig: _sig,
    );

    final pool = RelayPool([_EmptyRelay('wss://pool')]);
    final indexerPool = RelayPool([_EmptyRelay('wss://idx')]);
    await pool.connect();
    await indexerPool.connect();
    // fetchFromUrls("wss://outbox.example") dials the seeded relay in-memory.
    final outbox = _SeededRelay('wss://outbox.example', [note]);
    pool.makeClient = (url) =>
        url == 'wss://outbox.example' ? outbox : _EmptyRelay(url);
    addTearDown(pool.dispose);
    addTearDown(indexerPool.dispose);

    final db = _RepostCache(repost: repost, authorRelayList: relayList);
    final container = ProviderContainer(
      overrides: [
        relayPoolProvider.overrideWith((ref) => pool),
        indexerPoolProvider.overrideWith((ref) => indexerPool),
        localCacheProvider.overrideWith((ref) async => db),
        identityProvider.overrideWith(() => _NullId()),
      ],
    );
    addTearDown(container.dispose);
    container.read(eventStoreProvider.notifier);
    await container.read(localCacheProvider.future);

    final resolved = await container.read(repostedEventProvider('rp1').future);
    expect(resolved, isNotNull, reason: 'outbox tier must recover the note');
    expect(resolved!.id, 'note1');
    expect(resolved.content, 'the reposted note');
  });

  test('embedded repost still short-circuits before any fetch', () async {
    final note = _note('note2');
    final repost = Event(
      id: 'rp2',
      pubkey: 'r' * 64,
      createdAt: 1700000001,
      kind: 6,
      tags: [
        ['e', 'note2', '', ''],
        ['p', note.pubkey],
      ],
      content: jsonEncode(note.toWireObject()),
      sig: _sig,
    );
    final pool = RelayPool([_EmptyRelay('wss://pool')]);
    final indexerPool = RelayPool([_EmptyRelay('wss://idx')]);
    await pool.connect();
    await indexerPool.connect();
    addTearDown(pool.dispose);
    addTearDown(indexerPool.dispose);

    final db = _RepostCache(repost: repost, authorRelayList: _note('unused'));
    final container = ProviderContainer(
      overrides: [
        relayPoolProvider.overrideWith((ref) => pool),
        indexerPoolProvider.overrideWith((ref) => indexerPool),
        localCacheProvider.overrideWith((ref) async => db),
        identityProvider.overrideWith(() => _NullId()),
      ],
    );
    addTearDown(container.dispose);
    container.read(eventStoreProvider.notifier);
    await container.read(localCacheProvider.future);

    final resolved = await container.read(repostedEventProvider('rp2').future);
    expect(resolved?.id, 'note2');
  });
}
