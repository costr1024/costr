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
  });
}
