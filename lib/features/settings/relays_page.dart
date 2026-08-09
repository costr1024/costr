/// Server nodes page (DESIGN.md §7 — 服务器节点). Two sections:
///
/// 1. **中继服务器** — the WebSocket relays Costr is connected to, with live
///    connection status and a real WS round-trip latency (REQ→EOSE with an
///    impossible filter, ≈ network RTT — NOT an ICMP ping).
/// 2. **Blossom 图床服务器** — the HTTP media-upload servers, tried in priority
///    order on upload, with a real HTTP round-trip latency (HEAD request).
///
/// RTT caching (both sections): the most recent [_kKeep] (3) samples per server
/// are persisted to SQLite under a per-section key prefix (`relay_rtt:` /
/// `blossom_rtt:`). On entering the page each online server is measured once;
/// while the page stays mounted, samples are re-measured every
/// [_kRefreshInterval] (5s), FIFO-evicting to keep only the last 3. The
/// displayed value is the average of the cached samples (or the average of
/// however many exist if fewer than 3).
///
/// Color: low latency → green number; high latency → yellow number; cannot
/// connect → red "离线".
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/server_list_rules.dart';
import '../../app/theme.dart';
import '../../nostr/relay_pool.dart';
import '../../services/blossom_upload.dart' show measureBlossomRtt;
import 'server_list_sheet.dart';

const int _kKeep = 3;
const Duration _kRefreshInterval = Duration(seconds: 5);
const int _kHighLatencyMs = 150; // green below, yellow at/above.

/// Average of [samples]; null if empty.
int? averageRtt(List<int> samples) {
  if (samples.isEmpty) return null;
  var sum = 0;
  for (final v in samples) {
    sum += v;
  }
  return (sum / samples.length).round();
}

class RelaysPage extends ConsumerStatefulWidget {
  const RelaysPage({super.key});

  @override
  ConsumerState<RelaysPage> createState() => _RelaysPageState();
}

class _RelaysPageState extends ConsumerState<RelaysPage> {
  // Per-server cached RTT samples (last 3), keyed by url, per section.
  final Map<String, List<int>> _relayCache = {};
  final Map<String, List<int>> _blossomCache = {};
  final Map<String, List<int>> _searchCache = {};
  final Map<String, List<int>> _indexerCache = {};
  // Live relay connection status from the pool's status stream.
  final Map<String, RelayStatus> _relayStatus = {};
  final Map<String, RelayStatus> _searchStatus = {};
  final Map<String, RelayStatus> _indexerStatus = {};
  // Blossom reachability from the last HTTP probe: true=online, false=offline,
  // absent=not yet probed.
  final Map<String, bool> _blossomOnline = {};
  // Re-entrancy guard keys ("relay|url" / "blossom|url").
  final Set<String> _measuring = {};
  // Server lists sourced from serverListsProvider (local SQLite, seeded from
  // the code constants, user-editable via the 「自定义」 sheets). Populated in
  // _loadCacheThenMeasure.
  List<String> _relays = const <String>[];
  List<String> _search = const <String>[];
  List<String> _indexer = const <String>[];
  List<String> _blossom = const <String>[];
  Timer? _timer;
  StreamSubscription<List<RelayState>>? _statusSub;
  StreamSubscription<List<RelayState>>? _searchStatusSub;
  StreamSubscription<List<RelayState>>? _indexerStatusSub;

  @override
  void initState() {
    super.initState();
    _initRelayStatus();
    unawaited(_loadCacheThenMeasure());
    _timer = Timer.periodic(_kRefreshInterval, (_) => unawaited(_measureAll()));
  }

  @override
  void dispose() {
    _timer?.cancel();
    _statusSub?.cancel();
    _searchStatusSub?.cancel();
    _indexerStatusSub?.cancel();
    super.dispose();
  }

