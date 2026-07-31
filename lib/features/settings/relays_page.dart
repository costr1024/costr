/// Server nodes page (DESIGN.md §7 — 服务器节点). Lists the relays Costr is
/// connected to, each with a live connection status and a real WebSocket
/// round-trip latency (REQ→EOSE with an impossible filter, ≈ network RTT —
/// NOT an ICMP ping).
///
/// RTT caching: the most recent [_kKeep] (3) samples per relay are persisted to
/// SQLite (ConfigTable key `relay_rtt:<url>`). On entering the page each
/// connected relay is measured once; while the page stays mounted, samples are
/// re-measured every [_kRefreshInterval] (5s), FIFO-evicting to keep only the
/// last 3. The displayed value is the average of the cached samples (or the
/// average of however many exist if fewer than 3).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../nostr/relay_pool.dart';

const int _kKeep = 3;
const Duration _kRefreshInterval = Duration(seconds: 5);

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
  final Map<String, List<int>> _cache = {};
  final Map<String, RelayStatus> _status = {};
  final Set<String> _measuring = {};
  Timer? _timer;
  StreamSubscription<List<RelayState>>? _statusSub;

  @override
  void initState() {
    super.initState();
    _initStatus();
    unawaited(_loadCacheThenMeasure());
    _timer = Timer.periodic(_kRefreshInterval, (_) => unawaited(_measureAll()));
  }

  @override
  void dispose() {
    _timer?.cancel();
    _statusSub?.cancel();
    super.dispose();
  }

  void _initStatus() {
    final pool = ref.read(relayPoolProvider);
    for (final s in pool.states) {
      _status[s.url] = s.status;
    }
    _statusSub = pool.statusStream.listen((snapshot) {
      if (!mounted) return;
      for (final s in snapshot) {
        _status[s.url] = s.status;
      }
      setState(() {});
    });
  }

  Future<void> _loadCacheThenMeasure() async {
    final cache = await ref.read(localCacheProvider.future);
    if (!mounted) return;
    for (final url in defaultRelays) {
      _cache[url] = await cache.readRtt(url);
    }
    if (!mounted) return;
    setState(() {});
    await _measureAll();
  }

  Future<void> _measureAll() async {
    final pool = ref.read(relayPoolProvider);
    final targets = defaultRelays.where(
      (url) => _status[url] == RelayStatus.connected,
    );
    // Skip re-entrant runs: mark all targets measuring, only run those not
    // already in flight.
    final pending = targets.where((u) => _measuring.add(u)).toList();
    if (pending.isEmpty) return;
    setState(() {});
    final cache = await ref.read(localCacheProvider.future);
    await Future.wait(
      pending.map((url) async {
        final ms = await pool.measureRttFor(url);
        if (ms != null && mounted) {
          await cache.pushRtt(url, ms);
          _cache[url] = await cache.readRtt(url);
        }
        _measuring.remove(url);
      }),
    );
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
              '时延为真实 WebSocket 往返（REQ→EOSE），保留最近 $_kKeep 次，按平均值显示；停留时每 ${_kRefreshInterval.inSeconds}s 自动刷新。',
              style: theme.textTheme.bodySmall,
            ),
          ),
          for (final url in defaultRelays)
            _RelayRow(
              url: url,
              status: _status[url] ?? RelayStatus.disconnected,
              samples: _cache[url] ?? const <int>[],
              measuring: _measuring.contains(url),
            ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _RelayRow extends StatelessWidget {
  const _RelayRow({
    required this.url,
    required this.status,
    required this.samples,
    required this.measuring,
  });

  final String url;
  final RelayStatus status;
  final List<int> samples;
  final bool measuring;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final connected = status == RelayStatus.connected;
    final avg = averageRtt(samples);
    final color = connected
        ? Colors.green
        : (status == RelayStatus.connecting ? Colors.amber : Colors.grey);
    final trailing = measuring
        ? const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : Text(
            avg == null ? '—' : '${avg}ms',
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
              color: _rttColor(avg, theme),
            ),
          );
    return ListTile(
      leading: Icon(Icons.circle, color: color, size: 12),
      title: Text(url, style: theme.textTheme.bodyMedium),
      subtitle: Text(_statusLabel(status), style: theme.textTheme.bodySmall),
      trailing: trailing,
    );
  }

  String _statusLabel(RelayStatus s) {
    switch (s) {
      case RelayStatus.connected:
        return '已连接';
      case RelayStatus.connecting:
        return '连接中';
      case RelayStatus.disconnected:
        return '已断开';
      case RelayStatus.error:
        return '错误';
    }
  }

  Color _rttColor(int? avg, ThemeData theme) {
    if (avg == null) return theme.colorScheme.outline;
    if (avg < 150) return Colors.green;
    if (avg < 400) return Colors.amber.shade700;
    return Colors.red;
  }
}
