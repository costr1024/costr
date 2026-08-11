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
/// - Only the FIRST [_kScanCap] (100) NON-URL characters are judged: a
///   post's language is decided by its opening, and the window keeps
///   detection dirt-cheap even against adversariously long content (it runs
///   on the UI isolate). **URL spans (`http(s)://…`) are skipped and do NOT
///   count toward the window** — a Chinese post that is mostly download /
///   media links ("v1.0.1 正式版发布，下载地址：https://…") must not read as
///   English just because the links are Latin. At most [_kMaxSkippedUrls]
///   (10) links are skipped; on the next one the scan stops and the opening
///   characters gathered so far decide. Within the window the decision is
///   still by DOMINANT script, not "any character wins" — otherwise spam
///   could flip a post's class by seeding a couple of foreign letters into
///   the opening chars.
///
/// Result: 'ja' / 'ko' / 'zh' / 'en' / null. null means NO letters were
/// gathered — empty, pure-link, numbers-only, punctuation-only, or other
/// scripts (Cyrillic…). null is deliberately ambiguous and the FEED decides
/// what it means (see `currentFeedEventsProvider` + [hasAnyLetter] /
/// [containsUrl]): foreign-script text (letters present but none zh/en/ja)
/// matches no language filter, pure-link posts stay visible under every
/// option, and empty/symbol/number/emoji posts are dropped.
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

/// Judge from the first 100 NON-URL characters — a post's opening decides
/// its language; URLs are skipped (not language evidence) and the small
/// window bounds worst-case cost against 100KB+ spam content (detection
/// runs on the UI isolate).
const int _kScanCap = 100;

/// At most this many URL spans are skipped. On the NEXT URL the scan stops
/// entirely and the language is judged from the characters gathered so far —
/// a wall of links can't push the decision past the post's opening text,
/// and a pathological link-farm can't drag the scan deep into the content.
const int _kMaxSkippedUrls = 10;

/// Hard ceiling on how far the scan may WALK (belt-and-braces alongside
/// [_kMaxSkippedUrls]: URL spans are skipped without counting toward
/// [_kScanCap], so one giant URL could otherwise walk far into the content).
const int _kScanWalkLimit = 20000;

/// True when [s] at [i] begins a URL span (`https://` or `http://`).
bool _isUrlStart(String s, int i) =>
    s.startsWith('https://', i) || s.startsWith('http://', i);

/// Advance past the URL starting at [i] — to the next whitespace (or end).
int _skipUrl(String s, int i) {
  var j = i;
  while (j < s.length) {
    final u = s.codeUnitAt(j);
    if (u == 0x20 || u == 0x0A || u == 0x0D || u == 0x09) break;
    j++;
  }
  return j;
}

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
/// 'ja' (kana) > 'zh' (Han); null when no letters were gathered at all —
/// either the post is empty, or it is only URLs / numbers / emoji / other
/// scripts. null is ambiguous on purpose; the FEED resolves it (pure-link
/// posts stay visible, foreign-script / empty / symbol posts are dropped) —
/// see `currentFeedEventsProvider`, [hasAnyLetter], [containsUrl].
String? detectLanguage(String text) {
  if (text.isEmpty) return null;
  final c = _Counts();
  var counted = 0; // non-URL characters considered so far
  var urlsSkipped = 0;
  var i = 0;
  final n = text.length;
  while (i < n && counted < _kScanCap && i < _kScanWalkLimit) {
    // URL spans are not language evidence — skip them, up to a cap. Past
    // [_kMaxSkippedUrls] links the scan stops early and the language is
    // judged from the opening characters gathered so far (a wall of links
    // can't push the decision past the post's actual text).
    if (_isUrlStart(text, i)) {
      urlsSkipped++;
      if (urlsSkipped > _kMaxSkippedUrls) break;
      i = _skipUrl(text, i);
      continue;
    }
    final u = text.codeUnitAt(i);
    counted++;
    i++;
    // Surrogate halves (astral chars — emoji etc.) are not script evidence.
    if (u >= 0xD800 && u <= 0xDFFF) continue;
    if ((u >= 0x0041 && u <= 0x005A) || (u >= 0x0061 && u <= 0x007A)) {
      c.latin++;
    } else if ((u >= 0x4E00 && u <= 0x9FFF) || // CJK Unified Ideographs
        (u >= 0x3400 && u <= 0x4DBF) || // Extension A
        (u >= 0xF900 && u <= 0xFAFF)) {
      // Compatibility Ideographs
      c.han++;
    } else if ((u >= 0x3041 && u <= 0x309F) || // Hiragana
        (u >= 0x30A1 && u <= 0x30FA)) {
      // Katakana letters (no ・ー, see doc)
      c.kana++;
    } else if (u >= 0xAC00 && u <= 0xD7AF) {
      // Hangul syllables
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

/// Any Unicode letter, ANY script (Cyrillic, Arabic, Thai, Devanagari, …
/// included — `\p{L}`). Compiled once; [hasAnyLetter] is only reached for
/// posts [detectLanguage] already returned null for, so it is off the hot path.
final RegExp _anyLetterRegex = RegExp(r'\p{L}', unicode: true);

/// Same `https?://` span test [_isUrlStart] uses, as a whole-string scan.
final RegExp _urlRegexForSearch = RegExp(r'https?://');

/// True when [text] contains at least one Unicode letter of ANY script,
/// counting only characters OUTSIDE `http(s)://…` spans (same URL-skipping as
/// [detectLanguage], so the two always agree about what was evidence).
///
/// Feed filtering uses this to split the posts [detectLanguage] returned null
/// for into two very different groups:
/// - **foreign-script text** (Cyrillic «привет», Arabic, Thai, …): these ARE
///   language evidence — just not zh/en/ja — so the post belongs to none of
///   the filterable languages and must NOT leak into every filter the way the
///   old "null matches everything" rule did (the "不知道什么语言的帖子混进
///   中文流" bug).
/// - **no letters at all** (empty, `✄--- 2:25 ---✄`, numbers-only, emoji,
///   pure links — the URL itself is not evidence): nothing to attribute a
///   language to — handled separately by the feed (pure-link posts stay
///   visible, the rest are dropped).
/// Scan is capped like [detectLanguage] so adversarial content can't drag it
/// out.
bool hasAnyLetter(String text) {
  if (text.isEmpty) return false;
  final sb = StringBuffer();
  var i = 0;
  var urlsSkipped = 0;
  final n = text.length;
  while (i < n && sb.length < _kScanCap && i < _kScanWalkLimit) {
    if (_isUrlStart(text, i)) {
      urlsSkipped++;
      if (urlsSkipped > _kMaxSkippedUrls) break;
      i = _skipUrl(text, i);
      continue;
    }
    sb.writeCharCode(text.codeUnitAt(i));
    i++;
  }
  return _anyLetterRegex.hasMatch(sb.toString());
}

/// True when [text] contains an `http://` / `https://` URL anywhere. The feed
/// language filter uses it to keep pure-link posts (no letters at all) visible
/// under every language option (v1.0.2) while dropping other undetectable
/// posts — a bare-link post has no language to attribute, and hiding it would
/// silently eat e.g. a Chinese user's link-only share.
bool containsUrl(String text) {
  if (text.isEmpty) return false;
  final window = text.length > _kScanWalkLimit
      ? text.substring(0, _kScanWalkLimit)
      : text;
  return _urlRegexForSearch.hasMatch(window);
}
