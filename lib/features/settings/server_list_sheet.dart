/// Server customize sheet (服务器节点 page → 「自定义」, DESIGN.md §13). An
/// explicit advanced feature: edit ONE category's server list — add/remove
/// servers, restore the built-in defaults. Edits are staged in a local draft
/// and committed in ONE shot on 「保存」 via [saveServerList] (persist +
/// hot-swap the live pool + publish kind 10002 for the relay category).
///
/// Blossom extras (the only category where ORDER is user-visible — list order
/// = upload retry priority): rows are drag-reorderable, and the 「测速」
/// button measures each draft server's real upload + download bandwidth
/// (10 MiB fresh random file, see services/blossom_upload.dart). Speed
/// results live ONLY in the sheet's closure state: closing the sheet clears
/// them and aborts in-flight requests. Nothing is persisted.
///
/// The warning copy is deliberately plain (DESIGN.md §9 说人话): it spells out
/// what the category does, that customization is only needed for a server
/// that's been offline for a long time, and what breaks if the list is wrong.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../app/providers.dart';
import '../../app/server_list_rules.dart';
import '../../app/theme.dart';
import '../../services/blossom_upload.dart'
    show BlossomSpeed, blossomSpeedTestBytes, measureBlossomSpeed;
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
          '拖动调整顺序，排在前面的优先使用；'
          '点「测速」可实测每台的上传/下载速度，把快的放前面。'
          '$onlyWhenOffline'
          '如果列表配置错误，图片和视频会上传失败。'
          '$fallback';
  }
}

