/// Server customize sheet (服务器节点 page → 「自定义」, DESIGN.md §13). An
/// explicit advanced feature: edit ONE category's server list — add/remove
/// servers, restore the built-in defaults. Edits are staged in a local draft
/// and committed in ONE shot on 「保存」 via [saveServerList] (persist +
/// hot-swap the live pool + publish kind 10002 for the relay category).
///
/// The warning copy is deliberately plain (DESIGN.md §9 说人话): it spells out
/// what the category does, that customization is only needed for a server
/// that's been offline for a long time, and what breaks if the list is wrong.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/server_list_rules.dart';
import '../../app/theme.dart';
import '../../services/server_discovery.dart' show discoverySupported;

/// What the recommended servers were verified to do, per category (shown as
/// a one-line caption under 「为你推荐」). Every caption ends with a
/// self-verification reminder: a probe only proves the server worked AT PROBE
/// TIME — the user must check it themselves after swapping, ESPECIALLY search
/// relays (search quality can't be probed automatically at all) and indexers
/// (handled in [_warningFor] — they have no recommendation block). Blossom
/// also mentions the tiny test upload the probe performs — transparency about
/// what "实测" touched.
String _recoCaptionFor(ServerCategory category) {
  switch (category) {
    case ServerCategory.relay:
      return '这些服务器经过检测：能连上、免费。检测结果只代表当时，'
          '添加后请自行验证收发是否正常。'
          '推荐来自其他用户公开的服务器列表，不依赖任何中心服务器。';
    case ServerCategory.search:
      return '这些服务器经过检测：能连上、免费、自报支持搜索。'
          '但搜索效果好不好无法自动检测，添加后请自己搜几个关键词验证。'
          '推荐来自其他用户公开的服务器列表，不依赖任何中心服务器。';
    case ServerCategory.indexer:
      return '';
    case ServerCategory.blossom:
      return '这些图床经过实测：可以免费上传（检测时上传了一个极小的测试文件）。'
          '之后仍可能失效，添加后可自行上传一张图片验证。';
  }
}

/// Per-category warning shown at the top of the sheet.
String _warningFor(ServerCategory category) {
  const onlyWhenOffline = '只有当某台服务器长期处于离线状态时，才需要来自定义。';
  const fallback = '不确定怎么改的话，保持默认就好。';
  switch (category) {
    case ServerCategory.relay:
      return '这是高级功能。这里的服务器决定你能刷到的帖子从哪来、你发的帖子发到哪去。'
          '$onlyWhenOffline'
          '如果列表配置错误，可能刷不出新帖子，或发帖失败。'
          '$fallback';
    case ServerCategory.search:
      return '这是高级功能。这里的服务器专门负责搜索功能。'
          '$onlyWhenOffline'
          '如果列表配置错误，搜索时可能搜不到任何结果。'
          '更换或添加后请自行验证：搜几个关键词，看能否搜到帖子。'
          '$fallback';
    case ServerCategory.indexer:
      return '这是高级功能。这里的服务器用来获取别人的昵称和头像。'
          '$onlyWhenOffline'
          '如果列表配置错误，部分人的昵称、头像可能显示不出来。'
          '更换或添加后请自行验证可用性：打开一个陌生账号的主页，'
          '看昵称、头像能否正常显示。'
          '$fallback';
    case ServerCategory.blossom:
      return '这是高级功能。这里的服务器用来存放你上传的图片和视频，'
          '只支持使用 Blossom 协议的图床。'
          '$onlyWhenOffline'
          '如果列表配置错误，图片和视频会上传失败。'
          '$fallback';
  }
}

