/// Manage the logged-in user's NIP-51 kind-10000 mute list (Amethyst interop).
/// Lists muted users (resolved to names), words, and hashtags with un-mute
/// buttons. Reads [muteListProvider] (public + NIP-44-decrypted private); an
/// un-mute signs an updated kind-10000 via [muteEntry] and the feed filter
/// ([currentFeedEventsProvider] watches [myMuteSetProvider]) re-applies.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../widgets/avatar.dart';

class MuteListPage extends ConsumerWidget {
  const MuteListPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final identity = ref.watch(identityProvider).value;
    if (identity == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('屏蔽列表')),
        body: const Center(child: Text('未登录')),
      );
    }
    final async = ref.watch(muteListProvider(identity.pubkeyHex));
    return Scaffold(
      appBar: AppBar(
        title: const Text('屏蔽列表'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: '添加屏蔽词/标签',
            onPressed: () => _showAddSheet(context, ref),
          ),
        ],
      ),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) => const Center(child: Text('加载失败')),
        data: (mute) {
          if (mute.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  '还没有屏蔽任何人或词。\n在用户主页点 ⋮ → 屏蔽，帖子就不会出现在信息流里。',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          return ListView(
            children: [
              if (mute.pubkeys.isNotEmpty) ...[
                _MuteSectionHeader('用户（${mute.pubkeys.length}）'),
                for (final pk in mute.pubkeys) _MuteUserTile(pubkey: pk),
              ],
              if (mute.words.isNotEmpty) ...[
                _MuteSectionHeader('词（${mute.words.length}）'),
                for (final w in mute.words)
                  _MuteWordTile(word: w, isHashtag: false),
              ],
              if (mute.hashtags.isNotEmpty) ...[
                _MuteSectionHeader('标签（${mute.hashtags.length}）'),
                for (final t in mute.hashtags)
                  _MuteWordTile(word: t, isHashtag: true),
              ],
              const SizedBox(height: 24),
            ],
          );
        },
      ),
    );
  }
}

class _MuteSectionHeader extends StatelessWidget {
  const _MuteSectionHeader(this.title);
  final String title;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Text(
        title,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: CostrColors.of(context).text2,
        ),
      ),
    );
  }
}

/// Add a muted word or hashtag. Bottom sheet with a type toggle (词/标签) +
/// text field.词 → `["word", v]` (substring match in post content); 标签 →
/// `["t", v]` (hide posts carrying the hashtag). Both default-private
/// (NIP-44-encrypted in the kind-10000 content, Amethyst interop).
void _showAddSheet(BuildContext context, WidgetRef ref) {
  bool isHashtag = false;
  final controller = TextEditingController();
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) {
      final insets = MediaQuery.viewInsetsOf(ctx);
      return StatefulBuilder(
        builder: (ctx, setState) {
          return AnimatedPadding(
            // Lift the sheet above the soft keyboard. NB: EdgeInsets.copyWith
            // REPLACES fields — `.copyWith(bottom: 16)` would clobber the
            // keyboard height (viewInsets.bottom) with 16 and the sheet would
            // stay under the keyboard. Add them instead: keyboard height + a
            // 16px breathing gap above it.
            padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + insets.bottom),
            duration: const Duration(milliseconds: 120),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('添加屏蔽', style: Theme.of(ctx).textTheme.titleSmall),
                const SizedBox(height: 8),
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: false, label: Text('词')),
                    ButtonSegment(value: true, label: Text('标签')),
                  ],
                  selected: {isHashtag},
                  onSelectionChanged: (s) =>
                      setState(() => isHashtag = s.first),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: controller,
                  autofocus: true,
                  decoration: InputDecoration(
                    hintText: isHashtag ? '输入标签，如 股市行情' : '输入词，如 广告',
                    prefixText: isHashtag ? '#' : null,
                  ),
                  onSubmitted: (v) => _commit(ctx, ref, v, isHashtag),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () =>
                        _commit(ctx, ref, controller.text, isHashtag),
                    child: const Text('添加'),
                  ),
                ),
              ],
            ),
          );
        },
      );
    },
  );
}

Future<void> _commit(
  BuildContext ctx,
  WidgetRef ref,
  String raw,
  bool isHashtag,
) async {
  final v = raw.replaceAll('#', '').trim();
  if (v.isEmpty) return;
  final entry = isHashtag
      ? <String>['t', v.toLowerCase()]
      : <String>['word', v];
  Navigator.pop(ctx);
  await muteEntry(ref, entry, add: true);
}

class _MuteUserTile extends ConsumerWidget {
  const _MuteUserTile({required this.pubkey});
  final String pubkey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final meta = ref.watch(metadataProvider(pubkey)).value;
    return ListTile(
      leading: Avatar(pubkey: pubkey, radius: 18),
      title: Text(meta?.bestName ?? pubkey.substring(0, 12)),
      subtitle: Text(
        pubkey.substring(0, 16),
        style: TextStyle(
          fontSize: 11,
          fontFamily: 'monospace',
          color: CostrColors.of(context).text3,
        ),
      ),
      trailing: TextButton(
        onPressed: () => _unmute(ref, context),
        child: const Text('取消屏蔽'),
      ),
      onTap: () => context.push('/u/$pubkey'),
    );
  }

  Future<void> _unmute(WidgetRef ref, BuildContext context) async {
    await muteEntry(ref, ['p', pubkey], add: false);
  }
}

class _MuteWordTile extends ConsumerWidget {
  const _MuteWordTile({required this.word, required this.isHashtag});
  final String word;
  final bool isHashtag;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      leading: Icon(
        isHashtag ? Icons.tag : Icons.block,
        size: 20,
        color: CostrColors.of(context).text2,
      ),
      title: Text(isHashtag ? '#$word' : word),
      trailing: TextButton(
        onPressed: () async {
          final entry = isHashtag
              ? <String>['t', word]
              : <String>['word', word];
          await muteEntry(ref, entry, add: false);
        },
        child: const Text('取消屏蔽'),
      ),
    );
  }
}
