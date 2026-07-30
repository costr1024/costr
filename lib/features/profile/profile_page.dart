/// Profile page — header (banner/avatar/metadata) + 帖子/回帖/关注/关注者 tabs.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:markdown/markdown.dart' hide Text;
import 'package:url_launcher/url_launcher.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../models/event.dart';
import '../../models/metadata.dart';
import '../../nostr/identity.dart';
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
            length: 4,
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

    return NestedScrollView(
      headerSliverBuilder: (BuildContext context, bool innerBoxIsScrolled) {
        return <Widget>[
          SliverToBoxAdapter(
              child: _Header(pubkey: pubkey, identity: identity, meta: meta, isSelf: isSelf)),
          SliverPersistentHeader(
            pinned: true,
            delegate: _StickyTabBarDelegate(
              TabBar(
                tabAlignment: TabAlignment.start,
                isScrollable: true,
                tabs: const [Tab(text: '帖子'), Tab(text: '回帖'), Tab(text: '关注'), Tab(text: '关注者')],
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
        ],
      ),
    );
  }
}

/// Banner + metadata header.
class _Header extends ConsumerWidget {
  const _Header({required this.pubkey, required this.identity, required this.meta, required this.isSelf});
  final String pubkey;
  final Identity? identity;
  final Metadata? meta;
  final bool isSelf;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Column(
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
                colors: [Color(0xFF6750A4), Color(0xFF7B1FA2), Color(0xFF512DA8)],
              ),
            ),
          ),
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
              // Row 1: nickname + follow button.
              Row(
                children: [
                  Flexible(
                    child: Text(
                      meta?.bestName ?? '(未设置名字)',
                      style: theme.textTheme.titleLarge,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  _FollowButton(pubkey: pubkey),
                ],
              ),
              const SizedBox(height: 4),
              // Row 2: nprofile abbreviation (copyable).
              _CopyableNprofile(pubkey: pubkey),
              // Row 3: NIP-05 (wraps if long).
              if (meta?.nip05 != null && meta!.nip05!.isNotEmpty) ...[
                const SizedBox(height: 4),
                Row(
                  children: [
                    Icon(Icons.verified, size: 16, color: theme.colorScheme.primary),
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
                    Icon(Icons.bolt, size: 16, color: theme.colorScheme.primary),
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
              if (isSelf) ...[
                const SizedBox(height: 16),
                Row(
                  children: [
                    FilledButton.tonalIcon(
                      icon: const Icon(Icons.edit),
                      label: const Text('编辑资料'),
                      onPressed: () => context.push('/profile/edit'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.tonalIcon(
                      icon: const Icon(Icons.logout),
                      label: const Text('登出'),
                      onPressed: () async {
                        await ref.read(identityProvider.notifier).logout();
                        if (context.mounted) context.go('/login');
                      },
                    ),
                  ],
                ),
              ],
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
    final numStyle =
        theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700);
    final lblStyle = theme.textTheme.bodyMedium
        ?.copyWith(color: theme.colorScheme.secondary);
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
  const _FollowButton({required this.pubkey, this.followsMe = false});
  final String pubkey;
  /// True when this pubkey follows the logged-in user (→ show "回关" until
  /// mutual). Set by callers that know it (e.g. the logged-in user's followers
  /// tab). Default false → plain "关注".
  final bool followsMe;

  @override
  ConsumerState<_FollowButton> createState() => _FollowButtonState();
}

class _FollowButtonState extends ConsumerState<_FollowButton> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final follows = ref.watch(followingStateProvider).value ?? const <String>[];
    final followed = follows.contains(widget.pubkey);
    final label = followed
        ? '已关注'
        : (widget.followsMe ? '回关' : '关注');
    return FilledButton.tonalIcon(
      icon: Icon(followed ? Icons.check : Icons.person_add_outlined, size: 18),
      label: Text(label),
      onPressed: _busy ? null : (followed ? null : _follow),
    );
  }

  Future<void> _follow() async {
    // Fetch the logged-in user's existing custom group names.
    final identity = ref.read(identityProvider).value;
    if (identity == null) return;
    final groups = ref.read(userGroupNamesProvider(identity.pubkeyHex)).value ?? const <String>[];

    // Show a category picker: 默认分组 + existing custom groups + 新建分组.
    final category = await showModalBottomSheet<String>(
      context: context,
      builder: (BuildContext ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text('选择关注分组', style: Theme.of(ctx).textTheme.titleSmall),
            ),
            ListTile(
              leading: const Icon(Icons.label_off_outlined, size: 20),
              title: const Text('默认分组'),
              onTap: () => Navigator.pop(ctx, ''),
            ),
            for (final g in groups)
              ListTile(
                leading: const Icon(Icons.label_outline, size: 20),
                title: Text(g),
                onTap: () => Navigator.pop(ctx, g),
              ),
            ListTile(
              leading: const Icon(Icons.add, size: 20),
              title: const Text('新建分组…'),
              onTap: () async {
                Navigator.pop(ctx);
                final name = await _showNewGroupDialog(ctx);
                if (name != null && name.isNotEmpty) {
                  if (ctx.mounted) Navigator.pop(ctx, name);
                }
              },
            ),
          ],
        ),
      ),
    );
    if (category == null) return; // dismissed
    setState(() => _busy = true);
    final ok = await followUser(ref, widget.pubkey,
        category: category.isEmpty ? null : category);
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
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }
}

