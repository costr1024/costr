/// Profile page — header (banner/avatar/metadata) + 帖子/回帖/关注/关注者 tabs.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:markdown/markdown.dart' hide Text;
import 'package:url_launcher/url_launcher.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../feed/event_card.dart';
import '../../models/bookmark_entry.dart';
import '../../models/event.dart';
import '../../models/metadata.dart';
import '../../nostr/identity.dart';
import '../../nostr/actions.dart';
import '../../utils/nip19.dart';
import '../../widgets/avatar.dart';
import 'user_post_item.dart';

class ProfilePage extends ConsumerWidget {
  const ProfilePage({super.key, this.pubkey});

  /// If null, the logged-in identity's pubkey is used.
  final String? pubkey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final idAsync = ref.watch(identityProvider);
    final isOwn = pubkey == null;
    return Scaffold(
      appBar: isOwn
          ? AppBar(
              title: const Text('我的'),
              leading: IconButton(
                icon: const Icon(Icons.info_outline),
                onPressed: () => context.push('/about'),
              ),
              actions: [
                IconButton(
                  icon: const Icon(Icons.settings),
                  onPressed: () => context.push('/settings'),
                ),
              ],
            )
          : AppBar(
              title: const Text('用户'),
              leading: IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => context.pop(),
              ),
            ),
      body: idAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (Object e, _) => Center(child: Text('加载失败：$e')),
        data: (identity) {
          final pk = pubkey ?? identity?.pubkeyHex;
          final isSelf = pubkey == null || pubkey == identity?.pubkeyHex;
          if (pk == null) return const Center(child: Text('未登录'));
          return DefaultTabController(
            length: 5,
            child: _ProfileBody(pubkey: pk, isSelf: isSelf, identity: identity),
          );
        },
      ),
    );
  }
}

class _ProfileBody extends ConsumerWidget {
  const _ProfileBody({
    required this.pubkey,
    required this.isSelf,
    this.identity,
  });
  final String pubkey;
  final bool isSelf;
  final Identity? identity;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final meta = ref.watch(metadataProvider(pubkey)).value;
    final theme = Theme.of(context);

    return NestedScrollView(
      headerSliverBuilder: (BuildContext context, bool innerBoxIsScrolled) {
        return <Widget>[
          SliverToBoxAdapter(
            child: _Header(
              pubkey: pubkey,
              identity: identity,
              meta: meta,
              isSelf: isSelf,
            ),
          ),
          SliverPersistentHeader(
            pinned: true,
            delegate: _StickyTabBarDelegate(
              TabBar(
                tabAlignment: TabAlignment.start,
                isScrollable: true,
                tabs: const [
                  Tab(text: '帖子'),
                  Tab(text: '回帖'),
                  Tab(text: '关注'),
                  Tab(text: '关注者'),
                  Tab(text: '收藏'),
                ],
              ),
              color: theme.colorScheme.surface,
            ),
          ),
        ];
      },
      body: TabBarView(
        children: [
          _PostsTab(pubkey: pubkey),
          _RepliesTab(pubkey: pubkey),
          _FollowsTab(pubkey: pubkey, isSelf: isSelf),
          _FollowersTab(pubkey: pubkey, isSelf: isSelf),
          _BookmarksTab(pubkey: pubkey),
        ],
      ),
    );
  }
}

/// Banner + metadata header.
class _Header extends ConsumerWidget {
  const _Header({
    required this.pubkey,
    required this.identity,
    required this.meta,
    required this.isSelf,
  });
  final String pubkey;
  final Identity? identity;
  final Metadata? meta;
  final bool isSelf;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final status = ref.watch(userStatusProvider(pubkey)).value;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (meta?.banner != null && meta!.banner!.isNotEmpty)
          SizedBox(
            height: 150,
            width: double.infinity,
            child: Image.network(
              meta!.banner!,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
          )
        else
          Container(
            height: 150,
            width: double.infinity,
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color(0xFF6750A4),
                  Color(0xFF7B1FA2),
                  Color(0xFF512DA8),
                ],
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Transform.translate(
                offset: const Offset(0, -24),
                child: Avatar(pubkey: pubkey, radius: 40),
              ),
              const SizedBox(height: 4),
              // Row 1 (X-style): display name (bold, wraps to 2 lines if long)
              // with the @-handle (npub abbreviation) on the line below, and the
              // action button (编辑资料 for self, 关注 for others) to the right.
              // The name wraps instead of ellipsizing on one line, so long
              // nicknames stay fully readable.
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          meta?.bestName ?? '(未设置名字)',
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          softWrap: true,
                        ),
                        _CopyableNprofile(pubkey: pubkey),
                      ],
                    ),
                  ),
                  if (isSelf) ...[
                    _FollowButton(pubkey: pubkey, isSelf: true),
                    IconButton(
                      icon: const Icon(Icons.edit, size: 20),
                      tooltip: '编辑资料',
                      onPressed: () => context.push('/profile/edit'),
                    ),
                  ] else
                    _FollowButton(pubkey: pubkey),
                ],
              ),
              // NIP-38 user status — 2 lines under the name. Self sees an
              // inline edit field (no popup); others see read-only italic text.
              if (isSelf)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: _StatusEditField(pubkey: pubkey, current: status),
                )
              else if (status != null && status.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    status,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: CostrColors.text3,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ),
              // Row 3: NIP-05 (wraps if long). The badge distinguishes
              // verified (server confirmed the pubkey) from unverified
              // (failed / couldn't check) — see _Nip05Badge.
              if (meta?.nip05 != null && meta!.nip05!.isNotEmpty) ...[
                const SizedBox(height: 4),
                Row(
                  children: [
                    _Nip05Badge(pubkey: pubkey),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        meta!.nip05!,
                        style: theme.textTheme.bodySmall,
                        overflow: TextOverflow.ellipsis,
                        maxLines: 2,
                      ),
                    ),
                  ],
                ),
              ],
              // Lightning address (lud16/lud06) — between NIP-05 and about.
              if ((meta?.lud16 != null && meta!.lud16!.isNotEmpty) ||
                  (meta?.lud06 != null && meta!.lud06!.isNotEmpty)) ...[
                const SizedBox(height: 4),
                Row(
                  children: [
                    Icon(
                      Icons.bolt,
                      size: 16,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        meta?.lud16 ?? meta?.lud06 ?? '',
                        style: theme.textTheme.bodySmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ],
              // Row 4: about (个人简介, rendered as linkified markdown with
              // expand/collapse. #hashtag → tappable to tag feed; npub/nprofile
              // → resolved username + tappable to profile; http → browser.)
              if (meta?.about != null && meta!.about!.isNotEmpty) ...[
                const SizedBox(height: 8),
                _AboutText(text: meta!.about!),
              ],
              if (meta?.website != null && meta!.website!.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(meta!.website!, style: theme.textTheme.bodySmall),
              ],
              const SizedBox(height: 12),
              // Profile stats: 关注/关注者 counts.
              _ProfileStats(pubkey: pubkey),
              const SizedBox(height: 12),
            ],
          ),
        ),
        const Divider(height: 1),
      ],
    );
  }
}

