import 'package:costr/models/event.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Event.fromList', () {
    test('parses a well-formed kind-1 event', () {
      final list = <dynamic>[
        'a' * 64, // id
        'b' * 64, // pubkey
        1700000000,
        1,
        <dynamic>[
          <dynamic>['p', 'c' * 64],
          <dynamic>['e', 'd' * 64, 'reply'],
        ],
        'hello world',
        'e' * 128, // sig
      ];
      final ev = Event.fromList(list);
      expect(ev.id, 'a' * 64);
      expect(ev.pubkey, 'b' * 64);
      expect(ev.createdAt, 1700000000);
      expect(ev.kind, 1);
      expect(ev.content, 'hello world');
      expect(ev.sig, 'e' * 128);
      expect(ev.isTextNote, isTrue);
      expect(ev.isContactList, isFalse);
    });

    test('parses a kind-3 contact list and extracts p-tags', () {
      final pk1 = '1' * 64;
      final pk2 = '2' * 64;
      final list = <dynamic>[
        'id',
        'me',
        1,
        3,
        <dynamic>[
          <dynamic>['p', pk1, 'wss://relay.example', 'petname'],
          <dynamic>['p', pk2],
          <dynamic>['p', pk1], // duplicate → deduped
          <dynamic>['relay', 'wss://x'], // not a p tag → ignored
        ],
        '',
        'sig',
      ];
      final ev = Event.fromList(list);
      expect(ev.isContactList, isTrue);
      expect(ev.pTagPubkeys, [pk1, pk2]);
    });

    test('throws on wrong arity', () {
      expect(
        () => Event.fromList(<dynamic>['a', 'b', 1, 1, [], 'x']),
        throwsFormatException,
      );
    });

    test('throws when tags is not a list', () {
      expect(
        () => Event.fromList(<dynamic>['a', 'b', 1, 1, 'not-a-list', 'x', 's']),
        throwsFormatException,
      );
    });

    test('fromJson parses the object form some relays send', () {
      final m = <String, dynamic>{
        'id': 'a' * 64,
        'pubkey': 'b' * 64,
        'created_at': 1700000000,
        'kind': 1,
        'tags': <dynamic>[
          <dynamic>['p', 'c' * 64],
        ],
        'content': 'hello world',
        'sig': 'e' * 128,
      };
      final ev = Event.fromJson(m);
      expect(ev.id, 'a' * 64);
      expect(ev.pubkey, 'b' * 64);
      expect(ev.createdAt, 1700000000);
      expect(ev.kind, 1);
      expect(ev.content, 'hello world');
      expect(ev.isTextNote, isTrue);
      expect(ev.pTagPubkeys, ['c' * 64]);
    });

    test('fromMessage dispatches array vs object', () {
      final arr = <dynamic>['a' * 64, 'b' * 64, 1, 1, <dynamic>[], 'c', 'd' * 128];
      final obj = <String, dynamic>{
        'id': 'a' * 64,
        'pubkey': 'b' * 64,
        'created_at': 1,
        'kind': 1,
        'tags': <dynamic>[],
        'content': 'c',
        'sig': 'd' * 128,
      };
      expect(Event.fromMessage(arr).id, 'a' * 64);
      expect(Event.fromMessage(obj).id, 'a' * 64);
      expect(() => Event.fromMessage('nope'), throwsFormatException);
    });

    test('mediaAttachments parses NIP-92 imeta tags (x/y and dim)', () {
      final list = <dynamic>[
        'id', 'pk', 1, 1,
        <dynamic>[
          <dynamic>['imeta', 'url https://x/a.jpg', 'm image/jpeg', 'x 1200', 'y 630'],
          <dynamic>['imeta', 'url https://x/v.mp4', 'm video/mp4', 'dim 1920x1080'],
          <dynamic>['other', 'ignore'],
        ],
        'content',
        'sig',
      ];
      final ev = Event.fromList(list);
      final media = ev.mediaAttachments;
      expect(media.length, 2);
      expect(media[0].url, 'https://x/a.jpg');
      expect(media[0].mimeType, 'image/jpeg');
      expect(media[0].width, 1200);
      expect(media[0].height, 630);
      expect(media[0].isImage, isTrue);
      expect(media[1].isVideo, isTrue);
      expect(media[1].width, 1920);
      expect(media[1].height, 1080);
    });

    test('MediaAttachment infers image/video from URL when mimetype absent', () {
      const img = MediaAttachment(url: 'https://x/PHOTO.PNG?w=1');
      const vid = MediaAttachment(url: 'https://x/clip.webm');
      const other = MediaAttachment(url: 'https://x/page.html');
      expect(img.isImage, isTrue);
      expect(vid.isVideo, isTrue);
      expect(other.isImage, isFalse);
      expect(other.isVideo, isFalse);
    });

    test('mediaAttachments ignores malformed imeta without url', () {
      final list = <dynamic>[
        'id', 'pk', 1, 1,
        <dynamic>[
          <dynamic>['imeta', 'm image/jpeg', 'x 100'],
        ],
        'c', 's',
      ];
      expect(Event.fromList(list).mediaAttachments, isEmpty);
    });

    test('hashtags parses NIP-12 t-tags, lowercased + deduped', () {
      final list = <dynamic>[
        'id', 'pk', 1, 1,
        <dynamic>[
          <dynamic>['t', 'Nostr'],
          <dynamic>['t', 'nostr'], // dup after lowercasing
          <dynamic>['t', 'Bitcoin'],
          <dynamic>['e', 'refid'], // not a t tag
          <dynamic>['t', ''], // empty → ignored
        ],
        'c', 's',
      ];
      final ev = Event.fromList(list);
      expect(ev.hashtags, ['nostr', 'bitcoin']);
    });

    test('hashtags also extracts inline #hashtag from content', () {
      final list = <dynamic>[
        'id', 'pk', 1, 1, <dynamic>[],
        'check this #Bitcoin out and #中文 too',
        's',
      ];
      final ev = Event.fromList(list);
      expect(ev.hashtags, ['bitcoin', '中文']);
    });

    test('hashtags dedupes across t-tags and inline content', () {
      final list = <dynamic>[
        'id', 'pk', 1, 1,
        <dynamic>[<dynamic>['t', 'nostr']],
        'posting about #nostr again',
        's',
      ];
      expect(Event.fromList(list).hashtags, ['nostr']);
    });

    test('hashtags ignores markdown headings and URL fragments', () {
      final list = <dynamic>[
        'id', 'pk', 1, 1, <dynamic>[],
        '# A Heading\n\nsee https://example.com/page#section and #realtag',
        's',
      ];
      final ev = Event.fromList(list);
      // '# A Heading' has a space after # → not a tag.
      // '#section' is preceded by '/' inside the URL → ignored.
      expect(ev.hashtags, ['realtag']);
    });

    test('replyToId: reply marker > legacy positional > root marker', () {
      Event ev(List tags) => Event.fromList(<dynamic>[
        'id', 'pk', 1, 1, tags, 'c', 's',
      ]);
      expect(
        ev([
          ['e', 'root-id', 'wss://x', 'root'],
          ['e', 'parent-id', 'wss://x', 'reply'],
        ]).replyToId,
        'parent-id',
      );
      expect(
        ev([
          ['e', 'first-id'],
          ['e', 'parent-id'],
        ]).replyToId,
        'parent-id',
      );
      expect(
        ev([
          ['e', 'root-id', 'wss://x', 'root'],
        ]).replyToId,
        'root-id',
      );
      expect(
        ev([
          ['e', 'mention-id', 'wss://x', 'mention'],
        ]).isReply,
        isFalse,
      );
      expect(ev([]).isReply, isFalse);
      expect(ev([]).replyToId, isNull);
    });
  });
}
