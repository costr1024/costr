/// Feed page — global / following text-note timeline with pull-to-refresh
/// and load-more on scroll.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../nostr/relay_pool.dart';
import 'event_card.dart';

class FeedPage extends ConsumerStatefulWidget {
  const FeedPage({super.key});

  @override
  ConsumerState<FeedPage> createState() => _FeedPageState();
}

class _FeedPageState extends ConsumerState<FeedPage> {
  bool _loadingMore = false;
  static const int _loadMoreThreshold = 300; // px from bottom

  Future<void> _refresh() async {
    // Re-issue the feed subscription (closes the old sub, opens a new one).
    ref.invalidate(feedSubscriptionProvider);
    // Show the spinner briefly while relays respond.
    await Future<void>.delayed(const Duration(milliseconds: 1200));
  }

  Future<void> _loadMore() async {
    if (_loadingMore) return;
    final events = ref.read(currentFeedEventsProvider);
    if (events.isEmpty) return;
    final mode = ref.read(feedModeProvider);
    final follows =
        ref.read(followingStateProvider).value ?? const <String>[];
    if (mode == FeedMode.following && follows.isEmpty) return;
    final oldest =
        events.map((e) => e.createdAt).reduce((a, b) => a < b ? a : b);
    final filter = buildFeedFilter(mode, follows);
    filter['until'] = oldest - 1;
    setState(() => _loadingMore = true);
    final pool = ref.read(relayPoolProvider);
    final subId = nextSubId('more');
    pool.request(subId, filter, closeOnEose: true);
    await Future<void>.delayed(const Duration(seconds: 2));
    if (mounted) setState(() => _loadingMore = false);
  }

  @override
  Widget build(BuildContext context) {
    final mode = ref.watch(feedModeProvider);
    final events = ref.watch(currentFeedEventsProvider);
    final following = ref.watch(followingStateProvider);
    final relays = ref.watch(relayStatusProvider);
    final lang = ref.watch(languageFilterProvider);
    final tagFilter = ref.watch(tagFilterProvider);

    final followingLoading = mode == FeedMode.following && following.isLoading;
    final followingEmpty = mode == FeedMode.following &&
        following.hasValue &&
        (following.value ?? const []).isEmpty;

    return Scaffold(
      appBar: AppBar(
        title: const Text('costr'),
        actions: [
          _LanguageDropdown(value: lang),
          _RelayStatusChip(relays: relays.value ?? const []),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: SegmentedButton<FeedMode>(
              segments: const [
                ButtonSegment(value: FeedMode.global, label: Text('全球')),
                ButtonSegment(value: FeedMode.following, label: Text('关注')),
              ],
              selected: {mode},
              onSelectionChanged: (Set<FeedMode> s) {
                if (s.isNotEmpty) ref.read(feedModeProvider.notifier).set(s.first);
              },
            ),
          ),
          if (tagFilter != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: InputChip(
                  label: Text('#$tagFilter'),
                  visualDensity: VisualDensity.compact,
                  onDeleted: () => ref.read(tagFilterProvider.notifier).clear(),
                ),
              ),
            ),
          if (followingLoading || _loadingMore)
            const LinearProgressIndicator(),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _refresh,
              child: events.isEmpty
                  ? ListView(
                      children: [_EmptyState(followingEmpty: followingEmpty)],
                    )
                  : NotificationListener<ScrollNotification>(
                      onNotification: (ScrollNotification n) {
                        if (n is ScrollEndNotification &&
                            n.metrics.pixels >=
                                n.metrics.maxScrollExtent - _loadMoreThreshold) {
                          _loadMore();
                        }
                        return false;
                      },
                      child: ListView.builder(
                        itemCount: events.length,
                        itemBuilder: (BuildContext context, int i) =>
                            EventCard(event: events[i]),
                      ),
                    ),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.edit),
        label: const Text('发帖'),
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
        : '暂无帖子。\n下拉刷新或等待中继数据。';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 80, horizontal: 24),
      child: Center(
        child: Text(text, textAlign: TextAlign.center),
      ),
    );
  }
}

class _LanguageDropdown extends ConsumerWidget {
  const _LanguageDropdown({required this.value});
  final LanguageFilter value;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: DropdownButton<LanguageFilter>(
        value: value,
        underline: const SizedBox.shrink(),
        icon: const Icon(Icons.language, size: 20),
        items: const [
          DropdownMenuItem(value: LanguageFilter.all, child: Text('全部')),
          DropdownMenuItem(value: LanguageFilter.zh, child: Text('中文')),
          DropdownMenuItem(value: LanguageFilter.en, child: Text('英文')),
        ],
        onChanged: (LanguageFilter? f) {
          if (f != null) ref.read(languageFilterProvider.notifier).set(f);
        },
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
    final connectedCount =
        relays.where((r) => r.status == RelayStatus.connected).length;
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