/// Profile stats row: 关注 / 关注者 counts (X-style: bold number + secondary
/// label, see DESIGN.md §3 / ui_demo.html `.prof-stats`). The 关注 count is
/// the pubkey's own follows ([userGroupedFollowsProvider] summed across
/// groups); 关注者 is who follows them ([userFollowersProvider]). Shows "—"
/// while an async value is still loading or errored.
class _ProfileStats extends ConsumerWidget {
  const _ProfileStats({required this.pubkey});
  final String pubkey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final followsAsync = ref.watch(userGroupedFollowsProvider(pubkey));
    final followersAsync = ref.watch(userFollowersProvider(pubkey));
    // Sum the pubkey's follows across all groups (默认分组 + custom groups).
    final followingCount = followsAsync.value?.fold<int>(
      0,
      (int s, FollowGroup g) => s + g.pubkeys.length,
    );
    final followersCount = followersAsync.value?.length;
    final theme = Theme.of(context);
    final numStyle = theme.textTheme.bodyMedium?.copyWith(
      fontWeight: FontWeight.w700,
    );
    final lblStyle = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.secondary,
    );
    return Row(
      children: [
        _stat(followingCount, '关注', numStyle, lblStyle),
        const SizedBox(width: 20),
        _stat(followersCount, '关注者', numStyle, lblStyle),
      ],
    );
  }

  Widget _stat(
    int? count,
    String label,
    TextStyle? numStyle,
    TextStyle? lblStyle,
  ) {
    final n = count == null ? '—' : _formatCount(count);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(n, style: numStyle),
        const SizedBox(width: 4),
        Text(label, style: lblStyle),
      ],
    );
  }

  /// X-style compact count: 312 → "312", 1234 → "1.2k", 1_200_000 → "1.2M".
  static String _formatCount(int n) {
    if (n < 1000) return '$n';
    if (n < 1000000) {
      final v = (n / 100).round() / 10.0;
      return '${v.toStringAsFixed(1)}k';
    }
    final v = (n / 100000).round() / 10.0;
    return '${v.toStringAsFixed(1)}M';
  }
}

/// 关注 button for an other-user profile. Shows 已关注 if the logged-in user
/// already follows them (per followingStateProvider); tap publishes an updated
/// kind-3 via [followUser].
class _FollowButton extends ConsumerStatefulWidget {
  const _FollowButton({required this.pubkey, this.followsMe = false, this.isSelf = false});
  final String pubkey;

  /// True when this pubkey follows the logged-in user (→ show "回关" until
  /// mutual). Set by callers that know it (e.g. the logged-in user's followers
  /// tab). Default false → plain "关注".
  final bool followsMe;

  /// True when [pubkey] IS the logged-in user (follow-self on own profile).
  /// Relabels to 关注自己 / 已关注自己; the multi-select sheet + NIP-02 path
  /// are identical to following anyone else (DESIGN §8 follow-yourself).
  final bool isSelf;

  @override
  ConsumerState<_FollowButton> createState() => _FollowButtonState();
}

