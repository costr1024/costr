/// Profile page — shows a user's NIP-01 kind-0 profile (avatar, name, about,
/// website, banner) + npub + (hex pubkey for the logged-in user) + logout.
///
/// Parameterized by [pubkey]; when null, defaults to the logged-in identity.
/// Designed so a future "view author" feature can pass any pubkey.
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
          return _ProfileBody(pubkey: pk, isSelf: isSelf, identity: identity);
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
    final meta = ref.watch(metadataProvider(pubkey));
    final theme = Theme.of(context);
    final m = meta.value;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (m?.banner != null && m!.banner!.isNotEmpty)
            AspectRatio(
              aspectRatio: 3 / 1,
              child: Image.network(
                m.banner!,
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
                Row(
 crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Transform.translate(
                      offset: const Offset(0, -24),
                      child: Avatar(pubkey: pubkey, radius: 40),
                    ),                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        m?.bestName ?? '(未设置名字)',
                        style: theme.textTheme.titleLarge,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                if (m?.about != null && m!.about!.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(m.about!, style: theme.textTheme.bodyMedium),
                ],
                if (m?.website != null && m!.website!.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(m.website!, style: theme.textTheme.bodySmall),
                ],
                const SizedBox(height: 16),
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
                  const SizedBox(height: 24),
                  FilledButton.tonalIcon(
                    icon: const Icon(Icons.logout),
                    label: const Text('登出'),
                    onPressed: () async {
                      await ref.read(identityProvider.notifier).logout();
                      if (context.mounted) context.go('/login');
                    },
                  ),
                ],
              ],
            ),
          ),
          const Divider(height: 1),
          _PostsSection(pubkey: pubkey),
        ],
      ),
    );
  }
}

/// The user's public posts + replies (newest-first). Replies show the parent
/// post quoted above, indented (hierarchy via a left rule).
class _PostsSection extends ConsumerWidget {
  const _PostsSection({required this.pubkey});
  final String pubkey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(userPostsProvider(pubkey));
    return async.when(
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (Object e, _) => Padding(
        padding: const EdgeInsets.all(24),
        child: Center(child: Text('帖子加载失败：$e')),
      ),
      data: (List<Event> posts) {
        if (posts.isEmpty) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: Text('暂无公开帖子')),
          );
        }
        return ListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: posts.length,
          itemBuilder: (BuildContext context, int i) =>
              UserPostItem(event: posts[i]),
        );
      },
    );
  }
}
