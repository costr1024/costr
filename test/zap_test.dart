import 'dart:convert';

import 'package:costr/nostr/identity.dart';
import 'package:costr/services/zap.dart';
import 'package:costr/utils/bech32_codec.dart';
import 'package:flutter_test/flutter_test.dart';

const _priv =
    '0000000000000000000000000000000000000000000000000000000000000001';
final _signer = Identity.fromPrivkeyHex(_priv);

void main() {
  group('payRequestUri (lud16)', () {
    test('user@host → https://host/.well-known/lnurlp/user', () {
      final uri = payRequestUri('alice@example.com');
      expect(uri.scheme, 'https');
      expect(uri.host, 'example.com');
      expect(uri.path, '/.well-known/lnurlp/alice');
    });

    test('lud06 (lnurl1) decodes to a URL', () {
      // lnurl1 bech32 of "https://example.com/lnurlp/alice"
      // Built from the app's own encodeBech32 to avoid a hand-crafted string.
      final lnurl = _encodeLnurl('https://example.com/lnurlp/alice');
      final uri = payRequestUri(lnurl);
      expect(uri.toString(), 'https://example.com/lnurlp/alice');
    });

    test('malformed (no @) throws', () {
      expect(() => payRequestUri('nodomain'), throwsA(isA<ZapException>()));
    });
  });

  group('resolveLnurlPay', () {
    test('parses a payRequest with allowsNostr', () async {
      final pay = await resolveLnurlPay(
        'alice@example.com',
        (uri) async =>
            '{"callback":"https://x.com/cb?a=1",'
            '"minSendable":1000,"maxSendable":10000000,'
            '"metadata":"m",'
            '"allowsNostr":true,"nostrPubkey":"abc"}',
      );
      expect(pay.callback, 'https://x.com/cb?a=1');
      expect(pay.minSendable, 1000);
      expect(pay.maxSendable, 10000000);
      expect(pay.allowsNostr, isTrue);
      expect(pay.nostrPubkey, 'abc');
    });

    test('string min/max sendable parsed', () async {
      final pay = await resolveLnurlPay(
        'alice@example.com',
        (uri) async =>
            '{"callback":"https://x.com/cb","minSendable":"1000",'
            '"maxSendable":"5000","metadata":""}',
      );
      expect(pay.minSendable, 1000);
      expect(pay.maxSendable, 5000);
      expect(pay.allowsNostr, isFalse);
    });

    test('missing callback throws', () async {
      expect(
        () => resolveLnurlPay(
          'alice@example.com',
          (uri) async => '{"minSendable":1000,"maxSendable":5000}',
        ),
        throwsA(isA<ZapException>()),
      );
    });
  });

  group('requestZapInvoice', () {
    final pay = LnurlPayRequest(
      callback: 'https://x.com/cb',
      minSendable: 1000,
      maxSendable: 1000000000,
      metadata: '',
      allowsNostr: true,
    );

    test(
      'allowsNostr: signs kind-9734 + requests with amount/nostr/lnurl',
      () async {
        Uri? called;
        final invoice = await requestZapInvoice(
          pay: pay,
          amountMsat: 5000,
          recipientPubkey: _signer.pubkeyHex,
          signer: _signer,
          relays: const ['wss://relay.a/'],
          zappedNoteId: 'noteid',
          httpGet: (uri) async {
            called = uri;
            return '{"pr":"lnbc50u1p...","r":"ok"}';
          },
        );
        expect(invoice, 'lnbc50u1p...');
        expect(called, isNotNull);
        expect(called!.queryParameters['amount'], '5000');
        expect(called!.queryParameters['lnurl'], 'https://x.com/cb');
        final nostr = called!.queryParameters['nostr'];
        expect(nostr, isNotNull);
        // The nostr param is the signed kind-9734 event JSON (array form).
        final ev = nostr!.startsWith('{') ? Uri.decodeComponent(nostr) : nostr;
        // It should contain kind 9734 and the p/e/amount tags.
        expect(ev, contains('"kind":9734'));
        expect(ev, contains(_signer.pubkeyHex));
        expect(ev, contains('"noteid"'));
        expect(ev, contains('"amount","5000"'));
      },
    );

    test('no allowsNostr: plain LNURL-pay (amount only, no nostr)', () async {
      final plainPay = LnurlPayRequest(
        callback: 'https://x.com/cb',
        minSendable: 1000,
        maxSendable: 1000000000,
        metadata: '',
        allowsNostr: false,
      );
      Uri? called;
      final invoice = await requestZapInvoice(
        pay: plainPay,
        amountMsat: 1000,
        recipientPubkey: _signer.pubkeyHex,
        signer: _signer,
        relays: const ['wss://relay.a/'],
        httpGet: (uri) async {
          called = uri;
          return '{"pr":"lnbc1..."}';
        },
      );
      expect(invoice, 'lnbc1...');
      expect(called!.queryParameters['amount'], '1000');
      expect(called!.queryParameters.containsKey('nostr'), isFalse);
    });

    test('out-of-range amount throws', () async {
      expect(
        () => requestZapInvoice(
          pay: pay,
          amountMsat: 100, // below minSendable 1000
          recipientPubkey: _signer.pubkeyHex,
          signer: _signer,
          relays: const [],
          httpGet: (uri) async => '{}',
        ),
        throwsA(isA<ZapException>()),
      );
    });

    test('missing pr throws', () async {
      expect(
        () => requestZapInvoice(
          pay: pay,
          amountMsat: 5000,
          recipientPubkey: _signer.pubkeyHex,
          signer: _signer,
          relays: const [],
          httpGet: (uri) async => '{"reason":"rate limited"}',
        ),
        throwsA(isA<ZapException>()),
      );
    });

    test('comment param passed through', () async {
      Uri? called;
      await requestZapInvoice(
        pay: LnurlPayRequest(
          callback: 'https://x.com/cb',
          minSendable: 1000,
          maxSendable: 1000000000,
          metadata: '',
          allowsNostr: false,
        ),
        amountMsat: 1000,
        recipientPubkey: _signer.pubkeyHex,
        signer: _signer,
        relays: const [],
        comment: '谢谢',
        httpGet: (uri) async {
          called = uri;
          return '{"pr":"x"}';
        },
      );
      expect(called!.queryParameters['comment'], '谢谢');
    });

    test('callback existing query params preserved', () async {
      final payWithQ = LnurlPayRequest(
        callback: 'https://x.com/cb?session=42',
        minSendable: 1000,
        maxSendable: 1000000000,
        metadata: '',
        allowsNostr: false,
      );
      Uri? called;
      await requestZapInvoice(
        pay: payWithQ,
        amountMsat: 1000,
        recipientPubkey: _signer.pubkeyHex,
        signer: _signer,
        relays: const [],
        httpGet: (uri) async {
          called = uri;
          return '{"pr":"x"}';
        },
      );
      expect(called!.queryParameters['session'], '42');
      expect(called!.queryParameters['amount'], '1000');
    });
  });
}

String _encodeLnurl(String url) => encodeBech32('lnurl', utf8.encode(url));
