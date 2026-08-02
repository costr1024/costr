// Tests for the proxy-retry image helpers ([proxiedUrl], [shouldProxyRetry]).

import 'dart:async';
import 'dart:io';

import 'package:costr/widgets/proxied_network_image.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('proxiedUrl', () {
    test('wraps a plain https url in the proxy prefix', () {
      expect(
        proxiedUrl('https://cdn.example.com/x.png'),
        'https://proxy.bostr.online/https://cdn.example.com/x.png',
      );
    });

    test('wraps a plain http url too', () {
      expect(
        proxiedUrl('http://cdn.example.com/x.mp4'),
        'https://proxy.bostr.online/http://cdn.example.com/x.mp4',
      );
    });

    test('is idempotent — an already-proxied url is unchanged', () {
      const proxied = 'https://proxy.bostr.online/https://cdn.example.com/x.png';
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
