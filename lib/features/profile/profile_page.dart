/// Profile page — header (banner/avatar/metadata) + 帖子/回帖/关注/关注者 tabs.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
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
          _FollowsTab(pubkey: pubkey),
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
              // Row 4: about (个人简介, capped to prevent header overflow).
              if (meta?.about != null && meta!.about!.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  meta!.about!,
                  style: theme.textTheme.bodyMedium,
                  maxLines: 8,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              if (meta?.website != null && meta!.website!.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(meta!.website!, style: theme.textTheme.bodySmall),
              ],
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
  const _FollowsTab({required this.pubkey});
  final String pubkey;

  @override
  ConsumerState<_FollowsTab> createState() => _FollowsTabState();
}

class _FollowsTabState extends ConsumerState<_FollowsTab> {
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
    final async = ref.watch(userFollowsProvider(widget.pubkey));
    return Column(
      children: [
        _SearchBar(controller: _controller, hint: '过滤已关注…', onChanged: _onChanged),
        Expanded(
          child: async.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (Object e, _) => Center(child: Text('加载失败：$e')),
            data: (List<String> follows) {
              // Watch metadata per pubkey → filter by name/nip05/about/pubkey.
              final metaCache = <String, Metadata?>{};
              for (final pk in follows) {
                metaCache[pk] = ref.watch(metadataProvider(pk)).value;
              }
              var list = follows;
              if (_query.isNotEmpty) {
                final q = _query.toLowerCase();
                String? npubHex;
                if (q.startsWith('npub1')) {
                  try { npubHex = npubToHex(_query).toLowerCase(); } catch (_) {}
                }
                list = follows.where((pk) {
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
              if (list.isEmpty) return Center(child: Text(_query.isEmpty ? '暂无关注' : '无匹配'));
              return ListView.builder(
                itemCount: list.length,
                itemBuilder: (BuildContext context, int i) => _FollowRow(
                  pubkey: list[i],
                  followsMe: false,
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