class _FollowButtonState extends ConsumerState<_FollowButton> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final follows = ref.watch(followingStateProvider).value ?? const <String>[];
    final followed = follows.contains(widget.pubkey);
    final String label;
    if (widget.isSelf) {
      label = followed ? '已关注自己' : '关注自己';
    } else {
      label = followed ? '已关注' : (widget.followsMe ? '回关' : '关注');
    }
    final icon = followed ? Icons.check : Icons.person_add_outlined;
    return FilledButton.tonalIcon(
      icon: Icon(icon, size: 18),
      label: Text(label),
      onPressed: _busy ? null : (followed ? _unfollow : _follow),
    );
  }

  Future<void> _unfollow() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        content: const Text('取消关注？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('取消关注'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    final res = await unfollowUser(ref, widget.pubkey);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(res.ok ? '已取消关注' : '取消失败：${res.reason}')),
    );
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _follow() async {
    // Fetch the logged-in user's existing custom group names. Await the
    // provider's first emission (the SQLite snapshot) — reading `.value` on a
    // freshly-created StreamProvider returns null (loading), which `?? []`
    // would render as "no groups" every time the sheet opened.
    final identity = ref.read(identityProvider).value;
    if (identity == null) return;
    final groups =
        await ref.read(userGroupNamesProvider(identity.pubkeyHex).future);

    if (!mounted) return;
    // Multi-select follow sheet (Amethyst-style): pick the custom groups to
    // ALSO add the user to (kind-3 默认分组 is always added by the follow
    // itself). New groups can be created inline. Returns the set of selected
    // custom group names (empty = follow into 默认分组 only).
    final selected = await showModalBottomSheet<Set<String>>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext ctx) => _MultiGroupFollowSheet(
        groups: groups,
        onNewGroup: _showNewGroupDialog,
      ),
    );
    if (selected == null) return; // dismissed
    setState(() => _busy = true);
    final ok = await followUser(
      ref,
      widget.pubkey,
      categories: selected.toList(),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ok.ok ? '已关注' : '关注失败：${ok.reason}')),
    );
    if (mounted) setState(() => _busy = false);
  }

  Future<String?> _showNewGroupDialog(BuildContext context) async {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('新建分组'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '分组名称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }
}

/// Multi-select follow-group bottom sheet (Amethyst-style). Lists the user's
/// existing custom groups (NIP-51 kind-30000) as checkboxes + a "新建分组"
/// row that adds new names inline. Following always adds to kind-3 (默认分组);
/// the checked groups are EXTRA kind-30000 memberships. Confirm pops with the
/// selected set of custom group names (newly-created ones included).
class _MultiGroupFollowSheet extends StatefulWidget {
  const _MultiGroupFollowSheet({
    required this.groups,
    required this.onNewGroup,
  });
  final List<String> groups;
  final Future<String?> Function(BuildContext) onNewGroup;

  @override
  State<_MultiGroupFollowSheet> createState() => _MultiGroupFollowSheetState();
}

class _MultiGroupFollowSheetState extends State<_MultiGroupFollowSheet> {
  late final Set<String> _selected = {};
  late final List<String> _all = List<String>.from(widget.groups);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text('加入关注分组', style: theme.textTheme.titleSmall),
                  ),
                  TextButton(
                    onPressed: () =>
                        Navigator.pop(context, _selected.where((g) => g.isNotEmpty).toSet()),
                    child: const Text('关注'),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '默认分组始终包含。勾选的分组会额外把对方加进去。',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final g in _all)
                    CheckboxListTile(
                      controlAffinity: ListTileControlAffinity.leading,
                      value: _selected.contains(g),
                      onChanged: (v) => setState(() {
                        if (v == true) {
                          _selected.add(g);
                        } else {
                          _selected.remove(g);
                        }
                      }),
                      title: Text(g),
                    ),
                  ListTile(
                    leading: const Icon(Icons.add, size: 20),
                    title: const Text('新建分组…'),
                    onTap: () async {
                      final name = await widget.onNewGroup(context);
                      if (name == null || name.isEmpty) return;
                      if (!mounted) return;
                      setState(() {
                        if (_all.contains(name)) return;
                        _all.add(name);
                        _selected.add(name);
                      });
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Pinned TabBar sliver.
class _StickyTabBarDelegate extends SliverPersistentHeaderDelegate {
  _StickyTabBarDelegate(this.tabBar, {required this.color});
  final TabBar tabBar;
  final Color color;

  @override
  double get minExtent => tabBar.preferredSize.height;
  @override
  double get maxExtent => tabBar.preferredSize.height;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return Material(color: color, child: tabBar);
  }

  @override
  bool shouldRebuild(_StickyTabBarDelegate old) =>
      tabBar != old.tabBar || color != old.color;
}

class _PostsTab extends ConsumerStatefulWidget {
  const _PostsTab({required this.pubkey});
  final String pubkey;

  @override
  ConsumerState<_PostsTab> createState() => _PostsTabState();
}

class _PostsTabState extends ConsumerState<_PostsTab> {
  final _controller = TextEditingController();
  String _query = '';
  Timer? _debounce;

  @override
  void dispose() {
    _controller.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _onChanged(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (mounted) setState(() => _query = v.trim());
    });
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(userPostsProvider(widget.pubkey));
    // Sliver-based body (not Column[SearchBar, Expanded]) so the fixed-height
    // search bar doesn't overflow when the NestedScrollView body is given a
    // bounded height smaller than the bar during header scroll (the recurring
    // "bottom overflowed by N pixels" when the bio is long). Slivers tolerate
    // any bounded height; a Column with a fixed-height child does not.
    return RefreshIndicator(
      onRefresh: () => ref.refresh(userPostsProvider(widget.pubkey).future),
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(
            child: _SearchBar(
              controller: _controller,
              hint: '搜索该用户的帖子…',
              onChanged: _onChanged,
            ),
          ),
          async.when(
            loading: () => const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (Object e, _) => SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: Text('加载失败：$e')),
            ),
            data: (List<Event> all) {
              var posts = all.where((e) => !e.isReply).toList();
              if (_query.isNotEmpty) {
                final q = _query.toLowerCase();
                posts = posts
                    .where((e) => e.content.toLowerCase().contains(q))
                    .toList();
              }
              if (posts.isEmpty) {
                return SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(child: Text(_query.isEmpty ? '暂无帖子' : '无匹配帖子')),
                );
              }
              return SliverList(
                delegate: SliverChildBuilderDelegate(
                  (BuildContext context, int i) =>
                      UserPostItem(event: posts[i]),
                  childCount: posts.length,
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _RepliesTab extends ConsumerStatefulWidget {
  const _RepliesTab({required this.pubkey});
  final String pubkey;

  @override
  ConsumerState<_RepliesTab> createState() => _RepliesTabState();
}

class _RepliesTabState extends ConsumerState<_RepliesTab> {
  final _controller = TextEditingController();
  String _query = '';
  Timer? _debounce;

  @override
  void dispose() {
    _controller.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _onChanged(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (mounted) setState(() => _query = v.trim());
    });
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(userPostsProvider(widget.pubkey));
    return RefreshIndicator(
      onRefresh: () => ref.refresh(userPostsProvider(widget.pubkey).future),
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(
            child: _SearchBar(
              controller: _controller,
              hint: '搜索该用户的回帖…',
              onChanged: _onChanged,
            ),
          ),
          async.when(
            loading: () => const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (Object e, _) => SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: Text('加载失败：$e')),
            ),
            data: (List<Event> all) {
              var replies = all.where((e) => e.isReply).toList();
              if (_query.isNotEmpty) {
                final q = _query.toLowerCase();
                replies = replies
                    .where((e) => e.content.toLowerCase().contains(q))
                    .toList();
              }
              if (replies.isEmpty) {
                return SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(child: Text(_query.isEmpty ? '暂无回帖' : '无匹配回帖')),
                );
              }
              return SliverList(
                delegate: SliverChildBuilderDelegate(
                  (BuildContext context, int i) =>
                      UserPostItem(event: replies[i]),
                  childCount: replies.length,
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _FollowsTab extends ConsumerStatefulWidget {
  const _FollowsTab({required this.pubkey, required this.isSelf});
  final String pubkey;

  /// Only the logged-in user has a local followed-tags list (DESIGN §8), so
  /// the 关注的人 / 关注的标签 sub-tab only shows on the user's own profile.
  final bool isSelf;

  @override
  ConsumerState<_FollowsTab> createState() => _FollowsTabState();
}

class _FollowsTabState extends ConsumerState<_FollowsTab> {
  final _controller = TextEditingController();
  String _query = '';

  /// Selected group name, or null for "全部" (segmented view). See DESIGN §8.
  String? _selectedGroup;

  /// Sub-tab: 关注的人 (default) / 关注的标签 (self only).
  bool _showTags = false;
  Timer? _debounce;

  @override
  void dispose() {
    _controller.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _onChanged(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (mounted) setState(() => _query = v.trim());
    });
  }

  List<String> _filterGroup(
    List<String> pubkeys,
    Map<String, Metadata?> metaCache,
  ) {
    if (_query.isEmpty) return pubkeys;
    final q = _query.toLowerCase();
    String? npubHex;
    if (q.startsWith('npub1')) {
      try {
        npubHex = npubToHex(_query).toLowerCase();
      } catch (_) {}
    }
    return pubkeys.where((pk) {
      if (pk.toLowerCase().contains(q)) return true;
      if (npubHex != null && pk.toLowerCase().contains(npubHex)) return true;
      final m = metaCache[pk];
      if (m == null) return false;
      if ((m.name ?? '').toLowerCase().contains(q)) return true;
      if ((m.displayName ?? '').toLowerCase().contains(q)) return true;
      if ((m.nip05 ?? '').toLowerCase().contains(q)) return true;
      if ((m.about ?? '').toLowerCase().contains(q)) return true;
      return false;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Sliver-based (see _PostsTab): avoids the Column[fixed bar, Expanded]
    // overflow when the body is bounded smaller than the bar during scroll.
    return CustomScrollView(
      slivers: [
        if (widget.isSelf)
          SliverToBoxAdapter(
            child: _FollowSubTabs(
              showTags: _showTags,
              onSelected: (v) => setState(() => _showTags = v),
            ),
          ),
        if (widget.isSelf && _showTags)
          _buildTagsSliver(theme)
        else
          ..._buildPeopleSlivers(theme),
      ],
    );
  }

  List<Widget> _buildPeopleSlivers(ThemeData theme) {
    final async = ref.watch(userGroupedFollowsProvider(widget.pubkey));
    final slivers = <Widget>[
      SliverToBoxAdapter(
        child: _SearchBar(
          controller: _controller,
          hint: '过滤已关注…',
          onChanged: _onChanged,
        ),
      ),
    ];
    async.when(
      loading: () => slivers.add(
        const SliverFillRemaining(
          hasScrollBody: false,
          child: Center(child: CircularProgressIndicator()),
        ),
      ),
      error: (Object e, _) => slivers.add(
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(child: Text('加载失败：$e')),
        ),
      ),
      data: (List<FollowGroup> groups) {
        if (groups.isEmpty) {
          slivers.add(
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: Text('暂无关注')),
            ),
          );
          return;
        }
        // If the selected group vanished after a refresh, fall back to 全部.
        if (_selectedGroup != null &&
            !groups.any((g) => g.name == _selectedGroup)) {
          _selectedGroup = null;
        }
        final segmented = _selectedGroup == null;
        // Build a flat metadata cache for all pubkeys across groups.
        final allPks = <String>{};
        for (final g in groups) {
          allPks.addAll(g.pubkeys);
        }
        final metaCache = <String, Metadata?>{};
        for (final pk in allPks) {
          metaCache[pk] = ref.watch(metadataProvider(pk)).value;
        }
        // Build filtered sections. Only show per-group section headers
        // in 全部 (segmented) mode; a single selected group is a flat list.
        final sections = <Widget>[];
        for (final g in groups) {
          if (!segmented && g.name != _selectedGroup) continue;
          final filtered = _filterGroup(g.pubkeys, metaCache);
          if (filtered.isEmpty) continue;
          if (segmented) {
            sections.add(
              Container(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                color: theme.colorScheme.surfaceContainerHighest,
                child: Text(
                  '${g.name} (${filtered.length})',
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            );
          }
          for (final pk in filtered) {
            sections.add(
              _FollowRow(
                pubkey: pk,
                followsMe: false,
                onTap: () => context.push('/u/$pk'),
              ),
            );
          }
        }
        slivers.add(
          SliverToBoxAdapter(
            child: _GroupChipRow(
              groups: groups,
              selected: _selectedGroup,
              onSelected: (v) => setState(() => _selectedGroup = v),
            ),
          ),
        );
        if (sections.isEmpty) {
          slivers.add(
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: Text(_query.isEmpty ? '暂无关注' : '无匹配')),
            ),
          );
        } else {
          slivers.add(SliverList(delegate: SliverChildListDelegate(sections)));
        }
      },
    );
    return slivers;
  }

  /// 关注的标签 — synced via NIP-51 kind-30015 (DESIGN §8 / ui_demo.html
  /// `.tag-grid`). Each chip shows `#tag + 帖子数`; tap → jump to the home feed
  /// filtered by that tag; long-press → confirm unfollow. The leading "+ 标签"
  /// chip lets the user add a tag manually.
  Widget _buildTagsSliver(ThemeData theme) {
    final tagsAsync = ref.watch(followedTagsProvider);
    return tagsAsync.when(
      loading: () => const SliverFillRemaining(
        hasScrollBody: false,
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (Object e, _) => SliverFillRemaining(
        hasScrollBody: false,
        child: Center(child: Text('加载失败：$e')),
      ),
      data: (List<String> tags) {
        if (tags.isEmpty) {
          return const SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 32, vertical: 48),
                child: Text(
                  '还没关注的标签。\n'
                  '在帖子正文里长按 #标签 可关注；\n'
                  '在首页按某标签过滤时也能点星标关注。',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: CostrColors.text2, height: 1.6),
                ),
              ),
            ),
          );
        }
        return SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _AddTagChip(
                  onAdd: (t) => ref.read(followedTagsProvider.notifier).add(t),
                ),
                for (final tag in tags) _FollowedTagChip(tag: tag),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _FollowersTab extends ConsumerStatefulWidget {
  const _FollowersTab({required this.pubkey, required this.isSelf});
  final String pubkey;
  final bool isSelf;

  @override
  ConsumerState<_FollowersTab> createState() => _FollowersTabState();
}

class _FollowersTabState extends ConsumerState<_FollowersTab> {
  final _controller = TextEditingController();
  String _query = '';
  Timer? _debounce;

  @override
  void dispose() {
    _controller.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _onChanged(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (mounted) setState(() => _query = v.trim());
    });
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(userFollowersProvider(widget.pubkey));
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: _SearchBar(
            controller: _controller,
            hint: '过滤关注者…',
            onChanged: _onChanged,
          ),
        ),
        async.when(
          loading: () => const SliverFillRemaining(
            hasScrollBody: false,
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (Object e, _) => SliverFillRemaining(
            hasScrollBody: false,
            child: Center(child: Text('加载失败：$e')),
          ),
          data: (List<String> followers) {
            final metaCache = <String, Metadata?>{};
            for (final pk in followers) {
              metaCache[pk] = ref.watch(metadataProvider(pk)).value;
            }
            var list = followers;
            if (_query.isNotEmpty) {
              final q = _query.toLowerCase();
              String? npubHex;
              if (q.startsWith('npub1')) {
                try {
                  npubHex = npubToHex(_query).toLowerCase();
                } catch (_) {}
              }
              list = followers.where((pk) {
                if (pk.toLowerCase().contains(q)) return true;
                if (npubHex != null && pk.toLowerCase().contains(npubHex)) {
                  return true;
                }
                final m = metaCache[pk];
                if (m == null) return false;
                if ((m.name ?? '').toLowerCase().contains(q)) return true;
                if ((m.displayName ?? '').toLowerCase().contains(q)) {
                  return true;
                }
                if ((m.nip05 ?? '').toLowerCase().contains(q)) return true;
                if ((m.about ?? '').toLowerCase().contains(q)) return true;
                return false;
              }).toList();
            }
            if (list.isEmpty) {
              return SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: Text(_query.isEmpty ? '暂无关注者' : '无匹配')),
              );
            }
            return SliverList(
              delegate: SliverChildBuilderDelegate(
                (BuildContext context, int i) => _FollowRow(
                  pubkey: list[i],
                  followsMe: widget.isSelf,
                  onTap: () => context.push('/u/${list[i]}'),
                ),
                childCount: list.length,
              ),
            );
          },
        ),
      ],
    );
  }
}

/// 收藏 tab (NIP-51 kind-10003). Shows the user's bookmarked posts — public
/// bookmarks for everyone, plus the owner's private (NIP-44-decrypted) ones.
/// Amethyst-style: [bookmarksProvider] yields the SQLite-cached id list
/// instantly then background-refreshes from relays; each id resolves to an
/// [EventCard] via [eventByIdProvider]'s 3-tier lookup (SQLite → memory →
/// relay). DESIGN §8 — placed right after 关注者.
class _BookmarksTab extends ConsumerStatefulWidget {
  const _BookmarksTab({required this.pubkey});
  final String pubkey;

  @override
  ConsumerState<_BookmarksTab> createState() => _BookmarksTabState();
}

class _BookmarksTabState extends ConsumerState<_BookmarksTab> {
  final _controller = TextEditingController();
  String _query = '';
  Timer? _debounce;

  @override
  void dispose() {
    _controller.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _onChanged(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (mounted) setState(() => _query = v.trim());
    });
  }

  /// True if [entry] matches the current query. Empty query → always matches.
  /// Resolves the bookmarked event + author metadata from the cache so the
  /// user can search by post text or author name (not just the opaque id).
  /// Entries whose event hasn't resolved yet are hidden while a query is
  /// active; they reappear once resolved and the bookmarks stream re-emits.
  bool _matches(BookmarkEntry entry, String q) {
    if (q.isEmpty) return true;
    final ql = q.toLowerCase();
    if (entry.id.toLowerCase().contains(ql)) return true;
    final ev = ref.read(eventByIdProvider(entry.id)).value;
    if (ev == null) return false;
    if (ev.content.toLowerCase().contains(ql)) return true;
    if (ev.hashtags.any((t) => t.toLowerCase().contains(ql))) return true;
    final meta = ref.read(metadataProvider(ev.pubkey)).value;
    if (meta != null) {
      if ((meta.name ?? '').toLowerCase().contains(ql)) return true;
      if ((meta.displayName ?? '').toLowerCase().contains(ql)) return true;
      if ((meta.nip05 ?? '').toLowerCase().contains(ql)) return true;
    }
    return false;
  }

  Widget _sectionHeader(String title, int count, ThemeData theme) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Text(
          '$title · $count',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: theme.colorScheme.outline,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final async = ref.watch(bookmarksProvider(widget.pubkey));
    return RefreshIndicator(
      onRefresh: () => ref.refresh(bookmarksProvider(widget.pubkey).future),
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: <Widget>[
          SliverToBoxAdapter(
            child: _SearchBar(
              controller: _controller,
              hint: '搜索收藏…',
              onChanged: _onChanged,
            ),
          ),
          async.when(
            loading: () => const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (Object e, _) => SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: Text('加载失败：$e')),
            ),
            data: (List<BookmarkEntry> entries) {
              final public = entries
                  .where((e) => e.public && _matches(e, _query))
                  .toList();
              final private = entries
                  .where((e) => !e.public && _matches(e, _query))
                  .toList();
              if (public.isEmpty && private.isEmpty) {
                return SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(
                    child: Text(_query.isEmpty ? '暂无收藏' : '无匹配结果'),
                  ),
                );
              }
              return SliverMainAxisGroup(
                slivers: <Widget>[
                  if (public.isNotEmpty) ...[
                    _sectionHeader('公开书签', public.length, theme),
                    SliverList(
                      delegate: SliverChildBuilderDelegate(
                        (BuildContext context, int i) => _BookmarkRow(
                          eventId: public[i].id,
                          publicList: true,
                        ),
                        childCount: public.length,
                      ),
                    ),
                  ],
                  if (private.isNotEmpty) ...[
                    _sectionHeader('私人书签', private.length, theme),
                    SliverList(
                      delegate: SliverChildBuilderDelegate(
                        (BuildContext context, int i) => _BookmarkRow(
                          eventId: private[i].id,
                          publicList: false,
                        ),
                        childCount: private.length,
                      ),
                    ),
                  ],
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

/// A single bookmarked post — resolves [eventId] → [Event] via
/// [eventByIdProvider] (SQLite → memory → relay) and renders an [EventCard].
/// Loading / not-found states degrade gracefully (a bookmark may reference an
/// event not yet fetched; it streams in when the relay responds). A small lock
/// badge marks private bookmarks so the owner can tell them apart at a glance.
class _BookmarkRow extends ConsumerWidget {
  const _BookmarkRow({required this.eventId, this.publicList = true});
  final String eventId;
  final bool publicList;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(eventByIdProvider(eventId));
    final badge = publicList
        ? null
        : Padding(
            padding: const EdgeInsets.only(left: 12, top: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(
                  Icons.lock_outline,
                  size: 12,
                  color: Theme.of(context).colorScheme.outline,
                ),
                const SizedBox(width: 4),
                Text(
                  '私人',
                  style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context).colorScheme.outline,
                  ),
                ),
              ],
            ),
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        async.when(
          loading: () => const ListTile(
            dense: true,
            leading: SizedBox(
              width: 18,
              height: 18,
              child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
            ),
            title: Text('加载中…'),
          ),
          error: (Object e, _) => ListTile(
            dense: true,
            title: const Text('收藏的帖子加载失败'),
            subtitle: Text('$e'),
          ),
          data: (Event? e) => e == null
              ? const ListTile(dense: true, title: Text('收藏的帖子暂不可用'))
              : EventCard(event: e),
        ),
        ?badge,
      ],
    );
  }
}

