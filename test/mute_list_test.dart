// Unit tests for NostrActions mute list (NIP-51 kind-10000, Amethyst interop):
// public p/word/t/e tags + NIP-44-encrypted private entries in .content.
import 'package:costr/models/mute_set.dart';
import 'package:costr/nostr/actions.dart';
import 'package:costr/nostr/identity.dart';
import 'package:flutter_test/flutter_test.dart';

const _priv = '0000000000000000000000000000000000000000000000000000000000000001';

void main() {
  final id = Identity.fromPrivkeyHex(_priv);
  final actions = NostrActions(id);

  group('NostrActions.muteList', () {
    test('first private mute: kind 10000, NIP-44 content, no public tag', () {
      final e = actions.muteList(
        null,
        entry: ['p', 'a'.padLeft(64, 'a')],
        add: true,
        publicList: false,
      );
      expect(e.kind, 10000);
      // No public p tag — it's in the encrypted content.
      expect(e.tags.where((t) => t.isNotEmpty && t[0] == 'p'), isEmpty);
      expect(e.content, isNotEmpty); // NIP-44 payload
      expect(id.verifyEventSignature(id: e.id, sig: e.sig), isTrue);
    });

    test('private round-trip: encrypt then muteSetOf recovers the pubkey', () {
      final pk = 'b'.padLeft(64, 'b');
      final e = actions.muteList(null, entry: ['p', pk], add: true, publicList: false);
      final set = actions.muteSetOf(e);
      expect(set.pubkeys, contains(pk));
      expect(set.pubkeys.length, 1);
    });

    test('public mute: plain tag, no content', () {
      final e = actions.muteList(
        null,
        entry: ['word', 'spam'],
        add: true,
        publicList: true,
      );
      expect(e.tags, contains(equals(['word', 'spam'])));
      expect(e.content, '');
      final set = actions.muteSetOf(e);
      expect(set.words, contains('spam'));
    });

    test('private add preserves prior private + public entries', () {
      final pk1 = 'c'.padLeft(64, 'c');
      var e = actions.muteList(null, entry: ['p', pk1], add: true, publicList: false);
      e = actions.muteList(e, entry: ['word', 'ad'], add: true, publicList: false);
      final set = actions.muteSetOf(e);
      expect(set.pubkeys, contains(pk1));
      expect(set.words, contains('ad'));
    });

    test('remove a private entry', () {
      final pk = 'd'.padLeft(64, 'd');
      var e = actions.muteList(null, entry: ['p', pk], add: true, publicList: false);
      e = actions.muteList(e, entry: ['p', pk], add: false, publicList: false);
      final set = actions.muteSetOf(e);
      expect(set.pubkeys, isEmpty);
    });

    test('public + private union in muteSetOf', () {
      // Public p + word tags, plus encrypted private p.
      final pub = actions.muteList(null, entry: ['p', 'e'.padLeft(64, 'e')], add: true, publicList: true);
      final both = actions.muteList(pub, entry: ['p', 'f'.padLeft(64, 'f')], add: true, publicList: false);
      final set = actions.muteSetOf(both);
      expect(set.pubkeys.length, 2);
    });

    test('hashtag mute lowercased + t tag', () {
      final e = actions.muteList(null, entry: ['t', 'NSFW'], add: true, publicList: true);
      final set = actions.muteSetOf(e);
      expect(set.hashtags, contains('nsfw'));
    });
  });

  group('MuteSet matching', () {
    test('contentHasMutedWord is case-insensitive substring', () {
      const set = MuteSet(words: {'广告', 'spam'});
      expect(set.contentHasMutedWord('快来看广告啦'), true);
      expect(set.contentHasMutedWord('SPAM content'), true);
      expect(set.contentHasMutedWord('clean post'), false);
      expect(set.contentHasMutedWord(''), false);
    });

    test('hasMutedHashtag matches lowercased', () {
      const set = MuteSet(hashtags: {'nsfw'});
      expect(set.hasMutedHashtag(['NSFW', 'art']), true);
      expect(set.hasMutedHashtag(['art']), false);
    });
  });
}
