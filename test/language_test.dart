import 'package:costr/utils/language.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('detectLanguage', () {
    test('Chinese content → zh', () {
      expect(detectLanguage('今天天气真好'), 'zh');
      expect(detectLanguage('Hello 世界'), 'zh'); // mixed → zh
      expect(detectLanguage('繁體中文測試'), 'zh');
    });

    test('English content → en', () {
      expect(detectLanguage('Hello world'), 'en');
      expect(detectLanguage('GNUS/USD pair looking strong 2day'), 'en');
    });

    test('empty / numbers-only / other scripts → null', () {
      expect(detectLanguage(''), isNull);
      expect(detectLanguage('12345'), isNull);
      expect(detectLanguage('🎉🎉'), isNull);
      expect(detectLanguage('привет'), isNull); // Cyrillic, not en/zh
    });

    test('Japanese kana (no kanji) → null (not CJK han)', () {
      // Hiragana/syllabic — not in the han ranges; we don't mislabel as zh.
      expect(detectLanguage('こんにちは'), isNull);
    });
  });
}