/// Open the customize sheet for [category]. Resolves `true` when the user
/// saved a new list (caller should reload), anything else means no change.
///
/// [debugSpeedClient] (tests only): injected http client for the Blossom
/// speed test, so widget tests run without real network.
Future<bool?> showServerListSheet({
  required BuildContext context,
  required WidgetRef ref,
  required ServerCategory category,
  @visibleForTesting http.Client? debugSpeedClient,
}) {
  final name = categoryDisplayName(category);
  final min = minServersFor(category);
  final current = ref.read(serverListsProvider).value?.of(category);
  final draft = List<String>.of(current ?? defaultServerListFor(category));
  final controller = TextEditingController();
  String? fieldError;
  var saving = false;

  // Blossom speed-test state — closure-local by design: results are NEVER
  // persisted and die with the sheet (the whenComplete cleanup below also
  // aborts in-flight requests by closing [speedClient]).
  var speedRunning = false;
  var speedStep = 0; // 0-based index of the server currently being measured.
  var speedTotal = 0;
  String? speedCurrent; // url being measured right now.
  final speedResults = <String, BlossomSpeed>{};
  http.Client? speedClient;

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

  final sheet = showModalBottomSheet<bool>(
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

          // Editing is locked while a speed test runs (as well as while
          // saving): the test iterates a SNAPSHOT taken at start, so
          // concurrent add/remove/reorder would misalign rows and results;
          // 取消 stays enabled as the escape hatch (closing the sheet aborts
          // the run).
          final busy = saving || speedRunning;

          /// One-click speed test over the draft list, one server at a time
          /// (parallel streams would fight for the user's bandwidth and
          /// distort the very numbers being measured).
          Future<void> runSpeedTest() async {
            if (busy) return;
            final identity = ref.read(identityProvider).value;
            if (identity == null) return; // button disabled in this state
            final targets = List<String>.of(draft);
            if (targets.isEmpty) return;
            final client = debugSpeedClient ?? http.Client();
            // ONE fresh 10 MiB payload for the whole run, reused across
            // servers: cheap on memory, and every RUN still gets fresh bytes
            // (fresh sha256) so no server-side dedupe shortcut.
            final testBytes = blossomSpeedTestBytes();
            speedClient = client;
            setState(() {
              speedRunning = true;
              speedStep = 0;
              speedTotal = targets.length;
              speedCurrent = null;
              speedResults.clear();
            });
            try {
              for (var i = 0; i < targets.length; i++) {
                if (!ctx.mounted) return; // sheet closed → results discarded
                final url = targets[i];
                setState(() {
                  speedStep = i;
                  speedCurrent = url;
                });
                BlossomSpeed result;
                try {
                  result = await measureBlossomSpeed(
                    identity,
                    url,
                    testBytes: testBytes,
                    client: client,
                  );
                } catch (_) {
                  // Aborted (sheet closed → client closed) or unexpected
                  // error — treat as a failed measurement for this server.
                  result = const BlossomSpeed();
                }
                if (!ctx.mounted) return;
                setState(() {
                  speedResults[url] = result;
                  speedCurrent = null;
                });
              }
            } finally {
              // Only close clients we created ourselves (tests inject one
              // MockClient per test and expect it usable for the whole test).
              if (debugSpeedClient == null) client.close();
              speedClient = null;
              if (ctx.mounted) {
                setState(() {
                  speedRunning = false;
                  speedCurrent = null;
                });
              }
            }
          }

          /// One server row: URL + delete. Blossom rows additionally get a
          /// drag handle (the listener is inert for other categories — they
          /// don't live in a ReorderableListView, and the handle is only
          //  rendered for blossom anyway).
          Widget serverRow(int i, String url) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              children: [
                if (category == ServerCategory.blossom)
                  ReorderableDragStartListener(
                    index: i,
                    enabled: !busy,
                    child: Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Icon(
                        Icons.drag_handle,
                        size: 20,
                        color: colors.text3,
                      ),
                    ),
                  ),
                Expanded(
                  child: Text(
                    url,
                    style: Theme.of(ctx).textTheme.bodyMedium,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  tooltip: draft.length <= min ? '至少保留 $min 台' : '删除',
                  icon: const Icon(Icons.delete_outline),
                  iconSize: 20,
                  color: colors.text3,
                  onPressed: (busy || draft.length <= min)
                      ? null
                      : () => setState(() => draft.removeAt(i)),
                ),
              ],
            ),
          );

          /// Blossom-only line under a server row: the live speed-test
          /// progress / result for that url. Returns null when there is
          /// nothing to show for it.
          Widget? speedLine(String url) {
            if (speedRunning && speedCurrent == url) {
              return Padding(
                padding: const EdgeInsets.only(left: 28, bottom: 4),
                child: Row(
                  children: [
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '正在测速…（上传 10 MB 测试文件）',
                        style: Theme.of(
                          ctx,
                        ).textTheme.bodySmall?.copyWith(color: colors.text3),
                      ),
                    ),
                  ],
                ),
              );
            }
            final r = speedResults[url];
            if (r == null) return null;
            if (r.uploadMBps == null) {
              return Padding(
                padding: const EdgeInsets.only(left: 28, bottom: 4),
                child: Text(
                  '测速失败',
                  style: Theme.of(
                    ctx,
                  ).textTheme.bodySmall?.copyWith(color: colors.red),
                ),
              );
            }
            final up = r.uploadMBps!.toStringAsFixed(1);
            final down = r.downloadMBps == null
                ? '下载失败'
                : '下载 ${r.downloadMBps!.toStringAsFixed(1)} MB/s';
            return Padding(
              padding: const EdgeInsets.only(left: 28, bottom: 4),
              child: Text(
                '上传 $up MB/s · $down',
                style: Theme.of(
                  ctx,
                ).textTheme.bodySmall?.copyWith(color: colors.text2),
              ),
            );
          }

          /// Blossom row wrapped for drag-reorder (the ReorderableListView
          /// child): the URL row + its optional speed-test line.
          Widget blossomRow(int i) {
            final url = draft[i];
            final line = speedLine(url);
            return Column(
              key: ValueKey(url),
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [serverRow(i, url), ?line],
            );
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
                  if (category == ServerCategory.blossom)
                    // Drag-reorderable rows (Blossom only — its list order IS
                    // the upload retry priority). Explicit drag handles:
                    // desktop has no long-press-drag habit, and immediate
                    // drag avoids the delayed-drag vs scroll gesture
                    // conflict. The outer SingleChildScrollView scrolls; the
                    // list itself never does. Reorder only lands in [draft]
                    // — persisted on 「保存」 like every other edit.
                    ReorderableListView(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      buildDefaultDragHandles: false,
                      // onReorderItem (not the deprecated onReorder): the
                      // newIndex it passes is ALREADY adjusted for the item
                      // removed at oldIndex — no manual -1 correction needed.
                      onReorderItem: (oldIndex, newIndex) {
                        if (busy) return;
                        setState(() {
                          final item = draft.removeAt(oldIndex);
                          draft.insert(newIndex, item);
                          fieldError = null;
                        });
                      },
                      children: [
                        for (var i = 0; i < draft.length; i++) blossomRow(i),
                      ],
                    )
                  else
                    for (var i = 0; i < draft.length; i++)
                      serverRow(i, draft[i]),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: controller,
                          enabled: !busy,
                          decoration: InputDecoration(
                            isDense: true,
                            hintText: category == ServerCategory.blossom
                                ? 'https://…'
                                : 'wss://…',
                            errorText: fieldError,
                          ),
                          onSubmitted: (_) {
                            if (!busy && draft.length < maxServersPerCategory) {
                              addUrl();
                            }
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed:
                            (busy || draft.length >= maxServersPerCategory)
                            ? null
                            : addUrl,
                        child: const Text('添加'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  // The whole action row (恢复默认 | [测速] | 取消 | 保存) sits
                  // right under the add field, above the count caption and
                  // the recommendations: the user's flow is add-a-server →
                  // save, and the old position (bottom of the sheet, under
                  // the reco block) forced scrolling past the recommendations
                  // to reach 保存. Applies to all four categories (one shared
                  // sheet); 「测速」 only exists for blossom.
                  Row(
                    children: [
                      TextButton(
                        onPressed: busy
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
                      if (category == ServerCategory.blossom)
                        TextButton.icon(
                          onPressed: (busy || blossomLoggedOut)
                              ? null
                              : runSpeedTest,
                          icon: speedRunning
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.speed, size: 18),
                          label: Text(
                            speedRunning
                                ? '测速中 ${speedStep + 1}/$speedTotal'
                                : '测速',
                          ),
                        ),
                      const Spacer(),
                      // 取消 stays enabled during a speed test — it is the
                      // escape hatch that aborts the run (closing the sheet
                      // closes [speedClient], which kills in-flight requests).
                      TextButton(
                        onPressed: saving ? null : () => Navigator.pop(ctx),
                        child: const Text('取消'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: busy ? null : save,
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
                      '登录后可为你推荐可用的免费图床，也能一键测速',
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
                                  onPressed: busy
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
                                          (busy ||
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
                ],
              ),
            ),
          );
        },
      );
    },
  );
  // Closing the sheet (save / cancel / barrier tap / swipe down) discards all
  // speed-test state with the closure. Closing the dedicated speed-test client
  // also aborts any in-flight request — its error is caught inside the run
  // loop, which then bails on the `ctx.mounted` check.
  sheet.whenComplete(() => speedClient?.close());
  return sheet;
}