  void _initRelayStatus() {
    final pool = ref.read(relayPoolProvider);
    for (final s in pool.states) {
      _relayStatus[s.url] = s.status;
    }
    _statusSub = pool.statusStream.listen((snapshot) {
      if (!mounted) return;
      for (final s in snapshot) {
        _relayStatus[s.url] = s.status;
      }
      setState(() {});
    });
    // Search pool (NIP-50) — separate, lazily connected. Surface its status
    // too so the node page lists search relays distinctly.
    final searchPool = ref.read(searchPoolProvider);
    for (final s in searchPool.states) {
      _searchStatus[s.url] = s.status;
    }
    _searchStatusSub = searchPool.statusStream.listen((snapshot) {
      if (!mounted) return;
      for (final s in snapshot) {
        _searchStatus[s.url] = s.status;
      }
      setState(() {});
    });
    // Indexer pool — aggregates all users' kind-0 metadata; lazily connected.
    final indexerPool = ref.read(indexerPoolProvider);
    for (final s in indexerPool.states) {
      _indexerStatus[s.url] = s.status;
    }
    _indexerStatusSub = indexerPool.statusStream.listen((snapshot) {
      if (!mounted) return;
      for (final s in snapshot) {
        _indexerStatus[s.url] = s.status;
      }
      setState(() {});
    });
  }

  Future<void> _loadCacheThenMeasure() async {
    final cache = await ref.read(localCacheProvider.future);
    final lists = await ref.read(serverListsProvider.future);
    if (!mounted) return;
    _relays = lists.relays;
    _search = lists.search;
    _indexer = lists.indexer;
    _blossom = lists.blossom;
    for (final url in _relays) {
      _relayCache[url] = await cache.readRtt(url, prefix: 'relay_rtt');
    }
    for (final url in _blossom) {
      _blossomCache[url] = await cache.readRtt(url, prefix: 'blossom_rtt');
    }
    for (final url in _search) {
      _searchCache[url] = await cache.readRtt(url, prefix: 'relay_rtt');
    }
    for (final url in _indexer) {
      _indexerCache[url] = await cache.readRtt(url, prefix: 'relay_rtt');
    }
    if (!mounted) return;
    setState(() {});
    await _measureAll();
  }

  Future<void> _measureAll() async {
    final pool = ref.read(relayPoolProvider);
    final searchPool = ref.read(searchPoolProvider);
    final indexerPool = ref.read(indexerPoolProvider);
    // Relay targets: only connected relays.
    final relayTargets = _relays
        .where((u) => _relayStatus[u] == RelayStatus.connected)
        .map((u) => 'relay|$u')
        .where((k) => _measuring.add(k))
        .map((k) => k.substring('relay|'.length))
        .toList();
    final searchTargets = _search
        .where((u) => _searchStatus[u] == RelayStatus.connected)
        .map((u) => 'search|$u')
        .where((k) => _measuring.add(k))
        .map((k) => k.substring('search|'.length))
        .toList();
    final indexerTargets = _indexer
        .where((u) => _indexerStatus[u] == RelayStatus.connected)
        .map((u) => 'indexer|$u')
        .where((k) => _measuring.add(k))
        .map((k) => k.substring('indexer|'.length))
        .toList();
    final blossomTargets = _blossom
        .map((u) => 'blossom|$u')
        .where((k) => _measuring.add(k))
        .map((k) => k.substring('blossom|'.length))
        .toList();
    if (relayTargets.isEmpty &&
        searchTargets.isEmpty &&
        indexerTargets.isEmpty &&
        blossomTargets.isEmpty) {
      return;
    }
    if (mounted) setState(() {});
    final cache = await ref.read(localCacheProvider.future);
    final futures = <Future<void>>[
      ...relayTargets.map((url) async {
        final ms = await pool.measureRttFor(url);
        if (ms != null && mounted) {
          await cache.pushRtt(url, ms, prefix: 'relay_rtt');
          _relayCache[url] = await cache.readRtt(url, prefix: 'relay_rtt');
        }
        _measuring.remove('relay|$url');
      }),
      ...searchTargets.map((url) async {
        final ms = await searchPool.measureRttFor(url);
        if (ms != null && mounted) {
          await cache.pushRtt(url, ms, prefix: 'relay_rtt');
          _searchCache[url] = await cache.readRtt(url, prefix: 'relay_rtt');
        }
        _measuring.remove('search|$url');
      }),
      ...indexerTargets.map((url) async {
        // Indexers aggregate kind-0, not kind-1 — probe with kind-0 (a
        // filter they actually serve) so the probe returns an EVENT and
        // completes fast, instead of relying on an empty kind-1 EOSE.
        final ms = await indexerPool.measureRttFor(url, kinds: const [0]);
        if (ms != null && mounted) {
          await cache.pushRtt(url, ms, prefix: 'relay_rtt');
          _indexerCache[url] = await cache.readRtt(url, prefix: 'relay_rtt');
        }
        _measuring.remove('indexer|$url');
      }),
      ...blossomTargets.map((url) async {
        final ms = await measureBlossomRtt(url);
        _blossomOnline[url] = ms != null;
        if (ms != null && mounted) {
          await cache.pushRtt(url, ms, prefix: 'blossom_rtt');
          _blossomCache[url] = await cache.readRtt(url, prefix: 'blossom_rtt');
        }
        _measuring.remove('blossom|$url');
      }),
    ];
    await Future.wait(futures);
    if (mounted) setState(() {});
  }