/// Pinned TabBar sliver.
class _StickyTabBarDelegate extends SliverPersistentHeaderDelegate {  _StickyTabBarDelegate(this.tabBar, {required this.color});
  final TabBar tabBar;
  final Color color;

  @override
  double get minExtent => tabBar.preferredSize.height;
  @override
  double get maxExtent => tabBar.preferredSize.height;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
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
    return Column(
      children: [
        _SearchBar(controller: _controller, hint: '搜索该用户的帖子…', onChanged: _onChanged),
        Expanded(
          child: async.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (Object e, _) => Center(child: Text('加载失败：$e')),
            data: (List<Event> all) {
              var posts = all.where((e) => !e.isReply).toList();
              if (_query.isNotEmpty) {
                final q = _query.toLowerCase();
                posts = posts.where((e) => e.content.toLowerCase().contains(q)).toList();
              }
              if (posts.isEmpty) return Center(child: Text(_query.isEmpty ? '暂无帖子' : '无匹配帖子'));
              return ListView.builder(
                itemCount: posts.length,
                itemBuilder: (BuildContext context, int i) => UserPostItem(event: posts[i]),
              );
            },
          ),
        ),
      ],
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
    return Column(
      children: [
        _SearchBar(controller: _controller, hint: '搜索该用户的回帖…', onChanged: _onChanged),
        Expanded(
          child: async.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (Object e, _) => Center(child: Text('加载失败：$e')),
            data: (List<Event> all) {
              var replies = all.where((e) => e.isReply).toList();
              if (_query.isNotEmpty) {
                final q = _query.toLowerCase();
                replies = replies.where((e) => e.content.toLowerCase().contains(q)).toList();
              }
              if (replies.isEmpty) return Center(child: Text(_query.isEmpty ? '暂无回帖' : '无匹配回帖'));
              return ListView.builder(
                itemCount: replies.length,
                itemBuilder: (BuildContext context, int i) => UserPostItem(event: replies[i]),
              );
            },
          ),
        ),
      ],
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

