import 'package:costr/features/settings/relays_page.dart' show averageRtt;
import 'package:costr/services/local_cache.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LocalCache RTT cache', () {
    late LocalCache db;

    setUp(() {
      db = LocalCache(NativeDatabase.memory());
    });

    tearDown(() async {
      await db.close();
    });

    test('readRtt returns empty when no samples', () async {
      expect(await db.readRtt('wss://a'), isEmpty);
    });

    test('pushRtt stores and reads back samples FIFO', () async {
      await db.pushRtt('wss://a', 100);
      await db.pushRtt('wss://a', 120);
      expect(await db.readRtt('wss://a'), [100, 120]);
    });

    test('pushRtt keeps only the most recent 3 (FIFO eviction)', () async {
      for (final v in [100, 110, 120, 130, 140]) {
        await db.pushRtt('wss://a', v);
      }
      // First two (100, 110) evicted; last 3 kept.
      expect(await db.readRtt('wss://a'), [120, 130, 140]);
    });

    test('samples are isolated per relay', () async {
      await db.pushRtt('wss://a', 100);
      await db.pushRtt('wss://b', 200);
      expect(await db.readRtt('wss://a'), [100]);
      expect(await db.readRtt('wss://b'), [200]);
    });

    test('corrupt stored value is treated as empty', () async {
      await db.writeConfig('relay_rtt:wss://a', 'not-json');
      expect(await db.readRtt('wss://a'), isEmpty);
    });

    test('relay and blossom prefixes are isolated', () async {
      await db.pushRtt('wss://a', 100, prefix: 'relay_rtt');
      await db.pushRtt('wss://a', 200, prefix: 'blossom_rtt');
      expect(await db.readRtt('wss://a', prefix: 'relay_rtt'), [100]);
      expect(await db.readRtt('wss://a', prefix: 'blossom_rtt'), [200]);
    });
  });

  group('LocalCache write success-rate samples', () {
    late LocalCache db;

    setUp(() {
      db = LocalCache(NativeDatabase.memory());
    });

    tearDown(() async {
      await db.close();
    });

    test('readWriteSamples returns empty when no samples', () async {
      expect(await db.readWriteSamples('wss://a'), isEmpty);
    });

    test('pushWriteSample stores and reads back verdicts FIFO', () async {
      await db.pushWriteSample('wss://a', true);
      await db.pushWriteSample('wss://a', false);
      await db.pushWriteSample('wss://a', true);
      expect(await db.readWriteSamples('wss://a'), [true, false, true]);
    });

    test(
      'pushWriteSample keeps only the most recent 10 (FIFO eviction)',
      () async {
        // 7 accepts then 5 rejects: the first 2 accepts get evicted.
        for (var i = 0; i < 7; i++) {
          await db.pushWriteSample('wss://a', true);
        }
        for (var i = 0; i < 5; i++) {
          await db.pushWriteSample('wss://a', false);
        }
        final samples = await db.readWriteSamples('wss://a');
        expect(samples.length, 10);
        expect(samples.where((s) => s).length, 5);
        expect(samples.last, isFalse);
      },
    );

    test('samples are isolated per relay', () async {
      await db.pushWriteSample('wss://a', true);
      await db.pushWriteSample('wss://b', false);
      expect(await db.readWriteSamples('wss://a'), [true]);
      expect(await db.readWriteSamples('wss://b'), [false]);
    });

    test('corrupt stored value is treated as empty', () async {
      await db.writeConfig('relay_write_stats:wss://a', 'not-json');
      expect(await db.readWriteSamples('wss://a'), isEmpty);
    });
  });

  group('averageRtt', () {
    test('null when empty', () {
      expect(averageRtt(const <int>[]), isNull);
    });

    test('single value', () {
      expect(averageRtt(const [120]), 120);
    });

    test('fewer than 3 averages the actual samples', () {
      expect(averageRtt(const [100, 200]), 150);
    });

    test('3 samples average with rounding', () {
      expect(averageRtt(const [100, 150, 200]), 150);
      expect(averageRtt(const [100, 101, 102]), 101);
    });
  });
}
