// Unit tests for the server-list rules (纯函数层): normalization, set
// equality, per-category limits and the add-field validation messages. The
// kind-10002 sync-marker comparison reuses these exact functions, so their
// behavior is pinned down here.
import 'package:costr/app/server_list_rules.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('normalizeServerUrl', () {
    test('trims whitespace', () {
      expect(normalizeServerUrl('  wss://a.example  '), 'wss://a.example');
    });

    test('strips trailing slashes (all of them)', () {
      expect(normalizeServerUrl('wss://a.example/'), 'wss://a.example');
      expect(normalizeServerUrl('wss://a.example///'), 'wss://a.example');
    });

    test('lower-cases (hosts are case-insensitive; dedupes Foo vs foo)', () {
      expect(
        normalizeServerUrl('wss://Foo.EXAMPLE.com'),
        'wss://foo.example.com',
      );
      expect(
        normalizeServerUrl('HTTPS://Blossom.Ditto.PUB/'),
        'https://blossom.ditto.pub',
      );
    });

    test('empty stays empty', () {
      expect(normalizeServerUrl('   '), '');
    });

    test('scheme-only input keeps its separator (stripping stops at ://)', () {
      expect(normalizeServerUrl('wss://'), 'wss://');
      expect(normalizeServerUrl('https://'), 'https://');
    });
  });

  group('normalizeServerList', () {
    test('dedups case/slash variants, keeps first-seen order', () {
      expect(
        normalizeServerList([
          'wss://b.example/',
          'wss://A.example',
          'wss://b.example',
          'WSS://a.example/',
          '  ',
        ]),
        ['wss://b.example', 'wss://a.example'],
      );
    });
  });

  group('sameServerSet', () {
    test('order-insensitive', () {
      expect(
        sameServerSet(['wss://a', 'wss://b'], ['wss://b', 'wss://a']),
        isTrue,
      );
    });

    test('trailing slash + case differences are NOT a change', () {
      expect(sameServerSet(['wss://a.example/'], ['WSS://a.example']), isTrue);
    });

    test('whitespace-padded entries ignored on both sides', () {
      expect(sameServerSet(['wss://a', '  '], ['wss://a']), isTrue);
    });

    test('different membership is a change', () {
      expect(sameServerSet(['wss://a'], ['wss://b']), isFalse);
      expect(sameServerSet(['wss://a'], ['wss://a', 'wss://b']), isFalse);
    });
  });

  group('limits', () {
    test('cap is 10 for every category', () {
      expect(maxServersPerCategory, 10);
    });

    test('minimums: relay 3, search/indexer/blossom 1', () {
      expect(minServersFor(ServerCategory.relay), 3);
      expect(minServersFor(ServerCategory.search), 1);
      expect(minServersFor(ServerCategory.indexer), 1);
      expect(minServersFor(ServerCategory.blossom), 1);
    });

    test('every category has a config key', () {
      for (final c in ServerCategory.values) {
        expect(serverListKeys[c], isNotNull);
      }
      expect(serverListKeys[ServerCategory.relay], 'relay_list');
      expect(serverListKeys[ServerCategory.blossom], 'blossom_list');
    });
  });

  group('serverUrlError', () {
    final ws = ServerCategory.relay;
    final blossom = ServerCategory.blossom;

    test('empty input', () {
      expect(serverUrlError(ws, '   ', existing: const []), '请先输入服务器地址');
    });

    test('list already at the cap', () {
      final full = List.generate(10, (i) => 'wss://r$i.example');
      expect(
        serverUrlError(ws, 'wss://new.example', existing: full),
        '最多只能添加 10 台服务器',
      );
    });

    test('relay/search/indexer need a ws(s) scheme', () {
      for (final c in [
        ServerCategory.relay,
        ServerCategory.search,
        ServerCategory.indexer,
      ]) {
        expect(
          serverUrlError(c, 'https://a.example', existing: const []),
          '这看起来不是中继服务器地址，地址应以 wss:// 开头',
        );
        expect(
          serverUrlError(c, 'a.example', existing: const []),
          '这看起来不是中继服务器地址，地址应以 wss:// 开头',
        );
        // Both ws:// and wss:// accepted.
        expect(
          serverUrlError(c, 'wss://a.example', existing: const []),
          isNull,
        );
        expect(serverUrlError(c, 'ws://a.example', existing: const []), isNull);
      }
    });

    test('blossom needs https', () {
      expect(
        serverUrlError(blossom, 'http://a.example', existing: const []),
        '这看起来不是图床地址，地址应以 https:// 开头',
      );
      expect(
        serverUrlError(blossom, 'wss://a.example', existing: const []),
        '这看起来不是图床地址，地址应以 https:// 开头',
      );
      expect(
        serverUrlError(blossom, 'https://a.example', existing: const []),
        isNull,
      );
    });

    test('scheme-only URL has no host', () {
      expect(
        serverUrlError(ws, 'wss://', existing: const []),
        '这看起来不是一个有效的服务器地址',
      );
    });

    test('duplicate (case- and slash-insensitive)', () {
      expect(
        serverUrlError(
          ws,
          'WSS://A.example/',
          existing: const ['wss://a.example'],
        ),
        '这台服务器已经在列表里了',
      );
    });

    test('valid relay URL passes', () {
      expect(
        serverUrlError(
          ws,
          'wss://relay.new.example/',
          existing: const ['wss://other.example'],
        ),
        isNull,
      );
    });
  });

  group('categoryDisplayName', () {
    test('plain-language names for all four categories', () {
      expect(categoryDisplayName(ServerCategory.relay), '中继服务器');
      expect(categoryDisplayName(ServerCategory.search), '搜索中继');
      expect(categoryDisplayName(ServerCategory.indexer), '索引中继');
      expect(categoryDisplayName(ServerCategory.blossom), 'Blossom 图床');
    });
  });

  group('write success rate', () {
    test('fewer than 3 samples → no verdict', () {
      expect(lowWriteSuccessRate(const []), isNull);
      expect(lowWriteSuccessRate(const [false]), isNull);
      expect(lowWriteSuccessRate(const [false, false]), isNull);
      expect(writeRateWarning(const [false, false]), isNull);
    });

    test('half or better accepted → healthy', () {
      expect(lowWriteSuccessRate(const [true, false]), isNull);
      expect(lowWriteSuccessRate(const [true, true, false]), isFalse);
      expect(lowWriteSuccessRate(const [true, false, true, false]), isFalse);
      expect(writeRateWarning(const [true, false, true, false]), isNull);
    });

    test('fewer than half accepted → low', () {
      expect(lowWriteSuccessRate(const [false, false, false]), isTrue);
      expect(lowWriteSuccessRate(const [true, false, false]), isTrue);
      expect(
        lowWriteSuccessRate(const [true, false, false, false, false]),
        isTrue,
      );
    });

    test('warning names the actual counts', () {
      expect(
        writeRateWarning(const [true, false, false, false, false]),
        '近期发送 5 次仅成功 1 次，建议更换',
      );
      expect(
        writeRateWarning(const [false, false, false]),
        '近期发送 3 次仅成功 0 次，建议更换',
      );
    });
  });

  group('nip65RelayTags', () {
    test('ordinary relay → bare r tag (read+write)', () {
      expect(nip65RelayTags(['wss://relay.ditto.pub/']), [
        ['r', 'wss://relay.ditto.pub'],
      ]);
    });

    test('bostr plain URL → read marker; bostr /inbox → write marker', () {
      expect(
        nip65RelayTags([
          'wss://relay.bostr.online/',
          'wss://relay.bostr.online/inbox',
        ]),
        [
          ['r', 'wss://relay.bostr.online', 'read'],
          ['r', 'wss://relay.bostr.online/inbox', 'write'],
        ],
      );
    });

    test('mixed list preserves order and marks only the bostr pair', () {
      expect(
        nip65RelayTags([
          'wss://relay.gulugulu.moe/',
          'wss://relay.bostr.online/',
          'wss://relay.bostr.online/inbox',
          'wss://nostr.data.haus/',
        ]),
        [
          ['r', 'wss://relay.gulugulu.moe'],
          ['r', 'wss://relay.bostr.online', 'read'],
          ['r', 'wss://relay.bostr.online/inbox', 'write'],
          ['r', 'wss://nostr.data.haus'],
        ],
      );
    });

    test('skips empty entries', () {
      expect(nip65RelayTags(['', '  ']), isEmpty);
    });
  });

  group('isInboxRelay', () {
    test('every write relay is an inbox relay', () {
      // The dedicated write-only endpoint…
      expect(isInboxRelay('wss://relay.bostr.online/inbox'), isTrue);
      expect(isInboxRelay('WSS://relay.bostr.online/inbox/'), isTrue);
      // …and every ordinary read+write relay are all inboxes too.
      expect(isInboxRelay('wss://relay.ditto.pub'), isTrue);
      expect(isInboxRelay('wss://relay.gulugulu.moe/'), isTrue);
      expect(isInboxRelay('wss://other.example/inbox'), isTrue);
    });

    test('only the read-only bostr plain relay is NOT an inbox', () {
      expect(isInboxRelay('wss://relay.bostr.online'), isFalse);
      expect(isInboxRelay('WSS://relay.bostr.online/'), isFalse);
    });
  });

  group('isOutboxRelay', () {
    test('every read relay is an outbox relay', () {
      // The read-only bostr plain relay…
      expect(isOutboxRelay('wss://relay.bostr.online'), isTrue);
      expect(isOutboxRelay('WSS://relay.bostr.online/'), isTrue);
      // …and every ordinary read+write relay are all outboxes too.
      expect(isOutboxRelay('wss://relay.ditto.pub'), isTrue);
      expect(isOutboxRelay('wss://relay.gulugulu.moe/'), isTrue);
    });

    test('only the write-only bostr /inbox endpoint is NOT an outbox', () {
      expect(isOutboxRelay('wss://relay.bostr.online/inbox'), isFalse);
      expect(isOutboxRelay('WSS://relay.bostr.online/inbox/'), isFalse);
    });
  });

  test('inbox/outbox classification mirrors nip65RelayTags markers', () {
    const urls = [
      'wss://relay.gulugulu.moe/',
      'wss://relay.bostr.online/',
      'wss://relay.bostr.online/inbox',
      'wss://nostr.data.haus/',
    ];
    for (final u in urls) {
      final tag = nip65RelayTags([u]).single;
      // Bare `r` tag (len 2) = read+write; a 3rd field narrows the role.
      final hasRead = tag.length == 2 || tag[2] == 'read';
      final hasWrite = tag.length == 2 || tag[2] == 'write';
      expect(isOutboxRelay(u), hasRead, reason: 'outbox for $u');
      expect(isInboxRelay(u), hasWrite, reason: 'inbox for $u');
    }
  });
}
