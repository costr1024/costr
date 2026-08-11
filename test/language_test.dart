import 'dart:convert';

import 'package:costr/models/event.dart';
import 'package:costr/utils/language.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('detectLanguage', () {
    test('Chinese content (Han, no kana) → zh', () {
      expect(detectLanguage('今天天气真好'), 'zh');
      expect(detectLanguage('Hello 世界'), 'zh'); // Latin NOT dominant (≤3×) → zh
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
      // Kanji-heavy Japanese still carries grammar kana → stays ja.
      expect(detectLanguage('本日、国会議事堂にて総理大臣の所信表明演説が行われた'), 'ja');
    });

    test('Chinese that quotes kana → ja (kana wins)', () {
      // A Chinese post quoting a Japanese word with kana should classify as ja.
      expect(detectLanguage('他说 こんにちは 然后离开'), 'ja');
    });

    test('Korean → ko (also when Hanja/English is mixed in)', () {
      expect(detectLanguage('한국어입니다'), 'ko');
      expect(detectLanguage('오늘 Flutter 로 앱을 만들었다'), 'ko');
    });

    test(
      'Latin-dominated mix → en: giant English spam seeded with 2 Han chars',
      () {
        // The regression that froze the 中文 filter: 100KB+ English spam
        // posts each containing a couple of Han characters (「不受」) used to
        // classify as zh under "ANY Han char wins", flooding the Chinese
        // feed with non-Chinese mega-posts. Dominant-script counting sends
        // them to en.
        final spam =
            '${List.generate(3000, (i) => 'SPAM HEADLINE $i ').join()}'
            '不受 limited by search engines. '
            '${List.generate(3000, (i) => 'more spam text $i ').join()}';
        expect(detectLanguage(spam), 'en');
        // Same rule at smaller scale: an English post quoting one Chinese
        // word is still English.
        expect(detectLanguage('The word 你好 means hello in Chinese'), 'en');
      },
    );

    test('bilingual posts stay on the CJK side when CJK is substantial', () {
      // Chinese post sprinkled with English terms → zh.
      expect(detectLanguage('今天学了 Flutter 和 Dart，收获很大，明天继续加油！'), 'zh');
      // Japanese post with English terms → ja.
      expect(detectLanguage('今日は Flutter の pub get を使ってみた'), 'ja');
    });

    test('scan cap: CJK evidence beyond the cap never flips a Latin post', () {
      // Adversarial: pure Latin for the whole scanned window, two Han chars
      // appended after it — must not classify as zh (and the scan must stay
      // bounded instead of walking megabytes).
      final padded = 'a' * 20000 + '中文';
      expect(detectLanguage(padded), 'en');
      // Long pure Chinese still zh.
      expect(detectLanguage('中' * 20000), 'zh');
    });

    test('URLs are excluded from the opening window', () {
      // Real regression: a Chinese release announcement that is mostly
      // download/media links used to read as 'en' because the Latin URL
      // text dominated the first 100 chars. Links are not language evidence.
      expect(
        detectLanguage(
          '#Costr\nv1.0.1正式版发布，下载地址：\n'
          'https://github.com/costr1024/costr/releases/download/v1.0.1/app-release.apk\n\n'
          'https://blossom.ditto.pub/0be66e6b9fd61f241073d50918c69b0aa193a5731d348208b343fb42933aa3ec.jpeg',
        ),
        'zh',
      );
      // A wall of links first, then Chinese text — still zh.
      expect(
        detectLanguage(
          'https://example.com/a https://example.org/b/c 这是一个中文帖子',
        ),
        'zh',
      );
      // English post with links stays en.
      expect(
        detectLanguage('Check this out https://example.com/xyz great stuff'),
        'en',
      );
      // Pure links → no letters at all → null. The FEED then keeps pure-link
      // posts visible (v1.0.2) — see feed_language_filter_test.
      expect(detectLanguage('https://example.com/x'), isNull);
    });

    test('URL skipping caps at 10 links then judges the opening text', () {
      // Opening text first, then a link farm: the text decides → zh.
      final manyUrls = List.generate(
        15,
        (i) => 'https://example.com/$i',
      ).join(' ');
      expect(detectLanguage('中文内容 $manyUrls'), 'zh');
      // A wall of >10 links with NO text before them: the scan stops at the
      // 11th link, nothing was gathered → null, and any text AFTER the 11th
      // link is deliberately ignored. (Feed treats such pure-link posts as
      // visible under every filter.)
      expect(detectLanguage(manyUrls), isNull);
      expect(detectLanguage('$manyUrls 这是中文'), isNull);
      // Interleaved text + links (≤10 links) still reaches the text → zh.
      expect(
        detectLanguage(
          '中文 https://a.com/1 继续 https://a.com/2 结尾 https://a.com/3',
        ),
        'zh',
      );
    });

    test('empty / numbers-only / emoji / other scripts → null', () {
      expect(detectLanguage(''), isNull);
      expect(detectLanguage('12345'), isNull);
      expect(detectLanguage('🎉🎉'), isNull);
      expect(detectLanguage('привет'), isNull); // Cyrillic
      // CJK PUNCTUATION alone is not language evidence (used to match the
      // old Han range and leak punctuation-only posts into the zh filter).
      expect(detectLanguage('。、《》【'), isNull);
    });
  });

  group('hasAnyLetter / containsUrl (null-resolution helpers)', () {
    test('hasAnyLetter: any script counts, non-letters do not', () {
      expect(hasAnyLetter('hello'), isTrue);
      expect(hasAnyLetter('今天'), isTrue);
      expect(hasAnyLetter('привет'), isTrue); // Cyrillic
      expect(hasAnyLetter('مرحبا'), isTrue); // Arabic
      expect(hasAnyLetter('สวัสดี'), isTrue); // Thai
      expect(hasAnyLetter('12345'), isFalse);
      expect(hasAnyLetter('✄------------ 2:25 ------------✄'), isFalse);
      expect(hasAnyLetter('🎉🎉'), isFalse);
      expect(hasAnyLetter('。、《》【'), isFalse);
      expect(hasAnyLetter('https://example.com/123'), isFalse);
      expect(hasAnyLetter(''), isFalse);
    });

    test('containsUrl', () {
      expect(containsUrl('https://example.com'), isTrue);
      expect(containsUrl('see http://x.y/z ok'), isTrue);
      expect(containsUrl('no link here'), isFalse);
      expect(containsUrl(''), isFalse);
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

  group('Event.embeddedRepost (memoized NIP-18 parse)', () {
    Event repost(String content) => Event(
      id: 'rp',
      pubkey: 'pk',
      createdAt: 0,
      kind: 6,
      tags: const [
        ['e', 'target'],
      ],
      content: content,
      sig: '',
    );

    test('parses an embedded kind-1 note from the repost content', () {
      final inner = jsonEncode({
        'id': 'in1',
        'pubkey': 'pk2',
        'created_at': 1,
        'kind': 1,
        'tags': const [],
        'content': '内嵌的帖子',
        'sig': 's',
      });
      final rp = repost(inner);
      expect(rp.embeddedRepost, isNotNull);
      expect(rp.embeddedRepost!.content, '内嵌的帖子');
      expect(rp.embeddedRepost!.id, 'in1');
    });

    test('returns null for an empty-content (e-tag-only) repost', () {
      expect(repost('').embeddedRepost, isNull);
    });

    test('returns null when content is not embedded JSON', () {
      expect(repost('just some text, not JSON').embeddedRepost, isNull);
    });

    test('returns null when the embedded event is not post-like', () {
      final notPost = jsonEncode({
        'id': 'm1',
        'pubkey': 'pk2',
        'created_at': 1,
        'kind': 0, // metadata, not a post
        'tags': const [],
        'content': '{}',
        'sig': 's',
      });
      expect(repost(notPost).embeddedRepost, isNull);
    });

    test('a non-repost never has an embedded repost', () {
      final note = Event(
        id: 'n',
        pubkey: 'pk',
        createdAt: 0,
        kind: 1,
        tags: const [],
        content: '{"id":"x"}',
        sig: '',
      );
      expect(note.embeddedRepost, isNull);
    });

    test('repeated reads are stable (cached after first)', () {
      final inner = jsonEncode({
        'id': 'in2',
        'pubkey': 'pk2',
        'created_at': 1,
        'kind': 1,
        'tags': const [],
        'content': 'hi',
        'sig': 's',
      });
      final rp = repost(inner);
      final first = rp.embeddedRepost;
      expect(identical(rp.embeddedRepost, first), isTrue);
    });
  });
}