  List<String> _filterGroup(List<String> pubkeys, Map<String, Metadata?> metaCache) {
    if (_query.isEmpty) return pubkeys;
    final q = _query.toLowerCase();
    String? npubHex;
    if (q.startsWith('npub1')) {
      try { npubHex = npubToHex(_query).toLowerCase(); } catch (_) {}
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
    return Column(
      children: [
        if (widget.isSelf)
          _FollowSubTabs(
            showTags: _showTags,
            onSelected: (v) => setState(() => _showTags = v),
          ),
        Expanded(
          child: widget.isSelf && _showTags
              ? _buildTags(theme)
              : _buildPeople(theme),
        ),
      ],
    );
  }

  Widget _buildPeople(ThemeData theme) {
    final async = ref.watch(userGroupedFollowsProvider(widget.pubkey));
    return Column(
      children: [
        _SearchBar(controller: _controller, hint: '过滤已关注…', onChanged: _onChanged),
        Expanded(
          child: async.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (Object e, _) => Center(child: Text('加载失败：$e')),
            data: (List<FollowGroup> groups) {
              if (groups.isEmpty) return const Center(child: Text('暂无关注'));
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
                        style: theme.textTheme.labelMedium
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ),
                  );
                }
                for (final pk in filtered) {
                  sections.add(_FollowRow(
                    pubkey: pk,
                    followsMe: false,
                    onTap: () => context.push('/u/$pk'),
                  ));
                }
              }
              final chips = _GroupChipRow(
                groups: groups,
                selected: _selectedGroup,
                onSelected: (v) => setState(() => _selectedGroup = v),
              );
              final empty = sections.isEmpty
                  ? Center(
                      child: Text(_query.isEmpty ? '暂无关注' : '无匹配'))
                  : ListView(children: sections);
              return Column(
                children: [chips, Expanded(child: empty)],
              );
            },
          ),
        ),
      ],
    );
  }

  /// 关注的标签 — local-only list (DESIGN §8). Tap a tag → jump to the home
  /// feed filtered by that tag. Empty state explains where tags come from.
  Widget _buildTags(ThemeData theme) {
    final tagsAsync = ref.watch(followedTagsProvider);
    return tagsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (Object e, _) => Center(child: Text('加载失败：$e')),
      data: (List<String> tags) {
        if (tags.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 32, vertical: 48),
              child: Text(
                '还没关注的标签。\n在帖子正文里的 #标签 上点击，即可在首页按标签过滤；'
                '关注标签的功能后续会补上。',
                textAlign: TextAlign.center,
                style: TextStyle(color: CostrColors.text2, height: 1.6),
              ),
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.all(16),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final tag in tags)
                ActionChip(
                  label: Text('#$tag'),
                  shape: const StadiumBorder(),
                  side: BorderSide(color: theme.colorScheme.outline),
                  backgroundColor: theme.colorScheme.surface,
                  onPressed: () {
                    ref.read(tagFilterProvider.notifier).set(tag);
                    context.go('/feed');
                  },
                ),
            ],
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
    return Column(
      children: [
        _SearchBar(controller: _controller, hint: '过滤关注者…', onChanged: _onChanged),
        Expanded(
          child: async.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (Object e, _) => Center(child: Text('加载失败：$e')),
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
                  try { npubHex = npubToHex(_query).toLowerCase(); } catch (_) {}
                }
                list = followers.where((pk) {
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
              if (list.isEmpty) return Center(child: Text(_query.isEmpty ? '暂无关注者' : '无匹配'));
              return ListView.builder(
                itemCount: list.length,
                itemBuilder: (BuildContext context, int i) => _FollowRow(
                  pubkey: list[i],
                  followsMe: widget.isSelf,
                  onTap: () => context.push('/u/${list[i]}'),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Sub-tab bar for the 关注 tab: 关注的人 / 关注的标签 (DESIGN §8 /
/// ui_demo.html `.sub-tabs`). Only mounted on the logged-in user's own
/// profile (see _FollowsTab.isSelf).
class _FollowSubTabs extends StatelessWidget {
  const _FollowSubTabs({
    required this.showTags,
    required this.onSelected,
  });
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
        border:
            Border(bottom: BorderSide(color: theme.colorScheme.outline)),
      ),
      child: Row(
        children: [
          tab('关注的人', !showTags),
          tab('关注的标签', showTags),
        ],
      ),
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
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
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
        border:
            Border(bottom: BorderSide(color: theme.colorScheme.outline)),
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

/// Reusable search bar with a persistent controller (no cursor reset on rebuild).
class _SearchBar extends StatelessWidget {
  const _SearchBar({required this.controller, required this.hint, required this.onChanged});
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
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
            const SnackBar(content: Text('已复制 nprofile'), duration: Duration(seconds: 1)),
          );
        }
      },
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            shortenEntity(nprofile),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 4),
          Icon(Icons.copy, size: 14, color: theme.colorScheme.onSurfaceVariant),
        ],
      ),
    );
  }
}

