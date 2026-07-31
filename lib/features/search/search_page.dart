/// Global search page — NIP-50 search for posts (kind 1) and users (kind 0)
/// via the dedicated NIP-50 search pool. Entered from the feed AppBar search icon.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../models/event.dart';
import '../../widgets/avatar.dart';
import '../feed/event_card.dart';

class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key});

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  final TextEditingController _controller = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => setState(() => _query = _controller.text.trim());

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          autofocus: true,
          textInputAction: TextInputAction.search,
          decoration: const InputDecoration(
            hintText: '搜索帖子或用户…',
            border: InputBorder.none,
          ),
          onSubmitted: (_) => _submit(),
        ),
      ),
      body: _query.isEmpty
          ? const Center(child: Text('输入关键词搜索帖子与用户'))
          : CustomScrollView(
              slivers: [
                SliverToBoxAdapter(child: _UsersSection(query: _query)),
                SliverPadding(
                  padding: const EdgeInsets.only(top: 8),
                  sliver: _PostsSection(query: _query),
                ),
              ],
            ),
    );
  }
}

class _UsersSection extends ConsumerWidget {
  const _UsersSection({required this.query});
  final String query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(searchUsersProvider(query));
    return async.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(16),
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      ),
      error: (Object e, _) =>
          Padding(padding: const EdgeInsets.all(16), child: Text('用户搜索失败：$e')),
      data: (List<UserResult> users) {
        if (users.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text(
                '用户 (${users.length})',
                style: Theme.of(context).textTheme.labelMedium,
              ),
            ),
            for (final u in users)
              ListTile(
                leading: Avatar(pubkey: u.pubkey, radius: 18),
                title: Text(
                  u.metadata?.bestName ?? u.pubkey.substring(0, 12),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: u.metadata?.about == null
                    ? null
                    : Text(
                        u.metadata!.about!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                onTap: () => context.push('/u/${u.pubkey}'),
              ),
          ],
        );
      },
    );
  }
}

class _PostsSection extends ConsumerWidget {
  const _PostsSection({required this.query});
  final String query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(searchPostsProvider(query));
    return async.when(
      loading: () => const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Center(
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ),
      ),
      error: (Object e, _) => SliverToBoxAdapter(child: Text('帖子搜索失败：$e')),
      data: (List<Event> posts) {
        if (posts.isEmpty) {
          return const SliverToBoxAdapter(
            child: Padding(padding: EdgeInsets.all(16), child: Text('无帖子结果')),
          );
        }
        return SliverList(
          delegate: SliverChildBuilderDelegate(
            (BuildContext context, int i) => EventCard(event: posts[i]),
            childCount: posts.length,
          ),
        );
      },
    );
  }
}
