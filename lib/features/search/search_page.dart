/// Global search page — NIP-50 search for posts (kind 1) and users (kind 0)
/// via the dedicated NIP-50 search pool. Entered from the bottom-nav 搜索 tab.
///
/// A clearly-visible filled search field (so the user can tell where to type)
/// with a 全部 / 帖子 / 用户 filter (default 全部), defaulting to showing both
/// sections stacked. The per-section filter narrows to one kind.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../models/event.dart';
import '../../widgets/avatar.dart';
import '../../widgets/immersive.dart';
import '../feed/event_card.dart';

enum _SearchTab { all, posts, users }

class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key});

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  final TextEditingController _controller = TextEditingController();
  String _query = '';
  _SearchTab _tab = _SearchTab.all;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    super.dispose();
  }

  /// Live text changes: (1) refresh the X clear-button visibility; (2) when
  /// the keyword is deleted to EMPTY, stop the in-flight search and clear the
  /// results — invalidating the old query's providers disposes their relay
  /// REQs/timers, so nothing keeps searching in the background (user
  /// request: 清空关键词即停止搜索并清空结果).
  void _onTextChanged() {
    if (!mounted) return;
    if (_controller.text.trim().isEmpty && _query.isNotEmpty) {
      final last = _query;
      _query = '';
      ref.invalidate(searchPostsProvider(last));
      ref.invalidate(searchUsersProvider(last));
    }
    setState(() {});
  }

  void _clearSearch() => _controller.clear(); // → _onTextChanged

  void _submit() => setState(() => _query = _controller.text.trim());

  @override
  Widget build(BuildContext context) {
    return ImmersiveScaffold(
      topBar: AppBar(
        titleSpacing: 0,
        title: Padding(
          padding: const EdgeInsets.only(right: 12),
          // Filled, rounded, leading-icon search field — clearly visible as
          // an input (the prior borderless AppBar TextField read as an empty
          // bar, so the user couldn't tell where to type the keywords).
          // Trailing X (Amethyst-style) one-tap clears the keyword — which
          // also stops the search + clears results via [_onTextChanged].
          child: TextField(
            controller: _controller,
            autofocus: true,
            textInputAction: TextInputAction.search,
            style: const TextStyle(fontSize: 15),
            decoration: InputDecoration(
              hintText: '搜索帖子或用户…',
              hintStyle: TextStyle(
                fontSize: 15,
                color: CostrColors.of(context).text3,
              ),
              prefixIcon: Icon(
                Icons.search,
                size: 20,
                color: CostrColors.of(context).text3,
              ),
              suffixIcon: _controller.text.isEmpty
                  ? null
                  : GestureDetector(
                      onTap: _clearSearch,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        child: Icon(
                          Icons.close,
                          size: 18,
                          color: CostrColors.of(context).text3,
                        ),
                      ),
                    ),
              filled: true,
              fillColor: CostrColors.of(context).bg2,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 0,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(24),
                borderSide: BorderSide.none,
              ),
              isDense: true,
            ),
            onSubmitted: (_) => _submit(),
          ),
        ),
      ),
      body: Column(
        children: <Widget>[
          // 全部 / 帖子 / 用户 filter (default 全部).
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: SegmentedButton<_SearchTab>(
              segments: const [
                ButtonSegment(value: _SearchTab.all, label: Text('全部')),
                ButtonSegment(value: _SearchTab.posts, label: Text('帖子')),
                ButtonSegment(value: _SearchTab.users, label: Text('用户')),
              ],
              selected: {_tab},
              onSelectionChanged: (s) => setState(() => _tab = s.first),
            ),
          ),
          Expanded(child: ImmersiveScrollDetector(child: _buildBody())),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_query.isEmpty) {
      return const Center(child: Text('输入关键词搜索帖子与用户'));
    }
    // 全部: users stacked above posts (as before). 帖子 / 用户: just the one.
    switch (_tab) {
      case _SearchTab.users:
        return ListView(
          children: [_UsersSection(query: _query, expanded: true)],
        );
      case _SearchTab.posts:
        return CustomScrollView(
          slivers: [_PostsSection(query: _query, showHeader: false)],
        );
      case _SearchTab.all:
        return CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: _UsersSection(query: _query, expanded: false),
            ),
            SliverPadding(
              padding: const EdgeInsets.only(top: 8),
              sliver: _PostsSection(query: _query, showHeader: true),
            ),
          ],
        );
    }
  }
}

class _UsersSection extends ConsumerWidget {
  const _UsersSection({required this.query, required this.expanded});
  final String query;
  final bool expanded;

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
        if (users.isEmpty) {
          // In users-only mode, show the empty hint; in 全部 mode, hide the
          // section so a missing users result doesn't leave a stray header.
          return expanded
              ? const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: Text('无用户结果')),
                )
              : const SizedBox.shrink();
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!expanded)
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
  const _PostsSection({required this.query, required this.showHeader});
  final String query;
  final bool showHeader;

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
        return SliverMainAxisGroup(
          slivers: <Widget>[
            if (showHeader)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: Text(
                    '帖子 (${posts.length})',
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                ),
              ),
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (BuildContext context, int i) => EventCard(event: posts[i]),
                childCount: posts.length,
              ),
            ),
          ],
        );
      },
    );
  }
}
