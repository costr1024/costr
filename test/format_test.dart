import 'package:costr/utils/format.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('formatDuration', () {
    test('zero and sub-minute', () {
      expect(formatDuration(Duration.zero), '0:00');
      expect(formatDuration(const Duration(seconds: 9)), '0:09');
      expect(formatDuration(const Duration(seconds: 59)), '0:59');
    });

    test('minutes and hour boundary', () {
      expect(formatDuration(const Duration(seconds: 61)), '1:01');
      expect(formatDuration(const Duration(seconds: 59 * 60 + 59)), '59:59');
      expect(formatDuration(const Duration(seconds: 3600)), '1:00:00');
    });

    test('over an hour', () {
      expect(formatDuration(const Duration(seconds: 3723)), '1:02:03');
    });

    test('negative clamps to zero', () {
      expect(formatDuration(const Duration(seconds: -5)), '0:00');
    });
  });

  group('formatSpeed', () {
    test('common speeds', () {
      expect(formatSpeed(0.5), '0.5x');
      expect(formatSpeed(0.75), '0.75x');
      expect(formatSpeed(1.0), '1.0x');
      expect(formatSpeed(1.25), '1.25x');
      expect(formatSpeed(2.0), '2.0x');
    });
  });
}