  Future<void> _refreshNow() async {
    await _measureAll();
  }

  /// Open the customize sheet for [category]; when the user saves a new list,
  /// reload the lists + re-measure so the page reflects the change at once.
  Future<void> _openCustomize(ServerCategory category) async {
    final saved = await showServerListSheet(
      context: context,
      ref: ref,
      category: category,
    );
    if (saved == true && mounted) {
      await _loadCacheThenMeasure();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('服务器节点'),
        actions: [
          IconButton(
            tooltip: '重新测速',
            icon: const Icon(Icons.refresh),
            onPressed: _refreshNow,
          ),
        ],
      ),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              '下面每台服务器显示它对本机的响应速度（数字越小越快，单位毫秒）。'
              '保留最近 $_kKeep 次取平均，停留此页时每 '
              '${_kRefreshInterval.inSeconds} 秒自动重测一次。'
              '绿色=快，黄色=较慢，红色=连不上。',
              style: theme.textTheme.bodySmall,
            ),
          ),
          _SectionHeader(
            '中继服务器',
            onCustomize: () => _openCustomize(ServerCategory.relay),
          ),
          for (final url in _relays)
            _ServerRow(
              url: url,
              online: _relayStatus[url] == RelayStatus.connected,
              connecting: _relayStatus[url] == RelayStatus.connecting,
              samples: _relayCache[url] ?? const <int>[],
              measuring: _measuring.contains('relay|$url'),
            ),
          _SectionHeader(
            '搜索中继（NIP-50）',
            onCustomize: () => _openCustomize(ServerCategory.search),
          ),
          for (final url in _search)
            _ServerRow(
              url: url,
              online: _searchStatus[url] == RelayStatus.connected,
              connecting: _searchStatus[url] == RelayStatus.connecting,
              samples: _searchCache[url] ?? const <int>[],
              measuring: _measuring.contains('search|$url'),
            ),
          _SectionHeader(
            '索引中继',
            onCustomize: () => _openCustomize(ServerCategory.indexer),
          ),
          for (final url in _indexer)
            _ServerRow(
              url: url,
              online: _indexerStatus[url] == RelayStatus.connected,
              connecting: _indexerStatus[url] == RelayStatus.connecting,
              samples: _indexerCache[url] ?? const <int>[],
              measuring: _measuring.contains('indexer|$url'),
            ),
          _SectionHeader(
            'Blossom 图床服务器',
            onCustomize: () => _openCustomize(ServerCategory.blossom),
          ),
          for (final url in _blossom)
            _ServerRow(
              url: url,
              online: _blossomOnline[url] == true,
              connecting: !_blossomOnline.containsKey(url),
              samples: _blossomCache[url] ?? const <int>[],
              measuring: _measuring.contains('blossom|$url'),
            ),
          const SizedBox(height: 12),
          // Plain-language explainer for each server type. Nostr's
          // many relay "roles" are confusing — spell out what each does so
          // users know why there are four sections.
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('这些服务器都是干嘛的？', style: theme.textTheme.titleSmall),
                const SizedBox(height: 8),
                _ExplainerRow(
                  title: '中继服务器',
                  body:
                      '你每天刷的帖子来自这里。'
                      'Costr 连着这些中继，实时收发大家发的文字、转发和点赞。',
                ),
                _ExplainerRow(
                  title: '搜索中继',
                  body:
                      '专门支持全文搜索的中继。'
                      '你在搜索页搜关键词时，只问这几台，能精准找到含关键词的帖子。',
                ),
                _ExplainerRow(
                  title: '索引中继',
                  body:
                      '收录了"几乎所有人"的个人资料（昵称、头像、简介）。'
                      '当你看到一个陌生账号、本地没有他的资料时，Costr 就来这里取，'
                      '好让头像和昵称能显示出来，而不是显示一串乱码。',
                ),
                _ExplainerRow(
                  title: 'Blossom 图床',
                  body:
                      '你发帖时上传的图片和视频存在这里。'
                      '上传时按顺序逐个试，谁先成功用谁。',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ExplainerRow extends StatelessWidget {
  const _ExplainerRow({required this.title, required this.body});
  final String title;
  final String body;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: RichText(
        text: TextSpan(
          style: theme.textTheme.bodySmall,
          children: [
            TextSpan(
              text: '$title：',
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            TextSpan(text: body),
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title, {this.onCustomize});
  final String title;

  /// Opens the customize sheet for this category (「自定义」 entry on the
  /// right of the title row).
  final VoidCallback? onCustomize;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 4, 8, 0),
      color: theme.colorScheme.surfaceContainerHighest,
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: theme.textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (onCustomize != null)
            TextButton(
              onPressed: onCustomize,
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                minimumSize: const Size(0, 32),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('自定义'),
            ),
        ],
      ),
    );
  }
}

