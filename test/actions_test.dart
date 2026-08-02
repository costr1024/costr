import 'package:costr/models/event.dart';
import 'package:costr/nostr/actions.dart';
import 'package:costr/nostr/identity.dart';
import 'package:flutter_test/flutter_test.dart';

const _priv =
    '0000000000000000000000000000000000000000000000000000000000000001';

Event _ev(String id, {List<List<dynamic>> tags = const []}) => Event(
  id: id,
  pubkey: 'pubkey-x',
  createdAt: 1700000000,
  kind: 1,
  tags: tags,
  content: 'parent',
  sig: 's',
);

Matcher _tag(List<String> t) => contains(equals(t));

void main() {
  group('NostrActions', () {
    final id = Identity.fromPrivkeyHex(_priv);
    final actions = NostrActions(id);

    test('reply: root + reply e tags + p tag', () {
      final parent = _ev('parent-id');
      final r = actions.reply(parent, 'nice');
      expect(r.kind, 1);
      expect(r.content, 'nice');
      expect(r.tags, _tag(['e', 'parent-id', '', 'root']));
      expect(r.tags, _tag(['e', 'parent-id', '', 'reply']));
      expect(r.tags, _tag(['p', 'pubkey-x', '']));
      expect(id.verifyEventSignature(id: r.id, sig: r.sig), isTrue);
    });

    test('reply to a reply uses the thread root', () {
      final parent = _ev(
        'reply-id',
        tags: [
          ['e', 'root-id', '', 'root'],
          ['e', 'reply-id', '', 'reply'],
        ],
      );
      final r = actions.reply(parent, 're');
      expect(r.tags, _tag(['e', 'root-id', '', 'root']));
      expect(r.tags, _tag(['e', 'reply-id', '', 'reply']));
    });

    test('reaction (unicode emoji): kind 7, e/p/k tags', () {
      final target = _ev('target-id');
      final r = actions.reaction(target, '🔥');
      expect(r.kind, 7);
      expect(r.content, '🔥');
      expect(r.tags, _tag(['e', 'target-id', '', 'pubkey-x']));
      expect(r.tags, _tag(['p', 'pubkey-x', '']));
      expect(r.tags, _tag(['k', '1']));
      expect(r.tags.where((t) => t[0] == 'emoji'), isEmpty);
      expect(id.verifyEventSignature(id: r.id, sig: r.sig), isTrue);
    });

    test('reaction (custom emoji): adds NIP-30 emoji tag', () {
      final target = _ev('target-id');
      final r = actions.reaction(
        target,
        ':costr:',
        customShortcode: 'costr',
        customUrl: 'https://example.com/costr.png',
      );
      expect(r.content, ':costr:');
      expect(r.tags, _tag(['emoji', 'costr', 'https://example.com/costr.png']));
    });

    test('repost (NIP-18 kind 6): content is the reposted event JSON', () {
      final target = _ev('target-id');
      final r = actions.repost(target);
      expect(r.kind, 6);
      expect(r.tags, _tag(['e', 'target-id', '']));
      expect(r.tags, _tag(['p', 'pubkey-x', '']));
      expect(r.content.contains('target-id'), isTrue);
      expect(id.verifyEventSignature(id: r.id, sig: r.sig), isTrue);
    });

    test('userStatus (NIP-38 kind 30315, d=general): content = status text', () {
      final s = actions.userStatus('忙碌中');
      expect(s.kind, 30315);
      expect(s.content, '忙碌中');
      expect(s.tags, _tag(['d', 'general']));
      expect(id.verifyEventSignature(id: s.id, sig: s.sig), isTrue);
      // Empty text clears the status.
      expect(actions.userStatus('').content, '');
    });

    test('deleteEvent (NIP-09 kind 5): e tag points at target', () {
      final target = _ev('deadbeef');
      final d = actions.deleteEvent(target);
      expect(d.kind, 5);
      expect(d.tags, _tag(['e', 'deadbeef']));
      expect(id.verifyEventSignature(id: d.id, sig: d.sig), isTrue);
    });

    test('quote: kind 1 with nostr:note1 ref + e mention tag', () {
      final quoted = _ev('a' * 64);
      final r = actions.quote(quoted, 'well said');
      expect(r.kind, 1);
      expect(r.content, contains('well said'));
      expect(r.content, contains('nostr:note1'));
      expect(r.tags, _tag(['e', 'a' * 64, '', 'mention']));
      expect(r.tags, _tag(['p', 'pubkey-x', '']));
      expect(id.verifyEventSignature(id: r.id, sig: r.sig), isTrue);
    });

    test('relay hint is threaded into e/p tags when provided', () {
      const relay = 'wss://relay.example.com';
      final targetId = 'b' * 64;
      final rootId = 'a' * 64;
      final target = _ev(targetId, tags: [
        ['e', rootId, '', 'root'],
      ]);
      // reply
      final r = actions.reply(target, 'x', relay: relay);
      expect(r.tags, _tag(['e', rootId, relay, 'root']));
      expect(r.tags, _tag(['e', targetId, relay, 'reply']));
      expect(r.tags, _tag(['p', 'pubkey-x', relay]));
      // repost
      final rp = actions.repost(target, relay: relay);
      expect(rp.tags, _tag(['e', targetId, relay]));
      expect(rp.tags, _tag(['p', 'pubkey-x', relay]));
      // reaction
      final rx = actions.reaction(target, '🔥', relay: relay);
      expect(rx.tags, _tag(['e', targetId, relay, 'pubkey-x']));
      expect(rx.tags, _tag(['p', 'pubkey-x', relay]));
      // quote
      final q = actions.quote(target, 'q', relay: relay);
      expect(q.tags, _tag(['e', targetId, relay, 'mention']));
      expect(q.tags, _tag(['p', 'pubkey-x', relay]));
    });

    test('follow: kind 3 with full p-tag list, preserves existing + relay', () {
      final existing = _ev(
        'k3',
        tags: [
          ['p', 'existing-pk', 'wss://old.relay', 'pet'],
        ],
      );
      final r = actions.follow(
        existing,
        'new-pk',
        relay: 'wss://relay.damus.io/',
      );
      expect(r.kind, 3);
      expect(r.tags, _tag(['p', 'existing-pk', 'wss://old.relay', 'pet']));
      expect(r.tags, _tag(['p', 'new-pk', 'wss://relay.damus.io/']));
    });

    test('follow: adding an already-followed pubkey dedups', () {
      final existing = _ev(
        'k3',
        tags: [
          ['p', 'pk-1', ''],
        ],
      );
      final r = actions.follow(existing, 'pk-1');
      expect(r.tags.where((t) => t[1] == 'pk-1').length, 1);
    });

    // ---- NIP-51 kind-30000 categorized follow sets ----

    group('followCategory', () {
      Event k3(String evtId, {List<List<dynamic>> tags = const []}) => Event(
            id: evtId,
            pubkey: id.pubkeyHex,
            createdAt: 1700000000,
            kind: 30000,
            tags: tags,
            content: '',
            sig: 's',
          );

      test('new list: UUID d + name + p + client (Amethyst convention)', () {
        final r = actions.followCategory(null, 'new-pk', '真人用户');
        expect(r.kind, 30000);
        // d is a stable opaque UUID (NOT the human name) so renames never
        // fork the list; name carries the human name.
        final d = r.tags.firstWhere((t) => t[0] == 'd');
        expect(d[1], isNot('真人用户'));
        expect(d[1], matches(RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
        expect(r.tags, _tag(['name', '真人用户']));
        expect(r.tags, _tag(['p', 'new-pk', '']));
        expect(r.tags, _tag(['client', 'Costr']));
        expect(id.verifyEventSignature(id: r.id, sig: r.sig), isTrue);
      });

      test('edit Amethyst list: preserves UUID d + name + metadata, adds p',
          () {
        // An Amethyst-authored list: d=UUID, name="真人用户", plus alt/desc.
        final amethyst = k3(
          'amethyst-list',
          tags: [
            ['d', 'f40fa7f0-8441-4eae-8b55-f605699da40b'],
            ['alt', 'List of people'],
            ['name', '真人用户'],
            ['description', 'a group'],
            ['p', 'existing-pk', 'wss://relay.damus.io/'],
          ],
        );
        final r = actions.followCategory(amethyst, 'new-pk', '真人用户');
        // Real d (UUID) preserved — NOT rewritten to the display name.
        expect(
          r.tags,
          _tag(['d', 'f40fa7f0-8441-4eae-8b55-f605699da40b']),
        );
        // Human name + other metadata preserved.
        expect(r.tags, _tag(['name', '真人用户']));
        expect(r.tags, _tag(['alt', 'List of people']));
        expect(r.tags, _tag(['description', 'a group']));
        // Existing p kept, new p added.
        expect(r.tags, _tag(['p', 'existing-pk', 'wss://relay.damus.io/']));
        expect(r.tags, _tag(['p', 'new-pk', '']));
        expect(r.tags, _tag(['client', 'Costr']));
        // No duplicate client.
        expect(
          r.tags.where((t) => t[0] == 'client').length,
          1,
        );
      });

      test('edit list: adding an already-member pubkey dedups', () {
        final existing = k3(
          'lst',
          tags: [
            ['d', 'friends'],
            ['name', 'friends'],
            ['p', 'dup-pk', ''],
          ],
        );
        final r = actions.followCategory(existing, 'dup-pk', 'friends');
        expect(r.tags.where((t) => t[0] == 'p' && t[1] == 'dup-pk').length, 1);
        // d + name still present exactly once.
        expect(r.tags.where((t) => t[0] == 'd').length, 1);
        expect(r.tags.where((t) => t[0] == 'name').length, 1);
      });
    });
  });
}
