import 'dart:io';

import 'package:costr/services/secure_storage_service.dart';
import 'package:flutter_test/flutter_test.dart';

Future<String> _mode(String path) async {
  final r = await Process.run('stat', ['-c', '%a', path]);
  return (r.stdout as String).trim();
}

void main() {
  late String dir;
  setUp(() async {
    dir =
        '${Directory.systemTemp.path}/costr_test_${DateTime.now().microsecondsSinceEpoch}';
  });
  tearDown(() async {
    final d = Directory(dir);
    if (await d.exists()) await d.delete(recursive: true);
  });

  group('FileSecretStore', () {
    test('write then read round-trips', () async {
      final s = FileSecretStore(dir);
      await s.write('k1', 'v1');
      expect(await s.read('k1'), 'v1');
    });

    test('persists across instances (restart)', () async {
      await FileSecretStore(dir).write('nsec', 'nsec1abc');
      expect(await FileSecretStore(dir).read('nsec'), 'nsec1abc');
    });

    test('delete removes the value', () async {
      final s = FileSecretStore(dir);
      await s.write('k1', 'v1');
      await s.delete('k1');
      expect(await s.read('k1'), isNull);
    });

    test('delete on empty store is a no-op', () async {
      final s = FileSecretStore(dir);
      await s.delete('nope'); // should not throw
      expect(await s.read('nope'), isNull);
    });

    test('file is 0600 and dir is 0700', () async {
      final s = FileSecretStore(dir);
      await s.write('k1', 'v1');
      expect(await _mode('$dir/secret.json'), '600');
      expect(await _mode(dir), '700');
    });

    test('corrupt file degrades to empty (no crash)', () async {
      await Directory(dir).create(recursive: true);
      await File('$dir/secret.json').writeAsString('not json{');
      final s = FileSecretStore(dir);
      expect(await s.read('k1'), isNull);
      // writing after corruption works (overwrites)
      await s.write('k1', 'v1');
      expect(await s.read('k1'), 'v1');
    });
  });
}