/// Sub-tab bar for the 关注 tab: 关注的人 / 关注的标签 (DESIGN §8 /
/// ui_demo.html `.sub-tabs`). Only mounted on the logged-in user's own
/// profile (see _FollowsTab.isSelf).
class _FollowSubTabs extends StatelessWidget {
  const _FollowSubTabs({required this.showTags, required this.onSelected});
  final bool showTags;
  final ValueChanged<bool> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget tab(String label, bool on) {
      return Expanded(
        child: GestureDetector(
          onTap: on ? null : () => onSelected(!showTags),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 10),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: on ? theme.colorScheme.primary : Colors.transparent,
                  width: 3,
                ),
              ),
            ),
            child: Text(
              label,
              style: theme.textTheme.labelLarge?.copyWith(
                color: on
                    ? theme.colorScheme.onSurface
                    : theme.colorScheme.secondary,
                fontWeight: on ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(bottom: BorderSide(color: theme.colorScheme.outline)),
      ),
      child: Row(children: [tab('关注的人', !showTags), tab('关注的标签', showTags)]),
    );
  }
}

/// Horizontal group-filter chip row for the 关注 tab (DESIGN §8 / ui_demo.html
/// `.grp-chips`). "全部" (selected = null) → segmented by group; a specific
/// group → flat list of only that group.
class _GroupChipRow extends StatelessWidget {
  const _GroupChipRow({
    required this.groups,
    required this.selected,
    required this.onSelected,
  });
  final List<FollowGroup> groups;
  final String? selected;
  final ValueChanged<String?> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget chip(String label, String? value) {
      final on = selected == value;
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: GestureDetector(
          onTap: () => onSelected(value),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: on ? theme.colorScheme.primary : theme.colorScheme.surface,
              border: Border.all(
                color: on
                    ? theme.colorScheme.primary
                    : theme.colorScheme.outline,
              ),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              label,
              style: theme.textTheme.labelMedium?.copyWith(
                color: on
                    ? theme.colorScheme.onPrimary
                    : theme.colorScheme.secondary,
                fontWeight: on ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(bottom: BorderSide(color: theme.colorScheme.outline)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            chip('全部', null),
            for (final g in groups) chip(g.name, g.name),
          ],
        ),
      ),
    );
  }
}