class _FollowRow extends ConsumerWidget {
  const _FollowRow({required this.pubkey, required this.onTap, this.followsMe = false});
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

/// Renders the profile about text as linkified markdown with expand/collapse.
/// - npub1/nprofile1 mentions → resolved username, tappable to profile.
/// - #hashtag → tappable, sets tag filter + goes to feed.
/// - http(s) links → opens in default browser.
/// - Long text (> 300 chars) collapses with 展开/收起.
class _AboutText extends ConsumerStatefulWidget {
  const _AboutText({required this.text});
  final String text;

  @override
  ConsumerState<_AboutText> createState() => _AboutTextState();
}

class _AboutTextState extends ConsumerState<_AboutText> {
  bool _expanded = false;
  static const int _collapseThreshold = 200;
  static const double _collapsedHeight = 150;

  static final RegExp _entityRegex =
      RegExp(r'(?:nostr:)?(nprofile1|npub1)[qpzry9x8gf2tvdw0s3jn54khce6mua7l]{6,}');
  static final RegExp _hashtagRegex = RegExp(r'(?<![\w/:.])#([\p{L}\p{N}_]+)', unicode: true);

  @override
  Widget build(BuildContext context) {
    // 1. Linkify npub/nprofile mentions.
    final pubkeysByEntity = <String, String?>{};
    for (final m in _entityRegex.allMatches(widget.text)) {
      final entity = m.group(0)!;
      pubkeysByEntity.putIfAbsent(entity, () => entityToPubkeyHex(entity));
    }
    final nameByPubkey = <String, String>{};
    for (final pk in pubkeysByEntity.values) {
      if (pk == null) continue;
      final meta = ref.watch(metadataProvider(pk)).value;
      final name = meta?.bestName;
      if (name != null && name.isNotEmpty) nameByPubkey[pk] = name;
    }
    var processed = widget.text.replaceAllMapped(_entityRegex, (Match m) {
      final entity = m.group(0)!;
      final pk = pubkeysByEntity[entity];
      final label = (pk != null ? nameByPubkey[pk] : null) ?? shortenEntity(entity);
      return '[@$label](nostr:$entity)';
    });
    // 2. Linkify #hashtag → [#tag](costr:tag:tag)
    processed = processed.replaceAllMapped(_hashtagRegex, (Match m) {
      final tag = m.group(1)!.toLowerCase();
      return '[#${m.group(1)}](costr:tag:$tag)';
    });

    final theme = Theme.of(context);
    final isLong = widget.text.length > _collapseThreshold;

    Widget body = MarkdownBody(
      data: processed,
      extensionSet: ExtensionSet.gitHubFlavored,
      onTapLink: (String text, String? href, String? title) {
        if (href == null) return;
        if (href.startsWith('nostr:')) {
          final entity = href.substring('nostr:'.length);
          final pk = entityToPubkeyHex(entity);
          if (pk != null) context.push('/u/$pk');
        } else if (href.startsWith('costr:tag:')) {
          final tag = href.substring('costr:tag:'.length);
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
          if (isLong) Align(
            alignment: Alignment.centerRight,
            child: TextButton(onPressed: () => setState(() => _expanded = false), child: const Text('收起')),
          ),
        ],
      );
    }
    // Collapsed: use SizedBox + ClipRect (robust — no SingleChildScrollView
    // which can conflict with NestedScrollView's gesture handling).
    final surface = theme.colorScheme.surface;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: _collapsedHeight,
          child: Stack(
            children: [
              ClipRect(child: body),
              Positioned(
                left: 0, right: 0, bottom: 0,
                child: Container(
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.only(top: 24),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter, end: Alignment.bottomCenter,
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