class _ServerRow extends StatelessWidget {
  const _ServerRow({
    required this.url,
    required this.online,
    required this.connecting,
    required this.samples,
    required this.measuring,
  });

  final String url;
  final bool online; // reachable / connected
  final bool connecting; // connecting / not-yet-probed (ambiguous → spinner)
  final List<int> samples;
  final bool measuring;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dotColor = online
        ? Colors.green
        : (connecting ? Colors.amber : Colors.red);
    final trailing = _trailing(theme, CostrColors.of(context).text3);
    return ListTile(
      dense: true,
      visualDensity: const VisualDensity(horizontal: 0, vertical: -3),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      leading: Icon(Icons.circle, color: dotColor, size: 12),
      title: Text(url, style: theme.textTheme.bodyMedium),
      trailing: trailing,
    );
  }

  Widget _trailing(ThemeData theme, Color muted) {
    // Offline → red "离线".
    if (!online && !connecting) {
      return Text(
        '离线',
        style: theme.textTheme.bodyMedium?.copyWith(
          fontWeight: FontWeight.w600,
          color: Colors.red,
        ),
      );
    }
    final avg = averageRtt(samples);
    // Online but no sample yet (or still probing) → spinner / "…".
    if (avg == null) {
      return measuring || connecting
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Text(
              '…',
              style: theme.textTheme.bodyMedium?.copyWith(color: muted),
            );
    }
    // Has a number → green (low) or yellow (high).
    final color = avg < _kHighLatencyMs ? Colors.green : Colors.amber.shade700;
    return Text(
      '${avg}ms',
      style: theme.textTheme.bodyMedium?.copyWith(
        fontWeight: FontWeight.w600,
        color: color,
      ),
    );
  }
}
