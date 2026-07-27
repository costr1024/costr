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
  });
}
