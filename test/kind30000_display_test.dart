// Unit tests for kind-30000 follow-set display-name resolution.
//
// Amethyst stores a UUID in the `d` tag and the human-readable name in a
// `name` tag; Costr's own lists use the human name directly as `d` (no `name`
// tag). listDisplayName must prefer `name` and fall back to `d`, and
// return null for the default list (d="") so it is excluded from the named
// groups list.
import 'package:costr/app/providers.dart';
import 'package:costr/models/event.dart';
import 'package:flutter_test/flutter_test.dart';

Event _k30000(List<List<dynamic>> tags) => Event(
  id: 'id',
  pubkey: 'pk',
  createdAt: 0,
  kind: 30000,
  tags: tags,
  content: '',
  sig: 's',
);

void main() {
  group('listDisplayName', () {
    test('Amethyst list: prefers name tag over UUID d', () {
      final e = _k30000([
        ['d', 'f40fa7f0-8441-4eae-8b55-f605699da40b'],
        ['name', '真人用户'],
      ]);
      expect(listDisplayName(e), '真人用户');
    });

    test('Costr list: falls back to d when no name tag', () {
      final e = _k30000([
        ['d', 'friends'],
      ]);
      expect(listDisplayName(e), 'friends');
    });

    test('empty name tag falls back to d', () {
      final e = _k30000([
        ['d', 'friends'],
        ['name', ''],
      ]);
      expect(listDisplayName(e), 'friends');
    });

    test('default list (d="") is null — excluded from named groups', () {
      final e = _k30000([
        ['d', ''],
      ]);
      expect(listDisplayName(e), isNull);
    });

    test('list with neither d nor name is null', () {
      final e = _k30000([
        ['p', 'some-pk', ''],
      ]);
      expect(listDisplayName(e), isNull);
    });
  });
}