/// One followed-hashtag chip (DESIGN §8 / ui_demo.html `.tag-chip`): shows
/// `#tag 帖子数`. Tap → filter the home feed by this tag; long-press → confirm
/// unfollow. The post count is a local sample ([tagPostCountProvider]).
class _FollowedTagChip extends ConsumerWidget {
  const _FollowedTagChip({required this.tag});
  final String tag;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final count = ref.watch(tagPostCountProvider(tag));
    return GestureDetector(
      onLongPress: () async {
        final ok = await showDialog<bool>(
          context: context,
          builder: (BuildContext ctx) => AlertDialog(
            content: Text('取消关注 #$tag？'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('取消关注'),
              ),
            ],
          ),
        );
        if (ok == true) {
          await ref.read(followedTagsProvider.notifier).remove(tag);
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('#$tag', style: theme.textTheme.labelLarge),
            if (count > 0) ...[
              const SizedBox(width: 4),
              Text(
                '$count',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
      onTap: () {
        ref.read(tagFilterProvider.notifier).set(tag);
        context.go('/feed');
      },
    );
  }
}

/// Leading chip for manually adding a followed tag.
class _AddTagChip extends StatelessWidget {
  const _AddTagChip({required this.onAdd});
  final ValueChanged<String> onAdd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ActionChip(
      avatar: const Icon(Icons.add, size: 18),
      label: const Text('标签'),
      shape: const StadiumBorder(),
      side: BorderSide(color: theme.colorScheme.outline),
      backgroundColor: theme.colorScheme.surface,
      onPressed: () async {
        final controller = TextEditingController();
        final tag = await showDialog<String>(
          context: context,
          builder: (BuildContext ctx) => AlertDialog(
            title: const Text('关注标签'),
            content: TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(hintText: '标签名，如 nostr'),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, controller.text.trim()),
                child: const Text('关注'),
              ),
            ],
          ),
        );
        if (tag != null && tag.isNotEmpty) onAdd(tag);
      },
    );
  }
}