/// Open the customize sheet for [category]. Resolves `true` when the user
/// saved a new list (caller should reload), anything else means no change.
Future<bool?> showServerListSheet({
  required BuildContext context,
  required WidgetRef ref,
  required ServerCategory category,
}) {
  final name = categoryDisplayName(category);
  final min = minServersFor(category);
  final current = ref.read(serverListsProvider).value?.of(category);
  final draft = List<String>.of(current ?? defaultServerListFor(category));
  final controller = TextEditingController();
  String? fieldError;
  var saving = false;

  // Decentralized recommendations (server_discovery.dart): start probing the
  // moment the sheet opens. Null future = nothing to show (unsupported
  // category, or blossom while logged out — the UI shows a hint instead).
  // Reassigned by 「换一批」; the FutureBuilder below always reads the latest.
  final blossomLoggedOut =
      category == ServerCategory.blossom &&
      ref.read(identityProvider).value == null;
  Future<List<String>>? recoFuture =
      (discoverySupported(category) && !blossomLoggedOut)
      ? recommendServers(ref, category)
      : null;

  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) {
      final insets = MediaQuery.viewInsetsOf(ctx);
      final colors = CostrColors.of(ctx);
      return StatefulBuilder(
        builder: (ctx, setState) {
          void addUrl() {
            final err = serverUrlError(
              category,
              controller.text,
              existing: draft,
            );
            if (err != null) {
              setState(() => fieldError = err);
              return;
            }
            setState(() {
              draft.add(normalizeServerUrl(controller.text));
              fieldError = null;
              controller.clear();
            });
          }

          Future<void> save() async {
            if (saving) return;
            setState(() => saving = true);
            final messenger = ScaffoldMessenger.of(ctx);
            try {
              await saveServerList(ref, category, draft);
              if (ctx.mounted) Navigator.pop(ctx, true);
              messenger.showSnackBar(const SnackBar(content: Text('已保存')));
            } catch (_) {
              if (ctx.mounted) {
                setState(() {
                  saving = false;
                  fieldError = '保存失败，请重试';
                });
              }
            }
          }

          return AnimatedPadding(
            // Lift the sheet above the soft keyboard (ADD the keyboard height,
            // don't copyWith — see mute_list_page._showAddSheet).
            padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + insets.bottom),
            duration: const Duration(milliseconds: 120),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '自定义$name',
                    style: Theme.of(ctx).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: colors.warnBg,
                      border: Border.all(color: colors.warnBorder),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      _warningFor(category),
                      style: Theme.of(ctx).textTheme.bodySmall,
                    ),
                  ),
                  const SizedBox(height: 12),
                  for (var i = 0; i < draft.length; i++)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              draft[i],
                              style: Theme.of(ctx).textTheme.bodyMedium,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          IconButton(
                            tooltip: draft.length <= min ? '至少保留 $min 台' : '删除',
                            icon: const Icon(Icons.delete_outline),
                            iconSize: 20,
                            color: colors.text3,
                            onPressed: draft.length <= min
                                ? null
                                : () => setState(() => draft.removeAt(i)),
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: controller,
                          decoration: InputDecoration(
                            isDense: true,
                            hintText: category == ServerCategory.blossom
                                ? 'https://…'
                                : 'wss://…',
                            errorText: fieldError,
                          ),
                          onSubmitted: (_) {
                            if (draft.length < maxServersPerCategory) addUrl();
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: draft.length >= maxServersPerCategory
                            ? null
                            : addUrl,
                        child: const Text('添加'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '共 ${draft.length} 台 · 最多 $maxServersPerCategory 台 · '
                    '至少保留 $min 台',
                    style: Theme.of(
                      ctx,
                    ).textTheme.bodySmall?.copyWith(color: colors.text3),
                  ),
                  const SizedBox(height: 12),
                  if (blossomLoggedOut)
                    Text(
                      '登录后可为你推荐可用的免费图床',
                      style: Theme.of(
                        ctx,
                      ).textTheme.bodySmall?.copyWith(color: colors.text3),
                    ),
                  if (recoFuture != null)
                    // Probed recommendations (or the probing spinner). No
                    // error/no-result states render anything: per product
                    // decision, "找不到可推荐的就什么都不显示".
                    FutureBuilder<List<String>>(
                      future: recoFuture,
                      builder: (ctx, snapshot) {
                        if (snapshot.connectionState ==
                            ConnectionState.waiting) {
                          return Row(
                            children: [
                              const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  '正在为你寻找可用的服务器…',
                                  style: Theme.of(ctx).textTheme.bodySmall
                                      ?.copyWith(color: colors.text3),
                                ),
                              ),
                            ],
                          );
                        }
                        final urls = snapshot.data ?? const <String>[];
                        if (urls.isEmpty) return const SizedBox.shrink();
                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Text(
                                  '为你推荐',
                                  style: Theme.of(ctx).textTheme.bodyMedium
                                      ?.copyWith(fontWeight: FontWeight.w600),
                                ),
                                const Spacer(),
                                TextButton(
                                  onPressed: saving
                                      ? null
                                      : () => setState(() {
                                          recoFuture = recommendServers(
                                            ref,
                                            category,
                                            force: true,
                                          );
                                        }),
                                  child: const Text('换一批'),
                                ),
                              ],
                            ),
                            Text(
                              _recoCaptionFor(category),
                              style: Theme.of(ctx).textTheme.bodySmall
                                  ?.copyWith(color: colors.text3),
                            ),
                            for (final url in urls)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 2,
                                ),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        url,
                                        style: Theme.of(
                                          ctx,
                                        ).textTheme.bodyMedium,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    TextButton(
                                      onPressed:
                                          (saving ||
                                              draft.contains(url) ||
                                              draft.length >=
                                                  maxServersPerCategory)
                                          ? null
                                          : () => setState(() {
                                              draft.add(url);
                                              fieldError = null;
                                            }),
                                      child: Text(
                                        draft.contains(url) ? '已添加' : '添加',
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        );
                      },
                    ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      TextButton(
                        onPressed: saving
                            ? null
                            : () => setState(() {
                                draft
                                  ..clear()
                                  ..addAll(
                                    normalizeServerList(
                                      defaultServerListFor(category),
                                    ),
                                  );
                                fieldError = null;
                              }),
                        child: const Text('恢复默认'),
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: saving ? null : () => Navigator.pop(ctx),
                        child: const Text('取消'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: saving ? null : save,
                        child: saving
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Text('保存'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      );
    },
  );
}
