/// Heuristic language detection for feed filtering.
///
/// Nostr events have no standard language field, so we infer from content:
/// any CJK character → Chinese; else any Latin letter → English; else null.
/// Deliberately coarse — good enough for a 全部/中文/英文 feed filter, not for
/// classification. Mixed CJK+Latin content counts as Chinese (so e.g. a post
/// that quotes English inside Chinese still shows under 中文).
library;

const String _langZh = 'zh';
const String _langEn = 'en';

final RegExp _cjk = RegExp(
  r'[一-鿿㐀-䶿豈-﫿⺀-⻿　-〿]',
);
final RegExp _latin = RegExp(r'[A-Za-z]');

/// 'zh' if the text contains any CJK character; 'en' if it has Latin letters
/// and no CJK; null otherwise (empty / numbers-only / other scripts).
String? detectLanguage(String text) {
  if (text.isEmpty) return null;
  if (_cjk.hasMatch(text)) return _langZh;
  if (_latin.hasMatch(text)) return _langEn;
  return null;
}
