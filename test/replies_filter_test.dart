import 'package:costr/app/providers.dart';
import 'package:costr/models/event.dart';
import 'package:flutter_test/flutter_test.dart';

const _a64 =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _e64 =
    'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee';
const _s128 =
    'ssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssss';

Event _mk(
  String id, {
  required int kind,
  List<List<dynamic>> tags = const [],
  String content = '',
  String pubkey = _a64,
}) =>
    Event(
      id: id,
      pubkey: pubkey,
      createdAt: 1,
      kind: kind,
      tags: tags,
      content: content,
      sig: _s128,
    );

void main() {
  const target = _e64; // the post being replied to

  group('isReplyToEvent', () {
    test('kind-1 with matching #e tag is a reply', () {
      final e = _mk(
        '1111111111111111111111111111111111111111111111111111111111111111',
        kind: 1,
        tags: [
          ['e', target, '', 'reply'],
        ],
        content: 'hi',
      );
      expect(isReplyToEvent(e, target), isTrue);
    });

    test('kind-7 reaction with matching #e tag is NOT a reply', () {
      // Regression: reactions carry an e-tag pointing at the post they
      // react to. The global rawEvents stream delivers them; without the
      // isTextNote guard they'd be collected as replies and shown as posts.
      final e = _mk(
        '2222222222222222222222222222222222222222222222222222222222222222',
        kind: 7,
        tags: [
          ['e', target],
        ],
        content: '👍',
      );
      expect(isReplyToEvent(e, target), isFalse);
    });

    test('kind-3 contact list is NOT a reply', () {
      final e = _mk(
        '3333333333333333333333333333333333333333333333333333333333333333',
        kind: 3,
        tags: [
          ['p', _a64],
        ],
        content: '{}',
      );
      expect(isReplyToEvent(e, target), isFalse);
    });

    test('kind-1 without a matching #e tag is NOT a reply', () {
      final e = _mk(
        '4444444444444444444444444444444444444444444444444444444444444444',
        kind: 1,
        tags: [
          ['e', 'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff', '', 'reply'],
        ],
        content: 'unrelated',
      );
      expect(isReplyToEvent(e, target), isFalse);
    });

    test('kind-1 referencing a different event via #e is NOT a reply', () {
      final e = _mk(
        '5555555555555555555555555555555555555555555555555555555555555555',
        kind: 1,
        tags: [
          ['p', _a64],
          ['e', 'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd'],
        ],
        content: 'reply to someone else',
      );
      expect(isReplyToEvent(e, target), isFalse);
    });
  });
}
