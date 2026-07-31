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
import '../../nostr/relay_pool.dart';
import '../../services/blossom_upload.dart' show measureBlossomRtt;

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
  // Live relay connection status from the pool's status stream.
  final Map<String, RelayStatus> _relayStatus = {};
  final Map<String, RelayStatus> _searchStatus = {};
  // Blossom reachability from the last HTTP probe: true=online, false=offline,
  // absent=not yet probed.
  final Map<String, bool> _blossomOnline = {};
  // Re-entrancy guard keys ("relay|url" / "blossom|url").
  final Set<String> _measuring = {};
  // Server lists sourced from serverListsProvider (local SQLite, seeded from
  // the code constants). Populated in _loadCacheThenMeasure.
  List<String> _relays = const <String>[];
  List<String> _blossom = const <String>[];
  Timer? _timer;
  StreamSubscription<List<RelayState>>? _statusSub;
  StreamSubscription<List<RelayState>>? _searchStatusSub;

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
  }

  Future<void> _loadCacheThenMeasure() async {
    final cache = await ref.read(localCacheProvider.future);
    final lists = await ref.read(serverListsProvider.future);
    if (!mounted) return;
    _relays = lists.relays;
    _blossom = lists.blossom;
    for (final url in _relays) {
      _relayCache[url] = await cache.readRtt(url, prefix: 'relay_rtt');
    }
    for (final url in _blossom) {
      _blossomCache[url] = await cache.readRtt(url, prefix: 'blossom_rtt');
    }
    for (final url in searchRelays) {
      _searchCache[url] = await cache.readRtt(url, prefix: 'relay_rtt');
    }
    if (!mounted) return;
    setState(() {});
    await _measureAll();
  }

  Future<void> _measureAll() async {
    final pool = ref.read(relayPoolProvider);
    final searchPool = ref.read(searchPoolProvider);
    // Relay targets: only connected relays.
    final relayTargets = _relays
        .where((u) => _relayStatus[u] == RelayStatus.connected)
        .map((u) => 'relay|$u')
        .where((k) => _measuring.add(k))
        .map((k) => k.substring('relay|'.length))
        .toList();
    final searchTargets = searchRelays
        .where((u) => _searchStatus[u] == RelayStatus.connected)
        .map((u) => 'search|$u')
        .where((k) => _measuring.add(k))
        .map((k) => k.substring('search|'.length))
        .toList();
    final blossomTargets = _blossom
        .map((u) => 'blossom|$u')
        .where((k) => _measuring.add(k))
        .map((k) => k.substring('blossom|'.length))
        .toList();
    if (relayTargets.isEmpty &&
        searchTargets.isEmpty &&
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
              '时延为真实往返（中继: WebSocket REQ→EOSE；图床: HTTP HEAD），'
              '保留最近 $_kKeep 次、按平均值显示；停留时每 '
              '${_kRefreshInterval.inSeconds}s 自动刷新。'
              '绿色=低时延，黄色=高时延，红色=离线。',
              style: theme.textTheme.bodySmall,
            ),
          ),
          _SectionHeader('中继服务器'),
          for (final url in _relays)
            _ServerRow(
              url: url,
              online: _relayStatus[url] == RelayStatus.connected,
              connecting: _relayStatus[url] == RelayStatus.connecting,
              samples: _relayCache[url] ?? const <int>[],
              measuring: _measuring.contains('relay|$url'),
            ),
          _SectionHeader('搜索中继（NIP-50）'),
          for (final url in searchRelays)
            _ServerRow(
              url: url,
              online: _searchStatus[url] == RelayStatus.connected,
              connecting: _searchStatus[url] == RelayStatus.connecting,
              samples: _searchCache[url] ?? const <int>[],
              measuring: _measuring.contains('search|$url'),
            ),
          _SectionHeader('Blossom 图床服务器'),
          for (final url in _blossom)
            _ServerRow(
              url: url,
              online: _blossomOnline[url] == true,
              connecting: !_blossomOnline.containsKey(url),
              samples: _blossomCache[url] ?? const <int>[],
              measuring: _measuring.contains('blossom|$url'),
            ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);
  final String title;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      color: theme.colorScheme.surfaceContainerHighest,
      child: Text(
        title,
        style: theme.textTheme.labelMedium?.copyWith(
          fontWeight: FontWeight.w600,
        ),
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
    final trailing = _trailing(theme);
    return ListTile(
      dense: true,
      visualDensity: const VisualDensity(horizontal: 0, vertical: -3),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      leading: Icon(Icons.circle, color: dotColor, size: 12),
      title: Text(url, style: theme.textTheme.bodyMedium),
      trailing: trailing,
    );
  }

  Widget _trailing(ThemeData theme) {
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
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.outline,
              ),
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
