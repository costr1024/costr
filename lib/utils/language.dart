/// Heuristic language detection for feed filtering.
///
/// Nostr events have no standard language field, so we infer from content:
/// - Japanese if the text contains hiragana/katakana LETTERS (kana). Checked
///   BEFORE Han ideographs so kanji-only-with-kana Japanese posts classify as
///   'ja', not 'zh'. The kana ranges EXCLUDE the katakana middle dot `・`
///   (U+30FB) and prolonged mark `ー` (U+30FC): those are punctuation that
///   Chinese posts use for transliterated names (e.g. `玛丽・居里`), which
///   previously false-matched kana and leaked pure-Chinese posts into the
///   Japanese filter.
/// - Korean if it contains Hangul syllables. Checked before Han so a Korean
///   post that uses Hanja (Chinese characters used in Korean) classifies as
///   'ko' instead of leaking into the Chinese filter.
/// - Chinese if it contains Han ideographs and no kana/Hangul.
/// - English if it has Latin letters and no CJK/Hangul.
/// - null otherwise (empty / numbers-only / other scripts).
library;

const String _langZh = 'zh';
const String _langEn = 'en';
const String _langJa = 'ja';
const String _langKo = 'ko';

// Hiragana (U+3041–U+309F) + Katakana LETTERS (U+30A1–U+30FA). Excludes
// U+30A0 (゠) and U+30FB–U+30FF (・ーヽヾヿ punctuation) — see header.
final RegExp _kana = RegExp(r'[ぁ-ゟァ-ヺ]', unicode: true);
// Hangul syllables (U+AC00–U+D7AF). The distinguishing signal for Korean.
final RegExp _hangul = RegExp(r'[가-힯]', unicode: true);
// Han ideographs (CJK, shared by Chinese/Japanese kanji/Hanja).
final RegExp _cjk = RegExp(r'[一-鿿㐀-䶿豈-﫿⺀-⻿　-〿]', unicode: true);
final RegExp _latin = RegExp(r'[A-Za-z]');

/// 'ja' if kana present; else 'ko' if Hangul present; else 'zh' if Han
/// present; else 'en' if Latin present; else null.
String? detectLanguage(String text) {
  if (text.isEmpty) return null;
  if (_kana.hasMatch(text)) return _langJa;
  if (_hangul.hasMatch(text)) return _langKo;
  if (_cjk.hasMatch(text)) return _langZh;
  if (_latin.hasMatch(text)) return _langEn;
  return null;
}