class _SearchBar extends StatelessWidget {
  const _SearchBar({
    required this.controller,
    required this.hint,
    required this.onChanged,
  });
  final TextEditingController controller;
  final String hint;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: TextField(
        controller: controller,
        decoration: InputDecoration(
          hintText: hint,
          prefixIcon: const Icon(Icons.search, size: 20),
          isDense: true,
          border: const OutlineInputBorder(),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 8,
          ),
        ),
        onChanged: onChanged,
      ),
    );
  }
}

/// Shows the pubkey as a shortened `nprofile1...` abbreviation with a copy
/// button. Tapping copies the full nprofile to the clipboard.
class _CopyableNprofile extends StatelessWidget {
  const _CopyableNprofile({required this.pubkey});
  final String pubkey;

  @override
  Widget build(BuildContext context) {
    final nprofile = hexToNprofile(pubkey);
    final theme = Theme.of(context);
    return GestureDetector(
      onTap: () async {
        await Clipboard.setData(ClipboardData(text: nprofile));
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('已复制 nprofile'),
              duration: Duration(seconds: 1),
            ),
          );
        }
      },
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              shortenEntity(nprofile),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: 4),
          Icon(Icons.copy, size: 14, color: theme.colorScheme.onSurfaceVariant),
        ],
      ),
    );
  }
}

