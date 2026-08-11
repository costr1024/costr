import 'package:costr/app/providers.dart';
import 'package:costr/models/event.dart';
import 'package:flutter_test/flutter_test.dart';

Event _k10002(
  String id,
  String pubkey,
  List<List<dynamic>> tags, {
  int createdAt = 100,
}) => Event(
  id: id,
  pubkey: pubkey,
  createdAt: createdAt,
  kind: 10002,
  tags: tags,
  content: '',
  sig:
      'ssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssss',
);

void main() {
  const pk = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

  test('parse null for non-10002 event', () {
    final e = Event(
      id: 'x',
      pubkey: pk,
      createdAt: 1,
      kind: 1,
      tags: const [],
      content: '',
      sig:
          'ssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssss',
    );
    expect(RelayList.parse(e), isNull);
  });

  test('no marker → relay is both read + write', () {
    final e = _k10002('1', pk, [
      ['r', 'wss://a'],
      ['r', 'wss://b'],
    ]);
    final list = RelayList.parse(e)!;
    expect(list.read, ['wss://a', 'wss://b']);
    expect(list.write, ['wss://a', 'wss://b']);
  });

  test('read / write markers split correctly', () {
    final e = _k10002('2', pk, [
      ['r', 'wss://read', 'read'],
      ['r', 'wss://write', 'write'],
    ]);
    final list = RelayList.parse(e)!;
    expect(list.read, ['wss://read']);
    expect(list.write, ['wss://write']);
  });

  test('mixed: bare, read, write combine + dedup', () {
    final e = _k10002('3', pk, [
      ['r', 'wss://both'], // both
      ['r', 'wss://ro', 'read'],
      ['r', 'wss://both'], // dup → deduped
      ['r', 'wss://wo', 'write'],
    ]);
    final list = RelayList.parse(e)!;
    // read = both + ro (deduped)
    expect(list.read, ['wss://both', 'wss://ro']);
    expect(list.write, ['wss://both', 'wss://wo']);
  });

  test('ignores malformed r tags', () {
    final e = _k10002('4', pk, [
      ['r'], // no url
      ['r', ''], // empty url
      ['r', 123], // non-string url
      ['x', 'wss://nope'],
      ['r', 'wss://ok'],
    ]);
    final list = RelayList.parse(e)!;
    expect(list.read, ['wss://ok']);
    expect(list.write, ['wss://ok']);
  });

  test('empty relay list → empty read + write', () {
    final e = _k10002('5', pk, []);
    final list = RelayList.parse(e)!;
    expect(list.read, isEmpty);
    expect(list.write, isEmpty);
  });
}
