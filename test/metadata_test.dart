import 'dart:convert';

import 'package:costr/models/metadata.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Metadata', () {
    test('parses a standard kind-0 content object', () {
      final m = Metadata.fromJson(
        jsonDecode(
              jsonEncode({
                'name': 'alice',
                'display_name': 'Alice Liddell',
                'picture': 'https://example.com/alice.png',
                'about': 'curious',
                'website': 'https://alice.example',
                'banner': 'https://example.com/banner.png',
                'nip05': 'alice@example.com',
              }),
            )
            as Map<String, dynamic>,
      );
      expect(m.name, 'alice');
      expect(m.displayName, 'Alice Liddell');
      expect(m.picture, 'https://example.com/alice.png');
      expect(m.about, 'curious');
      expect(m.bestName, 'Alice Liddell');
      expect(m.initial, 'A');
    });

    test('bestName falls back to name when display_name absent', () {
      final m = Metadata.fromJson({'name': 'bob'});
      expect(m.bestName, 'bob');
      expect(m.displayName, isNull);
    });

    test('initial is ? when no name', () {
      final m = Metadata.fromJson({});
      expect(m.bestName, isNull);
      expect(m.initial, '?');
    });

    test('non-string fields are ignored (forward-compat)', () {
      final m = Metadata.fromJson({'name': 42, 'picture': true});
      expect(m.name, isNull);
      expect(m.picture, isNull);
    });

    test('extra unknown fields are ignored', () {
      final m = Metadata.fromJson({
        'name': 'x',
        'lud16': 'user@wallet.example', // lightning, not parsed in v1
        'deleted': false,
      });
      expect(m.name, 'x');
      expect(m.nip05, isNull);
    });
  });
}
