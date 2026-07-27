/// Feed page — global / following text-note timeline.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../nostr/relay_pool.dart';
import 'event_card.dart';

class FeedPage extends ConsumerWidget {
  const FeedPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(feedModeProvider);
    final events = ref.watch(currentFeedEventsProvider);
    final following = ref.watch(followingStateProvider);
    final relays = ref.watch(relayStatusProvider);

    final followingLoading =
        mode == FeedMode.following && following.isLoading;
    final followingEmpty = mode == FeedMode.following &&
        following.hasValue &&
        (following.value ?? const []).isEmpty;

    return Scaffold(
      appBar: AppBar(
        title: const Text('costr'),
        actions: [
          _RelayStatusChip(relays: relays.value ?? const []),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: SegmentedButton<FeedMode>(
              segments: const [
                ButtonSegment(
                  value: FeedMode.global,
                  label: Text('全球'),
                ),
                ButtonSegment(
                  value: FeedMode.following,
                  label: Text('关注'),
                ),
              ],
              selected: {mode},
              onSelectionChanged: (Set<FeedMode> s) {
                if (s.isNotEmpty) ref.read(feedModeProvider.notifier).set(s.first);
              },
            ),
          ),
          if (followingLoading) const LinearProgressIndicator(),
          Expanded(
            child: events.isEmpty
                ? _EmptyState(followingEmpty: followingEmpty)
                : ListView.builder(
                    itemCount: events.length,
                    itemBuilder: (BuildContext context, int i) =>
                        EventCard(event: events[i]),
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.edit),
        label: const Text('Compose'),
        onPressed: () => context.push('/compose'),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.followingEmpty});
  final bool followingEmpty;

  @override
  Widget build(BuildContext context) {
    final text = followingEmpty
        ? '你还没有关注任何人。\n关注其他用户后这里会显示他们的帖子。'
        : '暂无帖子。\n中继正在连接或尚无数据。';
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          text,
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

class _RelayStatusChip extends StatelessWidget {
  const _RelayStatusChip({required this.relays});
  final List<RelayState> relays;

  @override
  Widget build(BuildContext context) {
    if (relays.isEmpty) return const SizedBox.shrink();
    final connectedCount = relays
        .where((r) => r.status == RelayStatus.connected)
        .length;
    final allConnected = connectedCount == relays.length;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Chip(
        visualDensity: VisualDensity.compact,
        avatar: Icon(
          allConnected ? Icons.cloud_done : Icons.cloud_off,
          size: 18,
          color: allConnected ? Colors.green : Colors.amber,
        ),
        label: Text('$connectedCount/${relays.length}'),
      ),
    );
  }
}
