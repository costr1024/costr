import 'package:costr/models/event.dart';
import 'package:costr/utils/language.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('detectLanguage', () {
    test('Chinese content (Han, no kana) → zh', () {
      expect(detectLanguage('今天天气真好'), 'zh');
      expect(detectLanguage('Hello 世界'), 'zh'); // mixed Latin+Han, no kana → zh
      expect(detectLanguage('繁體中文測試'), 'zh');
    });

    test('English content → en', () {
      expect(detectLanguage('Hello world'), 'en');
      expect(detectLanguage('GNUS/USD pair looking strong 2day'), 'en');
    });

    test('Japanese with kana → ja (not zh, even if it has kanji)', () {
      expect(detectLanguage('こんにちは'), 'ja'); // hiragana only
      expect(detectLanguage('カタカナ'), 'ja'); // katakana only
      expect(detectLanguage('日本語のテストです'), 'ja'); // kanji + kana
    });

    test('Chinese that quotes kana → ja (kana wins)', () {
      // A Chinese post quoting a Japanese word with kana should classify as ja.
      expect(detectLanguage('他说 こんにちは 然后离开'), 'ja');
    });

    test('empty / numbers-only / emoji / other scripts → null', () {
      expect(detectLanguage(''), isNull);
      expect(detectLanguage('12345'), isNull);
      expect(detectLanguage('🎉🎉'), isNull);
      expect(detectLanguage('привет'), isNull); // Cyrillic
    });
  });

  group('Event.language (memoized)', () {
    Event note(String content) => Event(
      id: 'id-${content.hashCode}',
      pubkey: 'pk',
      createdAt: 0,
      kind: 1,
      tags: const [],
      content: content,
      sig: '',
    );

    test('matches detectLanguage across all outcomes', () {
      expect(note('今天天气真好').language, 'zh');
      expect(note('Hello world').language, 'en');
      expect(note('日本語のテストです').language, 'ja');
      expect(note('한국어입니다').language, 'ko');
      expect(note('12345').language, isNull);
    });

    test('repeated reads are stable (cached after first)', () {
      final e = note('こんにちは');
      final first = e.language;
      // Read again — must come from the memo, same value.
      expect(e.language, first);
      expect(e.language, 'ja');
    });
  });
}
