// Unit tests for the Blossom speed test (services/blossom_upload.dart):
// fresh test-data generation, the upload→download→cleanup measurement flow
// (success and every failure branch), and a regression guard for the
// per-server refactor of blossomUpload. All network is MockClient — no real
// requests.
import 'dart:convert';

import 'package:costr/nostr/identity.dart';
import 'package:costr/services/blossom_upload.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _priv =
    '0000000000000000000000000000000000000000000000000000000000000001';
const _server = 'https://blossom.example/';

/// Decodes the kind-24242 auth event out of an `Authorization: Nostr …`
/// header so tests can assert what was signed.
Map<String, dynamic> _decodeAuth(String? header) {
  expect(header, isNotNull, reason: 'Authorization header missing');
  expect(header!.startsWith('Nostr '), isTrue);
  return jsonDecode(utf8.decode(base64Url.decode(header.substring(6))))
      as Map<String, dynamic>;
}

List<String> _tagValues(Map<String, dynamic> event, String tagName) =>
    (event['tags'] as List<dynamic>)
        .whereType<List<dynamic>>()
        .where((t) => t.isNotEmpty && t.first == tagName)
        .map((t) => t.length > 1 ? t[1].toString() : '')
        .toList();

void main() {
  final identity = Identity.fromPrivkeyHex(_priv);

  group('blossomSpeedTestBytes', () {
    test('default size is 10 MiB and custom sizes work', () {
      expect(blossomSpeedTestBytes().length, 10 * 1024 * 1024);
      expect(blossomSpeedTestBytes(size: 0).length, 0);
      expect(blossomSpeedTestBytes(size: 7).length, 7); // not a multiple of 4
    });

    test('data is fresh on every call (no sha256 dedupe shortcut)', () {
      final a = blossomSpeedTestBytes(size: 4096);
      final b = blossomSpeedTestBytes(size: 4096);
      expect(crypto.sha256.convert(a), isNot(crypto.sha256.convert(b)));
    });
  });

  group('measureBlossomSpeed', () {
    // Small payload keeps the tests fast; the flow is size-agnostic.
    final bytes = blossomSpeedTestBytes(size: 64 * 1024);
    final sha = crypto.sha256.convert(bytes).toString();

    test('all green: measures upload AND download, then cleans up', () async {
      String? uploadAuth;
      String? deleteAuth;
      Uri? deleteUrl;
      final client = MockClient((req) async {
        if (req.method == 'PUT' && req.url.path.endsWith('/upload')) {
          uploadAuth = req.headers['Authorization'];
          expect(req.headers['Content-Type'], 'video/mp4');
          expect(req.headers['X-SHA-256'], sha);
          expect(req.bodyBytes.length, bytes.length);
          return http.Response(
            jsonEncode({'url': 'https://blossom.example/$sha.mp4'}),
            200,
          );
        }
        if (req.method == 'GET') {
          expect(req.url.toString(), 'https://blossom.example/$sha.mp4');
          return http.Response.bytes(List.filled(32 * 1024, 7), 200);
        }
        if (req.method == 'DELETE') {
          deleteAuth = req.headers['Authorization'];
          deleteUrl = req.url;
          return http.Response('', 200);
        }
        return http.Response('', 500);
      });

      final speed = await measureBlossomSpeed(
        identity,
        _server,
        testBytes: bytes,
        client: client,
      );
      expect(speed.uploadMBps, isNotNull);
      expect(speed.uploadMBps!, greaterThan(0));
      expect(speed.downloadMBps, isNotNull);
      expect(speed.downloadMBps!, greaterThan(0));

      // Upload auth event: t=upload, correct hash / mime / size.
      final upEvent = _decodeAuth(uploadAuth);
      expect(upEvent['kind'], 24242);
      expect(_tagValues(upEvent, 't'), ['upload']);
      expect(_tagValues(upEvent, 'x'), [sha]);
      expect(_tagValues(upEvent, 'm'), ['video/mp4']);
      expect(_tagValues(upEvent, 'size'), ['${bytes.length}']);

      // Cleanup: BUD delete endpoint + t=delete auth for the same hash.
      expect(deleteUrl.toString(), 'https://blossom.example/$sha');
      final delEvent = _decodeAuth(deleteAuth);
      expect(delEvent['kind'], 24242);
      expect(_tagValues(delEvent, 't'), ['delete']);
      expect(_tagValues(delEvent, 'x'), [sha]);
    });

    test('upload failure → both speeds null, no GET or DELETE', () async {
      var sawGetOrDelete = false;
      final client = MockClient((req) async {
        if (req.method == 'GET' || req.method == 'DELETE') {
          sawGetOrDelete = true;
        }
        return http.Response('', 500);
      });
      final speed = await measureBlossomSpeed(
        identity,
        _server,
        testBytes: bytes,
        client: client,
      );
      expect(speed.uploadMBps, isNull);
      expect(speed.downloadMBps, isNull);
      expect(sawGetOrDelete, isFalse);
    });

    test(
      'download failure → upload speed kept, cleanup still attempted',
      () async {
        var deleteAttempted = false;
        final client = MockClient((req) async {
          if (req.method == 'PUT') {
            return http.Response(
              jsonEncode({'url': 'https://blossom.example/$sha.mp4'}),
              200,
            );
          }
          if (req.method == 'GET') return http.Response('', 500);
          if (req.method == 'DELETE') {
            deleteAttempted = true;
            return http.Response('', 200);
          }
          return http.Response('', 500);
        });
        final speed = await measureBlossomSpeed(
          identity,
          _server,
          testBytes: bytes,
          client: client,
        );
        expect(speed.uploadMBps, greaterThan(0));
        expect(speed.downloadMBps, isNull);
        expect(deleteAttempted, isTrue);
      },
    );

    test('DELETE failure does not taint the result', () async {
      final client = MockClient((req) async {
        if (req.method == 'PUT') {
          return http.Response(
            jsonEncode({'url': 'https://blossom.example/$sha.mp4'}),
            200,
          );
        }
        if (req.method == 'GET') {
          return http.Response.bytes(List.filled(1024, 7), 200);
        }
        return http.Response('', 500); // DELETE rejected
      });
      final speed = await measureBlossomSpeed(
        identity,
        _server,
        testBytes: bytes,
        client: client,
      );
      expect(speed.uploadMBps, greaterThan(0));
      expect(speed.downloadMBps, greaterThan(0));
    });

    test('timeout → upload counted as failed', () async {
      final client = MockClient((req) async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        return http.Response('', 200);
      });
      final speed = await measureBlossomSpeed(
        identity,
        _server,
        testBytes: bytes,
        timeout: const Duration(milliseconds: 20),
        client: client,
      );
      expect(speed.uploadMBps, isNull);
      expect(speed.downloadMBps, isNull);
    });
  });

  test(
    'blossomUpload regression: skips a failing server, uses the next',
    () async {
      final hits = <String>[];
      final client = MockClient((req) async {
        hits.add(req.url.host);
        if (req.url.host == 'bad.example') return http.Response('', 500);
        return http.Response(
          jsonEncode({'url': 'https://good.example/file.png', 'sha256': 's'}),
          200,
        );
      });
      final result = await blossomUpload(
        identity,
        utf8.encode('costr'),
        mimetype: 'image/png',
        servers: const ['https://bad.example/', 'https://good.example/'],
        client: client,
      );
      expect(result, isNotNull);
      expect(result!.url, 'https://good.example/file.png');
      expect(hits, ['bad.example', 'good.example']);
    },
  );
}
