/// Heuristic language detection for feed filtering.
///
/// Nostr events have no standard language field, so we infer from content:
/// - Japanese if the text contains hiragana/katakana (kana). Checked BEFORE
///   Han ideographs so kanji-only-with-kana Japanese posts classify as 'ja',
///   not 'zh' (they were leaking into the Chinese filter before).
/// - Chinese if it contains Han ideographs and no kana.
/// - English if it has Latin letters and no CJK.
/// - null otherwise (empty / numbers-only / other scripts).
library;

const String _langZh = 'zh';
const String _langEn = 'en';
const String _langJa = 'ja';

// Hiragana + Katakana (Japanese kana). Kanji (Han) is shared with Chinese, so
// kana is the distinguishing signal for Japanese.
final RegExp _kana = RegExp(r'[぀-ゟ゠-ヿ]', unicode: true);
// Han ideographs (CJK, shared by Chinese/Japanese kanji).
final RegExp _cjk = RegExp(r'[一-鿿㐀-䶿豈-﫿⺀-⻿　-〿]', unicode: true);
final RegExp _latin = RegExp(r'[A-Za-z]');

/// 'ja' if kana present; else 'zh' if Han present; else 'en' if Latin present;
/// else null.
String? detectLanguage(String text) {
  if (text.isEmpty) return null;
  if (_kana.hasMatch(text)) return _langJa;
  if (_cjk.hasMatch(text)) return _langZh;
  if (_latin.hasMatch(text)) return _langEn;
  return null;
}
