import 'package:costr/app/providers.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('buildFeedFilter', () {
    test('global mode: kinds=[1], limit=200, no authors', () {
      final f = buildFeedFilter(FeedMode.global, const ['x']);
      expect(f['kinds'], [0, 1, 6, 7]);
      expect(f['limit'], 200);
      expect(f.containsKey('authors'), isFalse);
    });

    test('following mode with follows: includes authors', () {
      final f = buildFeedFilter(FeedMode.following, const ['a', 'b']);
      expect(f['kinds'], [0, 1, 6, 7]);
      expect(f['limit'], 200);
      expect(f['authors'], ['a', 'b']);
    });

    test('following mode with empty follows: no authors key', () {
      final f = buildFeedFilter(FeedMode.following, const []);
      expect(f.containsKey('authors'), isFalse);
    });

    test('authors list is a fresh copy (caller cannot mutate internal)', () {
      final src = ['a'];
      final f = buildFeedFilter(FeedMode.following, src);
      (f['authors'] as List).add('b');
      expect(src, ['a']);
    });
  });
}
