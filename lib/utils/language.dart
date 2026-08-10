/// Heuristic language detection for feed filtering.
///
/// Nostr events have no standard language field, so the DOMINANT SCRIPT of
/// the letter characters is inferred by counting, in ONE pass:
///
/// - Latin-dominated text is 'en' even when it sprinkles a few CJK
///   characters: Latin letters outnumbering CJK letters more than
///   [_kLatinDominance]×1 win. This blocks the spam attack that motivated
///   the rewrite — 100KB+ English spam posts seeding two Han characters
///   (「不受」) used to classify as 'zh' under the old "ANY Han char → zh"
///   rule, flooding the Chinese filter with giant non-Chinese posts (which
///   also froze the feed, since every visible card then parsed 100KB+ of
///   markdown). The ratio rule sends them back to 'en', diluted among real
///   English posts.
/// - Among CJK text: Hangul present → 'ko' (checked before Han so a Korean
///   post using Hanja doesn't leak into Chinese); else kana present → 'ja'
///   (checked before Han so kanji-heavy Japanese classifies 'ja', not 'zh' —
///   Japanese grammar requires kana, so real Chinese posts never contain
///   them); else Han → 'zh'. The kana ranges EXCLUDE the katakana middle dot
///   `・` (U+30FB) and prolonged mark `ー` (U+30FC): punctuation that
///   Chinese posts use for transliterated names (e.g. `玛丽・居里`), which
///   used to false-match kana and leak pure-Chinese posts into Japanese.
/// - Only the FIRST [_kScanCap] (100) characters are judged: a post's
///   language is decided by its opening, and the window keeps detection
///   dirt-cheap even against adversariously long content (it runs on the UI
///   isolate). Within the window the decision is still by DOMINANT script,
///   not "any character wins" — otherwise spam could flip a post's class by
///   seeding a couple of foreign letters into the opening 100 chars.
///
/// Result: 'ja' / 'ko' / 'zh' / 'en' / null (no letters at all — empty,
/// numbers-only, punctuation-only, other scripts like Cyrillic).
library;

const String _langZh = 'zh';
const String _langEn = 'en';
const String _langJa = 'ja';
const String _langKo = 'ko';

/// Latin letters must outnumber ALL CJK letters by this factor for a mixed
/// post to count as English. 3× keeps genuinely bilingual posts (a Chinese
/// post quoting an English term, an English post quoting a Chinese phrase)
/// on their CJK side while rejecting Latin spam seeded with CJK crumbs.
const int _kLatinDominance = 3;

/// Judge the language from the first 100 characters only — a post's opening
/// decides its language, and the small window bounds worst-case cost against
/// 100KB+ spam content (detection runs on the UI isolate).
const int _kScanCap = 100;

/// Counted script buckets; only LETTERS are evidence (digits, punctuation,
/// emoji and CJK punctuation like 。、 are ignored on purpose — they prove
/// nothing about the writing language).
class _Counts {
  int latin = 0;
  int han = 0;
  int kana = 0;
  int hangul = 0;
}

/// 'en' if Latin-only or Latin-dominated; else among CJK 'ko' (Hangul) >
/// 'ja' (kana) > 'zh' (Han); null when the text has no letters at all.
String? detectLanguage(String text) {
  if (text.isEmpty) return null;
  final c = _Counts();
  final n = text.length < _kScanCap ? text.length : _kScanCap;
  for (var i = 0; i < n; i++) {
    final u = text.codeUnitAt(i);
    // Surrogate halves (astral chars — emoji etc.) are not script evidence.
    if (u >= 0xD800 && u <= 0xDFFF) continue;
    if ((u >= 0x0041 && u <= 0x005A) || (u >= 0x0061 && u <= 0x007A)) {
      c.latin++;
    } else if ((u >= 0x4E00 && u <= 0x9FFF) || // CJK Unified Ideographs
        (u >= 0x3400 && u <= 0x4DBF) || // Extension A
        (u >= 0xF900 && u <= 0xFAFF)) { // Compatibility Ideographs
      c.han++;
    } else if ((u >= 0x3041 && u <= 0x309F) || // Hiragana
        (u >= 0x30A1 && u <= 0x30FA)) { // Katakana letters (no ・ー, see doc)
      c.kana++;
    } else if (u >= 0xAC00 && u <= 0xD7AF) { // Hangul syllables
      c.hangul++;
    }
  }
  final cjk = c.han + c.kana + c.hangul;
  if (cjk == 0) return c.latin > 0 ? _langEn : null;
  if (c.latin > cjk * _kLatinDominance) return _langEn;
  if (c.hangul > 0) return _langKo;
  if (c.kana > 0) return _langJa;
  return _langZh;
}