/// NIP-05 verification badge. Verified (the domain's nostr.json maps the
/// handle to this pubkey) → the check icon in the brand color. Failed / could
/// not reach the domain → a muted error-outline so unverified handles are
/// visually distinct from verified ones. While checking, a tiny spinner.
class _Nip05Badge extends ConsumerWidget {
  const _Nip05Badge({required this.pubkey});
  final String pubkey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final async = ref.watch(nip05VerifiedProvider(pubkey));
    if (async.isLoading) {
      return SizedBox(
        width: 14,
        height: 14,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: theme.colorScheme.outline,
        ),
      );
    }
    final status = async.value ?? Nip05Status.unknown;
    final IconData icon;
    final Color color;
    switch (status) {
      case Nip05Status.verified:
        icon = Icons.verified;
        color = theme.colorScheme.primary;
      case Nip05Status.failed:
      case Nip05Status.unknown:
      case Nip05Status.none:
        icon = Icons.error_outline;
        color = theme.colorScheme.outline;
    }
    return Icon(icon, size: 16, color: color);
  }
}

class _FollowRow extends ConsumerWidget {
  const _FollowRow({
    required this.pubkey,
    required this.onTap,
    this.followsMe = false,
  });
  final String pubkey;
  final VoidCallback onTap;
  final bool followsMe;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final meta = ref.watch(metadataProvider(pubkey)).value;
    return ListTile(
      leading: Avatar(pubkey: pubkey, radius: 18),
      title: Text(
        displayLabelFor(pubkey, meta),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: _FollowButton(pubkey: pubkey, followsMe: followsMe),
      onTap: onTap,
    );
  }
}

/// Inline NIP-38 status editor for the user's own profile — a direct text
/// field (no popup) under the name, above the about. maxLength 100 (NIP-38
/// statuses are short). Enter / check icon signs kind-30315 (d="general") +
/// publishes; publishAndWait already does per-relay 1/2/3s retry. Local cache
/// is written + [userStatusProvider] invalidated so the new status shows
/// instantly.
class _StatusEditField extends ConsumerStatefulWidget {
  const _StatusEditField({required this.pubkey, this.current});
  final String pubkey;
  final String? current;

  @override
  ConsumerState<_StatusEditField> createState() => _StatusEditFieldState();
}

class _StatusEditFieldState extends ConsumerState<_StatusEditField> {
  late final TextEditingController _c =
      TextEditingController(text: widget.current ?? '');
  bool _saving = false;
  bool _focused = false;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _StatusEditField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Sync from an async refresh only while not actively editing.
    final next = widget.current ?? '';
    if (!_focused && next != _c.text) {
      _c.value = TextEditingValue(
        text: next,
        selection: TextSelection.collapsed(offset: next.length),
      );
    }
  }

  Future<void> _save() async {
    final id = ref.read(identityProvider).value;
    if (id == null) return;
    final text = _c.text.trim();
    setState(() => _saving = true);
    final signed = NostrActions(id).userStatus(text);
    await ref.read(relayPoolProvider).publishAndWait(signed);
    // Local cache so it shows instantly + offline.
    final db = await ref.read(localCacheProvider.future);
    await db.writeEvent(
      id: signed.id,
      pubkey: signed.pubkey,
      kind: signed.kind,
      createdAt: signed.createdAt,
      content: signed.content,
      sig: signed.sig,
      raw: jsonEncode(signed.toWireObject()),
      tagsJson: jsonEncode(signed.tags),
      tags: signed.tags,
    );
    ref.invalidate(userStatusProvider(widget.pubkey));
    if (mounted) setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Focus(
      onFocusChange: (f) => setState(() => _focused = f),
      child: TextField(
        controller: _c,
        maxLength: 100,
        maxLines: 1,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => unawaited(_save()),
        decoration: InputDecoration(
          hintText: '状态签名（NIP-38）',
          isDense: true,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: theme.colorScheme.outline),
          ),
          suffixIcon: _saving
              ? const Padding(
                  padding: EdgeInsets.all(8),
                  child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : IconButton(
                  tooltip: '保存',
                  icon: const Icon(Icons.check, size: 18),
                  onPressed: () => unawaited(_save()),
                ),
        ),
      ),
    );
  }
}

