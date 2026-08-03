// Tests for the proxy-retry image helpers ([proxiedUrl], [shouldProxyRetry]).

import 'dart:async';
import 'dart:io';

import 'package:costr/widgets/proxied_network_image.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('proxiedUrl', () {
    test('routes an https url through the proxy as a scheme-less origin', () {
      // The mirror wants /<origin-domain>/<path> — a scheme'd url makes it
      // parse "https:" as the origin domain → 400 Invalid origin domain.
      expect(
        proxiedUrl('https://cdn.example.com/x.png'),
        'https://proxy.bostr.online/cdn.example.com/x.png',
      );
    });

    test('strips the http scheme too', () {
      expect(
        proxiedUrl('http://cdn.example.com/x.mp4'),
        'https://proxy.bostr.online/cdn.example.com/x.mp4',
      );
    });

    test('keeps the query string intact for the upstream origin', () {
      expect(
        proxiedUrl('https://cdn.example.com/x.png?sig=abc&exp=123'),
        'https://proxy.bostr.online/cdn.example.com/x.png?sig=abc&exp=123',
      );
    });

    test('is idempotent — an already-proxied url is unchanged', () {
      const proxied = 'https://proxy.bostr.online/cdn.example.com/x.png';
      expect(proxiedUrl(proxied), proxied);
    });

    test('empty input passes through', () {
      expect(proxiedUrl(''), '');
    });
  });

  group('shouldProxyRetry', () {
    test('false for a 404 (image absent — proxy cannot help)', () {
      expect(shouldProxyRetry(const HttpException('404 Not Found')), isFalse);
      expect(shouldProxyRetry(Exception('HTTP 404: not found')), isFalse);
    });

    test('true for socket / timeout / TLS failures (blocked domain)', () {
      expect(shouldProxyRetry(const SocketException('host unreachable')), isTrue);
      expect(shouldProxyRetry(TimeoutException('timed out')), isTrue);
      expect(shouldProxyRetry(const HandshakeException('TLS reset')), isTrue);
    });

    test('true for a generic/unknown error (default to retry)', () {
      expect(shouldProxyRetry(Exception('connection reset by peer')), isTrue);
    });
  });
}
