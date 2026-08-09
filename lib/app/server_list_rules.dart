/// Rules for the user-editable server lists (服务器节点 page, DESIGN.md §13):
/// the four categories, their persistence keys, per-category size limits, URL
/// normalization and validation. Pure functions, no Riverpod — kept in a
/// leaf file so `providers.dart`, the settings UI and the tests can all share
/// ONE implementation (normalization MUST stay identical between the save
/// path and the kind-10002 sync-marker comparison, or accounts would re-
/// publish on every switch just because of a trailing-slash difference).
library;

/// The four kinds of servers Costr connects to. Display copy and persistence
/// are per-category; only [relay] changes are published to Nostr (kind 10002).
enum ServerCategory { relay, search, indexer, blossom }

/// Config-table keys (device-level, shared by ALL accounts on this device).
/// `relay_list` / `blossom_list` predate the edit UI; the other two were
/// seeded constants before.
const Map<ServerCategory, String> serverListKeys = {
  ServerCategory.relay: 'relay_list',
  ServerCategory.search: 'search_relay_list',
  ServerCategory.indexer: 'indexer_relay_list',
  ServerCategory.blossom: 'blossom_list',
};

/// Hard cap per category (product decision: keep lists small and sane).
const int maxServersPerCategory = 10;

/// Per-category minimum — the lists must never be emptied below this.
/// Relays need 3 so one dead relay can't blind the app; the other categories
/// degrade a single feature each, so 1 is enough.
int minServersFor(ServerCategory category) {
  switch (category) {
    case ServerCategory.relay:
      return 3;
    case ServerCategory.search:
    case ServerCategory.indexer:
    case ServerCategory.blossom:
      return 1;
  }
}

/// Plain-language name used in page headers and the customize sheet.
String categoryDisplayName(ServerCategory category) {
  switch (category) {
    case ServerCategory.relay:
      return '中继服务器';
    case ServerCategory.search:
      return '搜索中继';
    case ServerCategory.indexer:
      return '索引中继';
    case ServerCategory.blossom:
      return 'Blossom 图床';
  }
}

/// Canonical form of a server URL: trimmed, lower-cased, no trailing slash.
/// Lower-casing the whole URL is deliberate: relay/blossom URLs are
/// scheme+host(+root) in practice, and hosts are case-insensitive, so this
/// dedupes `wss://Foo.example/` vs `wss://foo.example` — the exact mismatch
/// that would otherwise cause needless kind-10002 re-publishes.
String normalizeServerUrl(String raw) {
  var u = raw.trim().toLowerCase();
  // Never strip into the scheme separator: 'wss://' alone must stay 'wss://'
  // (so the scheme check below can reject it with the right message).
  final schemeEnd = u.indexOf('://');
  final keep = schemeEnd >= 0 ? schemeEnd + 3 : 0;
  while (u.length > keep && u.endsWith('/')) {
    u = u.substring(0, u.length - 1);
  }
  return u;
}

/// Normalize + dedup a list, preserving first-seen order (order matters:
/// blossom list order = upload retry priority).
List<String> normalizeServerList(List<String> urls) {
  final seen = <String>{};
  final out = <String>[];
  for (final raw in urls) {
    final u = normalizeServerUrl(raw);
    if (u.isEmpty) continue;
    if (seen.add(u)) out.add(u);
  }
  return out;
}

/// Order-insensitive equality of two server lists, compared on normalized
/// URLs (so a trailing slash or case difference isn't a "change").
bool sameServerSet(List<String> a, List<String> b) {
  final sa = a.map(normalizeServerUrl).where((u) => u.isNotEmpty).toSet();
  final sb = b.map(normalizeServerUrl).where((u) => u.isNotEmpty).toSet();
  return sa.length == sb.length && sa.containsAll(sb);
}

/// Validate a URL the user wants to ADD to [category]'s list, given the
/// list's current [existing] entries. Returns a plain-language Chinese error
/// message, or null when the URL is acceptable. Centralizes every rule the
/// add-field can trip so the sheet and any future entry point stay in sync.
String? serverUrlError(
  ServerCategory category,
  String raw, {
  required List<String> existing,
}) {
  if (raw.trim().isEmpty) return '请先输入服务器地址';
  if (existing.length >= maxServersPerCategory) {
    return '最多只能添加 $maxServersPerCategory 台服务器';
  }
  final u = normalizeServerUrl(raw);
  final needsWs = category != ServerCategory.blossom;
  if (needsWs
      ? !(u.startsWith('wss://') || u.startsWith('ws://'))
      : !u.startsWith('https://')) {
    return needsWs
        ? '这看起来不是中继服务器地址，地址应以 wss:// 开头'
        : '这看起来不是图床地址，地址应以 https:// 开头';
  }
  final parsed = Uri.tryParse(u);
  if (parsed == null || parsed.host.isEmpty) {
    return '这看起来不是一个有效的服务器地址';
  }
  if (existing.map(normalizeServerUrl).contains(u)) {
    return '这台服务器已经在列表里了';
  }
  return null;
}

// --- Relay write success rate ----------------------------------------------
// Only WRITE verdicts are measured: publishing is the fragile direction (a
// relay that accepts writes can almost always be read from), so the 服务器
// 节点 page warns about relays whose writes keep failing and suggests
// replacing them. Samples live in the SQLite config table
// (`relay_write_stats:<url>`, FIFO — see LocalCache.pushWriteSample).

/// Minimum recorded publishes before a success-rate verdict is meaningful
/// (fewer than this → no warning, avoids nagging after one bad attempt).
const int minWriteSamples = 3;

/// Whether a relay's recent write record is bad enough to suggest replacing
/// it: at least [minWriteSamples] recorded verdicts AND fewer than half
/// accepted. Null = not enough data yet.
bool? lowWriteSuccessRate(List<bool> samples) {
  if (samples.length < minWriteSamples) return null;
  final ok = samples.where((s) => s).length;
  return ok * 2 < samples.length; // success rate strictly below 50%
}

/// Plain-language warning shown under a relay row on the 服务器节点 page, or
/// null when the relay has too little data or its success rate is fine. The
/// counts are included so the suggestion is grounded ("近期发送 5 次仅成功 1
/// 次"), not a mysterious red flag.
String? writeRateWarning(List<bool> samples) {
  if (lowWriteSuccessRate(samples) != true) return null;
  final ok = samples.where((s) => s).length;
  return '近期发送 ${samples.length} 次仅成功 $ok 次，建议更换';
}