/// Renders the profile about text as linkified markdown with expand/collapse.
/// - npub1/nprofile1 mentions → resolved username, tappable to profile.
/// - #hashtag → tappable, sets tag filter + goes to feed.
/// - http(s) links → opens in default browser.
/// - Content taller than [_collapsedHeight] collapses with 展开/收起
///   (measured by actual rendered height, so a short-by-char-count but
///   line-heavy bio still collapses — the char-count gate used before let
///   one's own multi-line bio render full while longer others' bios folded).
class _AboutText extends ConsumerStatefulWidget {
  const _AboutText({required this.text});
  final String text;

  @override
  ConsumerState<_AboutText> createState() => _AboutTextState();
}

class _AboutTextState extends ConsumerState<_AboutText> {
  bool _expanded = false;
  /// True once the full body has been laid out and found to exceed
  /// [_collapsedHeight]. Until measured, the body renders unclipped so it can
  /// be measured (and so genuinely short bios never clip).
  bool _overflows = false;
  bool _measured = false;
  final _measureKey = GlobalKey();
  static const double _collapsedHeight = 150;

  @override
  void initState() {
    super.initState();
    _scheduleMeasure();
  }

  @override
  void didUpdateWidget(covariant _AboutText oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Metadata reloaded with different content → re-measure.
    if (oldWidget.text != widget.text) {
      _measured = false;
      _overflows = false;
      _expanded = false;
      _scheduleMeasure();
    }
  }

  void _scheduleMeasure() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _measured) return;
      final ctx = _measureKey.currentContext;
      final box = ctx?.findRenderObject();
      if (box is! RenderBox || !box.hasSize) {
        // Not laid out yet (markdown still resolving) — try again next frame.
        if (mounted) _scheduleMeasure();
        return;
      }
      _measured = true;
      if (box.size.height > _collapsedHeight + 8) {
        setState(() => _overflows = true);
      }
    });
  }

  static final RegExp _entityRegex = RegExp(
    r'(?:nostr:)?((?:nprofile1|npub1)[qpzry9x8gf2tvdw0s3jn54khce6mua7l]{6,})',
  );
  static final RegExp _hashtagRegex = RegExp(
    r'(?<![\w/:.])#([\p{L}\p{N}_]+)',
    unicode: true,
  );

  @override
  Widget build(BuildContext context) {
    // 0. Preserve blank lines. Markdown collapses runs of blank lines into a
    // single paragraph break; Amethyst renders multiple blank lines. Replace
    // each empty line with a zero-width space (non-whitespace → not a blank
    // line → no paragraph split) and render soft line breaks as real breaks
    // (softLineBreak: true below), so each blank line stays visible.
    var processed = widget.text
        .split('\n')
        .map((l) => l.trim().isEmpty ? '​' : l)
        .join('\n');
    // 1. Linkify npub/nprofile mentions.
    final pubkeysByEntity = <String, String?>{};
    for (final m in _entityRegex.allMatches(processed)) {
      // group(1) = the bare entity (no `nostr:` prefix); use it for both
      // pubkey lookup and the link href so the href stays `nostr:<bare>`
      // (no doubled prefix).
      final entity = m.group(1)!;
      pubkeysByEntity.putIfAbsent(entity, () => entityToPubkeyHex(entity));
    }
    final nameByPubkey = <String, String>{};
    for (final pk in pubkeysByEntity.values) {
      if (pk == null) continue;
      final meta = ref.watch(metadataProvider(pk)).value;
      final name = meta?.bestName;
      if (name != null && name.isNotEmpty) nameByPubkey[pk] = name;
    }
    processed = processed.replaceAllMapped(_entityRegex, (Match m) {
      final entity = m.group(1)!;
      final pk = pubkeysByEntity[entity];
      final label =
          (pk != null ? nameByPubkey[pk] : null) ?? shortenEntity(entity);
      return '[@$label](nostr:$entity)';
    });
    // 2. Linkify #hashtag → [#tag](costr:tag:tag)
    processed = processed.replaceAllMapped(_hashtagRegex, (Match m) {
      final tag = m.group(1)!.toLowerCase();
      return '[#${m.group(1)}](costr:tag:$tag)';
    });

    final theme = Theme.of(context);
    final isLong = _overflows;

    Widget body = MarkdownBody(
      key: _measured ? null : _measureKey,
      data: processed,
      softLineBreak: true,
      extensionSet: ExtensionSet.gitHubFlavored,
      onTapLink: (String text, String? href, String? title) {
        if (href == null) return;
        if (href.startsWith('nostr:')) {
          final entity = href.substring('nostr:'.length);
          final pk = entityToPubkeyHex(entity);
          if (pk != null) context.push('/u/$pk');
        } else if (href.startsWith('costr:tag:')) {
          // flutter_markdown percent-encodes non-ASCII in hrefs (e.g. Chinese
          // #去掉 → costr:tag:%E5%8E%BB…) — decode so the tag filter gets the
          // real characters, not mojibake.
          final tag = Uri.decodeFull(href.substring('costr:tag:'.length));
          ref.read(tagFilterProvider.notifier).set(tag);
          context.go('/feed');
        } else if (href.startsWith('http')) {
          launchUrl(Uri.parse(href), mode: LaunchMode.externalApplication);
        }
      },
      styleSheet: MarkdownStyleSheet.fromTheme(theme),
    );

    if (!isLong || _expanded) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          body,
          if (isLong)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => setState(() => _expanded = false),
                child: const Text('收起'),
              ),
            ),
        ],
      );
    }
    // Collapsed: wrap the body in a NeverScrollable SingleChildScrollView
    // inside ClipRect. ClipRect alone only clips PAINT — the markdown's
    // internal Column still receives the bounded maxHeight and throws
    // "RenderFlex overflowed by N pixels" when the about is long. The
    // SingleChildScrollView gives the body unbounded height (no layout
    // overflow) while ClipRect clips it to the collapsed height.
    final surface = theme.colorScheme.surface;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: _collapsedHeight,
          child: Stack(
            children: [
              ClipRect(
                child: SingleChildScrollView(
                  physics: const NeverScrollableScrollPhysics(),
                  child: body,
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.only(top: 24),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [surface.withValues(alpha: 0), surface],
                    ),
                  ),
                  child: TextButton(
                    onPressed: () => setState(() => _expanded = true),
                    child: const Text('展开'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
