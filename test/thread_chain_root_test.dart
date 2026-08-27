// Regression: thread chain root must honor the focused post's NIP-10 `root`
// marker even when the replyTo walk dead-ends earlier. Real-world shape from
// a user-reported broken thread: the intermediate post quotes the true root
// with a `mention` marker only (its own replyToId is null), so the old walk
// threaded the whole conversation under that intermediate post and fetched
// only its direct replies — most replies (incl. the user's own) never showed.

import 'dart:convert';

import 'package:costr/app/providers.dart';
import 'package:costr/models/event.dart';
import 'package:costr/nostr/identity.dart';
import 'package:costr/nostr/relay_pool.dart';
import 'package:costr/services/local_cache.dart' as cache;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Id extends IdentityNotifier {
  @override
  Future<Identity?> build() async => null;
}

class _FakeCache implements cache.LocalCache {
  final Map<String, Event> byId = {};

  @override
  Future<cache.EventRow?> queryEventById(String id) async {
    final e = byId[id];
    if (e == null) return null;
    return cache.EventRow(
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
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('focused reply root marker lifts the chain to the true root', () async {
    final fake = _FakeCache();
    final container = ProviderContainer(
      overrides: [
        relayPoolProvider.overrideWith((ref) => RelayPool(const [])),
        localCacheProvider.overrideWith((ref) async => fake),
        // Keep the account registry (secure storage) out of a bare test.
        identityProvider.overrideWith(() => _Id()),
      ],
    );
    addTearDown(container.dispose);
    // Resolve the fake DB BEFORE any provider runs.
    await container.read(localCacheProvider.future);

    // R = true root (top-level). M quotes R via a MENTION marker only (not a
    // reply — its replyToId is null). F replies to M and carries the root
    // marker R (how Costr/newbot tag replies into such a thread).
    final r = Event(
      id: 'rrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrr',
      pubkey: 'a' * 64,
      createdAt: 1700000000,
      kind: 1,
      tags: const [],
      content: 'root post',
      sig: 's',
    );
    final m = Event(
      id: 'mmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmm',
      pubkey: 'b' * 64,
      createdAt: 1700000100,
      kind: 1,
      tags: [
        ['e', r.id, '', 'mention'],
      ],
      content: 'quoting the root',
      sig: 's',
    );
    final f = Event(
      id: 'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff',
      pubkey: 'c' * 64,
      createdAt: 1700000200,
      kind: 1,
      tags: [
        ['e', r.id, '', 'root'],
        ['e', m.id, '', 'reply'],
      ],
      content: 'reply into the thread',
      sig: 's',
    );
    fake.byId[r.id] = r;
    fake.byId[m.id] = m;
    fake.byId[f.id] = f;

    final chain = await container
        .read(threadAncestorsProvider(f.id).future)
        .timeout(const Duration(seconds: 5));
    expect(chain.map((e) => e.id).toList(), [r.id, m.id, f.id]);
  });
}
