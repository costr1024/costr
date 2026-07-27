/// Profile page — header (banner/avatar/metadata) + 帖子/回帖/关注 tabs.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../models/event.dart';
import '../../nostr/identity.dart';
import '../../widgets/avatar.dart';
import 'user_post_item.dart';

class ProfilePage extends ConsumerWidget {
  const ProfilePage({super.key, this.pubkey});

  /// If null, the logged-in identity's pubkey is used.
  final String? pubkey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final idAsync = ref.watch(identityProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('我的')),
      body: idAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (Object e, _) => Center(child: Text('加载失败：$e')),
        data: (identity) {
          final pk = pubkey ?? identity?.pubkeyHex;
          final isSelf = pubkey == null || pubkey == identity?.pubkeyHex;
          if (pk == null) return const Center(child: Text('未登录'));
          return DefaultTabController(
            length: 3,
            child: _ProfileBody(pubkey: pk, isSelf: isSelf, identity: identity),
          );
        },
      ),
    );
  }
}

class _ProfileBody extends ConsumerWidget {
  const _ProfileBody({required this.pubkey, required this.isSelf, this.identity});
  final String pubkey;
  final bool isSelf;
  final Identity? identity;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final meta = ref.watch(metadataProvider(pubkey)).value;
    final theme = Theme.of(context);

    return Column(
      children: [
        // --- Header (banner + metadata, natural height) ---
        Material(
          color: theme.colorScheme.surface,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (meta?.banner != null && meta!.banner!.isNotEmpty)
                AspectRatio(
                  aspectRatio: 3 / 1,
                  child: Image.network(
                    meta.banner!,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  ),
                )
              else
                Container(height: 8, color: theme.colorScheme.surfaceContainerHighest),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Transform.translate(
                      offset: const Offset(0, -24),
                      child: Avatar(pubkey: pubkey, radius: 40),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      meta?.bestName ?? '(未设置名字)',
                      style: theme.textTheme.titleLarge,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (meta?.about != null && meta!.about!.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(meta.about!, style: theme.textTheme.bodyMedium),
                    ],
                    if (meta?.website != null && meta!.website!.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(meta.website!, style: theme.textTheme.bodySmall),
                    ],
                    const SizedBox(height: 12),
                    Text('npub', style: theme.textTheme.labelSmall),
                    SelectableText(
                      identity?.npub ?? '',
                      style: theme.textTheme.bodyMedium,
                    ),
                    if (isSelf) ...[
                      const SizedBox(height: 12),
                      Text('pubkey (hex)', style: theme.textTheme.labelSmall),
                      SelectableText(
                        identity?.pubkeyHex ?? pubkey,
                        style: theme.textTheme.bodySmall,
                      ),
                      const SizedBox(height: 16),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: FilledButton.tonalIcon(
                          icon: const Icon(Icons.logout),
                          label: const Text('登出'),
                          onPressed: () async {
                            await ref.read(identityProvider.notifier).logout();
                            if (context.mounted) context.go('/login');
                          },
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const Divider(height: 1),
            ],
          ),
        ),
        // --- Tabs ---
        Material(
          color: theme.colorScheme.surface,
          child: TabBar(
            tabAlignment: TabAlignment.start,
            isScrollable: true,
            tabs: const [
              Tab(text: '帖子'),
              Tab(text: '回帖'),
              Tab(text: '关注'),
            ],
          ),
        ),
        // --- Tab content ---
        Expanded(
          child: TabBarView(
            children: [
              _PostsTab(pubkey: pubkey),
              _RepliesTab(pubkey: pubkey),
              _FollowsTab(pubkey: pubkey),
            ],
          ),
        ),
      ],
    );
  }
}

class _PostsTab extends ConsumerWidget {
  const _PostsTab({required this.pubkey});
  final String pubkey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(userPostsProvider(pubkey));
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (Object e, _) => Center(child: Text('加载失败：$e')),
      data: (List<Event> all) {
        final posts = all.where((e) => !e.isReply).toList();
        if (posts.isEmpty) return const Center(child: Text('暂无帖子'));
        return ListView.builder(
          itemCount: posts.length,
          itemBuilder: (BuildContext context, int i) =>
              UserPostItem(event: posts[i]),
        );
      },
    );
  }
}

class _RepliesTab extends ConsumerWidget {
  const _RepliesTab({required this.pubkey});
  final String pubkey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(userPostsProvider(pubkey));
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (Object e, _) => Center(child: Text('加载失败：$e')),
      data: (List<Event> all) {
        final replies = all.where((e) => e.isReply).toList();
        if (replies.isEmpty) return const Center(child: Text('暂无回帖'));
        return ListView.builder(
          itemCount: replies.length,
          itemBuilder: (BuildContext context, int i) =>
              UserPostItem(event: replies[i]),
        );
      },
    );
  }
}

class _FollowsTab extends ConsumerWidget {
  const _FollowsTab({required this.pubkey});
  final String pubkey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(userFollowsProvider(pubkey));
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (Object e, _) => Center(child: Text('加载失败：$e')),
      data: (List<String> follows) {
        if (follows.isEmpty) return const Center(child: Text('暂无关注'));
        return ListView.builder(
          itemCount: follows.length,
          itemBuilder: (BuildContext context, int i) => _FollowRow(
            pubkey: follows[i],
            onTap: () => context.push('/u/${follows[i]}'),
          ),
        );
      },
    );
  }
}

class _FollowRow extends ConsumerWidget {
  const _FollowRow({required this.pubkey, required this.onTap});
  final String pubkey;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final meta = ref.watch(metadataProvider(pubkey)).value;
    final theme = Theme.of(context);
    return ListTile(
      leading: Avatar(pubkey: pubkey, radius: 18),
      title: Text(
        displayLabelFor(pubkey, meta),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: onTap,
      trailing: meta?.bestName == null
          ? Text(
              pubkey.length > 10 ? '${pubkey.substring(0, 8)}…' : pubkey,
              style: theme.textTheme.labelSmall,
            )
          : null,
    );
  }
}
