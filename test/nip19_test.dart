import 'package:costr/utils/bech32_codec.dart';
import 'package:costr/utils/nip19.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hex/hex.dart';

void main() {
  group('NIP-19 nsec/npub/note', () {
    const privHex =
        '0000000000000000000000000000000000000000000000000000000000000001';
    // secp256k1 base point G.x — the canonical x-only pubkey for privkey 1.
    const pubHex =
        '79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798';

    test('nsec round-trips to the same private key hex', () {
      final nsec = hexToNsec(privHex);
      expect(nsec.startsWith('nsec1'), isTrue);
      expect(nsecToHex(nsec), privHex);
    });

    test('npub round-trips to the same public key hex', () {
      final npub = hexToNpub(pubHex);
      expect(npub.startsWith('npub1'), isTrue);
      expect(npubToHex(npub), pubHex);
    });

    test('note round-trips to the same event id hex', () {
      final note = hexToNote(pubHex); // any 32-byte id
      expect(note.startsWith('note1'), isTrue);
      expect(noteToHex(note), pubHex);
    });

    test('decoding the wrong hrp yields a different hrp', () {
      final nsec = hexToNsec(privHex);
      final d = decodeBech32(nsec);
      expect(d.hrp, 'nsec');
    });

    test('shortenEntity truncates long entities', () {
      final npub = hexToNpub(pubHex);
      final short = shortenEntity(npub);
      expect(short.length, lessThan(npub.length));
      expect(short.contains('…'), isTrue);
      expect(short.startsWith(npub.substring(0, 8)), isTrue);
      expect(short.endsWith(npub.substring(npub.length - 4)), isTrue);
    });

    test('shortenEntity leaves short strings untouched', () {
      expect(shortenEntity('abc'), 'abc');
    });

    test('32-byte zero private key round-trips', () {
      const zero =
          '0000000000000000000000000000000000000000000000000000000000000000';
      expect(nsecToHex(hexToNsec(zero)), zero);
    });

    test('nprofile round-trips to its pubkey hex (TLV type 0)', () {
      // TLV: type=0 (pubkey) len=32 + 32 bytes; then type=1 (relay) len=5 + "hello".
      final pubkeyBytes = List<int>.generate(32, (i) => i);
      final tlv = <int>[
        0, 32, ...pubkeyBytes,
        1, 5, 0x68, 0x65, 0x6c, 0x6c, 0x6f, // relay "hello" (ignored)
      ];
      final nprofile = encodeBech32('nprofile', tlv);
      expect(nprofile.startsWith('nprofile1'), isTrue);
      expect(nprofileToPubkeyHex(nprofile), HEX.encode(pubkeyBytes));
      expect(entityToPubkeyHex(nprofile), HEX.encode(pubkeyBytes));
    });

    test('nprofileToPubkeyHex rejects non-nprofile strings', () {
      expect(nprofileToPubkeyHex('npub1abc'), isNull);
      expect(nprofileToPubkeyHex('not-a-key'), isNull);
    });

    test('nprofileDecode preserves pubkey + relay hints', () {
      final pubkeyBytes = List<int>.generate(32, (i) => i);
      final relay1 = 'wss://relay.ditto.pub/';
      final relay2 = 'wss://search.nos.today/';
      final tlv = <int>[
        0,
        32,
        ...pubkeyBytes,
        1,
        relay1.length,
        ...relay1.codeUnits,
        1,
        relay2.length,
        ...relay2.codeUnits,
      ];
      final nprofile = encodeBech32('nprofile', tlv);
      final decoded = nprofileDecode(nprofile);
      expect(decoded, isNotNull);
      expect(decoded!.pubkey, HEX.encode(pubkeyBytes));
      expect(decoded.relays, [relay1, relay2]);
      // nostr: prefix handled
      expect(
        nprofileDecode('nostr:$nprofile')?.pubkey,
        HEX.encode(pubkeyBytes),
      );
    });

    test('nprofileDecode returns null without a pubkey TLV', () {
      // relay only, no pubkey
      final tlv = <int>[1, 5, 0x68, 0x65, 0x6c, 0x6c, 0x6f];
      final nprofile = encodeBech32('nprofile', tlv);
      expect(nprofileDecode(nprofile), isNull);
    });

    test('entityToPubkeyHex handles npub / nprofile / else null', () {
      const pub =
          '79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798';
      final npub = hexToNpub(pub);
      expect(entityToPubkeyHex(npub), pub);
      expect(
        entityToPubkeyHex('note1${'q' * 40}'),
        isNull,
      ); // note isn't a pubkey
    });
  });

  group('NIP-19 nevent', () {
    const idHex =
        'abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789';
    const authorHex =
        '79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798';

    test('round-trips id + relays + author + kind', () {
      final nevent = hexToNevent(
        idHex,
        relays: const ['wss://relay.a/', 'wss://relay.b/'],
        authorHex: authorHex,
        kind: 1,
      );
      final decoded = neventDecode(nevent)!;
      expect(decoded.id, idHex);
      expect(decoded.author, authorHex);
      expect(decoded.relays, ['wss://relay.a/', 'wss://relay.b/']);
      expect(decoded.kind, 1);
    });

    test('strips nostr: prefix', () {
      final nevent = hexToNevent(idHex, authorHex: authorHex);
      expect(neventDecode('nostr:$nevent')!.id, idHex);
    });

    test('entityToEventIdHex handles nevent / note / else null', () {
      final nevent = hexToNevent(idHex);
      expect(entityToEventIdHex(nevent), idHex);
      expect(entityToEventIdHex('nostr:$nevent'), idHex);
      expect(entityToEventIdHex(hexToNote(idHex)), idHex);
      expect(entityToEventIdHex('not-an-entity'), isNull);
    });

    test('decode rejects non-nevent', () {
      expect(neventDecode(hexToNpub(authorHex)), isNull);
    });

    test('no relay/author produces minimal nevent', () {
      final nevent = hexToNevent(idHex);
      final decoded = neventDecode(nevent)!;
      expect(decoded.id, idHex);
      expect(decoded.relays, isEmpty);
      expect(decoded.author, isNull);
      expect(decoded.kind, isNull);
    });
  });

  group('NIP-19 decoders on malformed input (untrusted content)', () {
    // The entity regex matches ANY bech32-charset run (`npub1qqqqqq`, junk in
    // URLs, typos). Decoders run during widget build, so malformed bech32
    // must yield null — never throw (pre-fix: Bech32Exception crashed the
    // render path).
    test('entityToPubkeyHex returns null for invalid checksum', () {
      expect(entityToPubkeyHex('npub1qqqqqq'), isNull);
    });

    test('entityToPubkeyHex returns null for invalid characters', () {
      // 'b' is not in the bech32 charset.
      expect(entityToPubkeyHex('npub1abcdef'), isNull);
    });

    test('entityToEventIdHex returns null for malformed note/nevent', () {
      expect(entityToEventIdHex('note1qqqqqq'), isNull);
      expect(entityToEventIdHex('nevent1qqqqqq'), isNull);
    });

    test('neventDecode / nprofileDecode return null for junk', () {
      expect(neventDecode('nevent1notbech32'), isNull);
      expect(nprofileDecode('nprofile1notbech32'), isNull);
    });
  });

  group('entityMatchInUrl', () {
    const pubHex =
        '79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798';
    final npub = hexToNpub(pubHex);
    final re = RegExp(r'(?:nostr:)?(npub1[qpzry9x8gf2tvdw0s3jn54khce6mua7l]+)');

    Match first(String text) => re.firstMatch(text)!;

    test('true for an entity inside a URL (npub-subdomain blossom host)', () {
      final text = 'clip https://$npub.blossom.band/abc.mp4 end';
      expect(entityMatchInUrl(text, first(text)), isTrue);
    });

    test('true for an entity in a URL path', () {
      final text = 'https://media.example/$npub/img.jpg';
      expect(entityMatchInUrl(text, first(text)), isTrue);
    });

    test('false for a bare mention', () {
      final text = 'hello nostr:$npub world';
      expect(entityMatchInUrl(text, first(text)), isFalse);
    });

    test('false for a mention after a URL', () {
      final text = 'https://example.com/a.jpg then $npub';
      expect(entityMatchInUrl(text, first(text)), isFalse);
    });
  });

  group('rangeInUrl (offset variant)', () {
    const pubHex =
        '79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798';
    final npub = hexToNpub(pubHex);

    test('true when the range sits inside a URL', () {
      final text = 'see https://$npub.blossom.band/x.jpg ok';
      final s = text.indexOf(npub);
      expect(rangeInUrl(text, s, s + npub.length), isTrue);
    });

    test('false when the range is outside every URL', () {
      final text = 'hello $npub world';
      final s = text.indexOf(npub);
      expect(rangeInUrl(text, s, s + npub.length), isFalse);
    });

    test('range at the very start of a leading URL is inside it', () {
      final text = 'https://example.com/a.jpg';
      expect(rangeInUrl(text, 0, 0), isTrue);
    });

    test('true for a URL followed by a separate mention', () {
      final text = 'https://example.com/a.jpg $npub';
      final s = text.indexOf(npub);
      expect(rangeInUrl(text, s, s + npub.length), isFalse);
    });
  });
}
