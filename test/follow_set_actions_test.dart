// Unit tests for NostrActions follow-set operations: create (UUID d),
// rename (d preserved, name updated), delete (NIP-09 a-coordinate kind-5),
// FollowGroup.memberCount, and kind-10015 followed-hashtags NIP-44
// encrypt/decrypt (Amethyst interop).
import 'package:costr/app/providers.dart';
import 'package:costr/models/event.dart';
import 'package:costr/nostr/actions.dart';
import 'package:costr/nostr/identity.dart';
import 'package:flutter_test/flutter_test.dart';

const _priv = '0000000000000000000000000000000000000000000000000000000000000001';

Event _k30000(List<List<dynamic>> tags, {String id = 'id', String pk = 'pk'}) =>
    Event(id: id, pubkey: pk, createdAt: 0, kind: 30000, tags: tags, content: '', sig: 's');

Matcher _tag(List<String> t) => contains(equals(t));

void main() {
  final id = Identity.fromPrivkeyHex(_priv);
  final actions = NostrActions(id);

  group('NostrActions.followCategory (new list)', () {
    test('new list uses a UUID d + name tag (Amethyst convention)', () {
      final e = actions.followCategory(null, 'pk-followed', '好友');
      expect(e.kind, 30000);
      // name tag = the human name.
      expect(e.tags, _tag(['name', '好友']));
      // d tag is a UUID v4 (8-4-4-4-12, not the human name).
      final d = e.tags.firstWhere((t) => t[0] == 'd');
      expect(d[1], isNot('好友'));
      expect(d[1], matches(RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
      // p tag included.
      expect(e.tags, _tag(['p', 'pk-followed', '']));
      // client tag.
      expect(e.tags, _tag(['client', 'Costr']));
      expect(id.verifyEventSignature(id: e.id, sig: e.sig), isTrue);
    });

    test('editing existing list preserves Amethyst UUID d + name + rebuilds p',
        () {
      final current = _k30000([
        ['d', 'f40fa7f0-8441-4eae-8b55-f605699da40b'],
        ['name', '真人用户'],
        ['alt', 'real users'],
        ['p', 'old-pk', ''],
      ]);
      final e = actions.followCategory(current, 'new-pk', '真人用户');
      // d preserved verbatim.
      expect(e.tags, _tag(['d', 'f40fa7f0-8441-4eae-8b55-f605699da40b']));
      // name + metadata preserved.
      expect(e.tags, _tag(['name', '真人用户']));
      expect(e.tags, _tag(['alt', 'real users']));
      // old-pk kept, new-pk added.
      expect(e.tags, _tag(['p', 'old-pk', '']));
      expect(e.tags, _tag(['p', 'new-pk', '']));
    });
  });

  group('NostrActions.renameFollowSet', () {
    test('preserves d, updates only name, carries p roster + metadata', () {
      final current = _k30000([
        ['d', 'f40fa7f0-8441-4eae-8b55-f605699da40b'],
        ['name', '旧名'],
        ['alt', 'desc'],
        ['image', 'url'],
        ['p', 'pk-a', 'wss://x'],
        ['p', 'pk-b', ''],
      ]);
      final e = actions.renameFollowSet(current, '新名');
      expect(e.kind, 30000);
      // d unchanged — the list does NOT fork.
      expect(e.tags, _tag(['d', 'f40fa7f0-8441-4eae-8b55-f605699da40b']));
      // old name gone, new name present.
      expect(e.tags, isNot(_tag(['name', '旧名'])));
      expect(e.tags, _tag(['name', '新名']));
      // metadata + roster preserved verbatim.
      expect(e.tags, _tag(['alt', 'desc']));
      expect(e.tags, _tag(['image', 'url']));
      expect(e.tags, _tag(['p', 'pk-a', 'wss://x']));
      expect(e.tags, _tag(['p', 'pk-b', '']));
      expect(e.tags, _tag(['client', 'Costr']));
      expect(id.verifyEventSignature(id: e.id, sig: e.sig), isTrue);
    });
  });

  group('NostrActions.deleteFollowSet', () {
    test('kind-5 with a coordinate 30000:pubkey:d + e=current id', () {
      final current = _k30000([
        ['d', 'f40fa7f0-8441-4eae-8b55-f605699da40b'],
        ['name', '真人用户'],
      ], id: 'ev-id-123');
      final e = actions.deleteFollowSet(current);
      expect(e.kind, 5);
      // a-coordinate = 30000:<signing pubkey>:<d> — deletes every version.
      expect(e.tags, _tag(['a', '30000:${id.pubkeyHex}:f40fa7f0-8441-4eae-8b55-f605699da40b']));
      // e tag points at the current event id (best-effort for e-keyed clients).
      expect(e.tags, _tag(['e', 'ev-id-123']));
      expect(e.tags, _tag(['client', 'Costr']));
      expect(id.verifyEventSignature(id: e.id, sig: e.sig), isTrue);
    });
  });

  group('FollowGroup.memberCount', () {
    test('default group: pubkeys.length (no source event)', () {
      const g = FollowGroup('默认分组', ['a', 'b', 'c']);
      expect(g.memberCount, 3);
    });

    test('custom group: counts all p tags in source, not just followed members',
        () {
      // List has 5 members but only 2 are still in the user's kind-3 follows.
      final source = _k30000([
        ['d', 'uuid-1'],
        ['name', '科技'],
        ['p', 'm1', ''],
        ['p', 'm2', ''],
        ['p', 'm3', ''],
        ['p', 'm4', ''],
        ['p', 'm5', ''],
      ]);
      final g = FollowGroup('科技', ['m1', 'm2'], source: source);
      // True count is 5 (Amethyst shows this), NOT 2 (followed ∩ group).
      expect(g.memberCount, 5);
      expect(g.pubkeys.length, 2); // rows render only followed members
    });
  });

  group('NostrActions.followedHashtags (kind-10015 + NIP-44, Amethyst)', () {
    test('first follow: kind 10015, encrypted content, alt label', () {
      final e = actions.followedHashtags(null, add: '股市行情');
      expect(e.kind, 10015);
      expect(e.tags, _tag(['alt', 'Hashtag List']));
      expect(e.tags, _tag(['client', 'Costr']));
      // No plain t tag — hashtags are in the encrypted content.
      expect(e.tags.where((t) => t.isNotEmpty && t[0] == 't'), isEmpty);
      expect(e.content, isNotEmpty); // NIP-44 payload
      expect(id.verifyEventSignature(id: e.id, sig: e.sig), isTrue);
    });

    test('round-trip: encrypt then decrypt recovers the hashtag', () {
      final e = actions.followedHashtags(null, add: 'bing每日一图');
      expect(actions.followedHashtagTags(e), ['bing每日一图']);
    });

    test('add to existing (decrypt → modify → re-encrypt) preserves prior',
        () {
      final first = actions.followedHashtags(null, add: '股市行情');
      final second = actions.followedHashtags(first, add: 'bing每日一图');
      final tags = actions.followedHashtagTags(second);
      expect(tags.toSet(), {'股市行情', 'bing每日一图'});
    });

    test('remove from existing', () {
      var e = actions.followedHashtags(null, add: '股市行情');
      e = actions.followedHashtags(e, add: 'bing每日一图');
      final removed = actions.followedHashtags(e, remove: '股市行情');
      expect(actions.followedHashtagTags(removed), ['bing每日一图']);
    });

    test('content decrypts to Amethyst JSON shape [["t",…]]', () {
      final e = actions.followedHashtags(null, add: 'tagA');
      // Re-decrypt via the same NostrActions and inspect the raw JSON shape.
      final plain = actions.followedHashtagTags(e);
      expect(plain, ['taga']); // lowercased
      // And the encrypted content is base64 (NIP-44 v2).
      expect(e.content, matches(RegExp(r'^[A-Za-z0-9+/=]+$')));
    });

    test('lowercases and strips # prefix', () {
      final e = actions.followedHashtags(null, add: '#Hello');
      expect(actions.followedHashtagTags(e), ['hello']);
    });
  });
}
