/// Settings page (DESIGN.md §7 — 通知/账号/服务器/关于/退出登录).
library;

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../services/account_registry.dart';
import '../../utils/nip19.dart';
import '../../widgets/avatar.dart';
import '../../widgets/display_name.dart';
import '../auth/login_page.dart' show showLogoutSheet;

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final level = ref.watch(textScaleProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        children: [
          const _SectionHeader('通用'),
          _Row(
            title: '字号',
            subtitle: '${level.label}（放大 ${(level.factor * 100).round()}%）',
            onTap: () => _showTextScaleSheet(context, ref, level),
          ),
          _Row(
            title: '通知',
            subtitle: '回复、喜欢、关注等',
            onTap: () => context.push('/settings/notifications'),
          ),
          _Row(
            title: '账号备份',
            subtitle: '账号级 NSFW 设置、备份私钥',
            onTap: () => context.push('/settings/account'),
          ),
          _Row(
            title: '服务器节点',
            subtitle: 'Costr 连接的服务器，一般不用改',
            onTap: () => context.push('/settings/relays'),
          ),
          _Row(
            title: '屏蔽列表',
            subtitle: '已屏蔽的用户、词、标签',
            onTap: () => context.push('/settings/mute'),
          ),
          _LocalSwitchTile(
            title: '代理媒体',
            subtitleOn: '已开启：含图片/视频的帖子显示「代理媒体」按钮，点按走 proxy.bostr.online',
            subtitleOff: '关闭：不显示「代理媒体」按钮。仅本机设置，不同步中继',
            enabled: ref.watch(proxyMediaEnabledProvider),
            onChanged: (v) =>
                ref.read(proxyMediaEnabledProvider.notifier).set(v),
          ),
          // Immersive browse (LOCAL-only, never synced). When ON, the top
          // app bar + bottom nav + FAB hide on scroll-down and return on
          // scroll-up (Amethyst pattern) for full-screen browsing.
          _LocalSwitchTile(
            title: '沉浸式浏览',
            subtitleOn: '已开启：向下滚动隐藏顶栏/底栏/发帖键，向上滚动恢复。仅本机，不同步',
            subtitleOff: '关闭：顶栏底栏常驻。仅本机设置，不同步中继',
            enabled: ref.watch(immersiveBrowseProvider),
            onChanged: (v) => ref.read(immersiveBrowseProvider.notifier).set(v),
          ),
          const _SectionHeader('关于'),
          _Row(
            title: '关于 Costr',
            subtitle: '是什么、设计理念',
            onTap: () => context.push('/about'),
          ),
          const _SectionHeader('账号'),
          const _AccountList(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
            child: Text(
              '点按账号即可切换，当前账号保持活跃、其余账号不占用连接；'
              '长按账号可将其从本机移除。',
              style: TextStyle(
                fontSize: 12,
                color: CostrColors.of(context).text3,
                height: 1.5,
              ),
            ),
          ),
          _Row(
            title: '添加账号',
            subtitle: '用已有私钥登录或创建新账号',
            onTap: () => context.push('/login?add=1'),
          ),
          _Row(
            title: '退出登录',
            titleColor: CostrColors.of(context).red,
            subtitle: '移除当前账号私钥，保留本地数据，下次可恢复',
            onTap: () => showLogoutSheet(context, ref),
          ),
          const SizedBox(height: 24),
          Text(
            'Costr = Chinese Nostr\n'
            '更适合中文用户的 Nostr 开源社交客户端',
            style: Theme.of(context).textTheme.labelSmall,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          const _VersionFooter(),
        ],
      ),
    );
  }

  void _showTextScaleSheet(
    BuildContext context,
    WidgetRef ref,
    TextScaleLevel current,
  ) {
    showModalBottomSheet<void>(
      context: context,
      builder: (BuildContext ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '字号',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
              ),
              for (final l in TextScaleLevel.values)
                ListTile(
                  onTap: () {
                    ref.read(textScaleProvider.notifier).set(l);
                    Navigator.pop(context);
                  },
                  leading: Icon(
                    current == l
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  title: Text(l.label),
                  subtitle: Text('放大 ${(l.factor * 100).round()}%'),
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }
}

/// About / intro page (DESIGN.md §6).
class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('关于 Costr')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Center(
            child: Text(
              'Costr',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(height: 4),
          Center(
            child: Text(
              'Costr = Chinese Nostr',
              style: TextStyle(
                fontSize: 13,
                color: CostrColors.of(context).text2,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Center(
            child: Text(
              '更适合中文用户的 Nostr 开源社交客户端',
              style: TextStyle(
                fontSize: 14,
                color: CostrColors.of(context).text2,
              ),
            ),
          ),
          const SizedBox(height: 18),
          _IntroCard(
            icon: Icons.shield,
            title: '没有人能删你的帖子',
            body: '你发的帖子分布在全网多台服务器上，没有任何人——包括 Costr 自己——能删除、封号或限流。',
          ),
          _IntroCard(
            icon: Icons.lock_outline,
            title: '匿名，一把钥匙就是身份',
            body:
                '不用手机号、不用邮箱、不实名。一串钥匙就是你的整个账号，不绑定任何现实身份。'
                '想更进一步隐身？搭配 VPN 代理服务一起用——中继只能看到代理的地址，'
                '看不到你的真实网络位置，匿名保障更高。',
          ),
          _IntroCard(
            icon: Icons.dns_outlined,
            title: '你的钥匙，你做主',
            body: '私钥只存在你这台手机里，不上传任何服务器。没有公司能替你发帖，也没有平台能封你——像自己开了个广播站。',
          ),
          _IntroCard(
            icon: Icons.adjust,
            title: '简单、克制、不打扰',
            body: '默认值就是最好的设置，开箱即用，不用折腾一堆开关。',
          ),
          const SizedBox(height: 18),
          const _NostrProtocolDiagram(),
          const SizedBox(height: 14),
          const _ExplainCard(
            title: '发帖＝写进你的「发件箱」中继',
            body:
                '每个 Nostr 用户为自己挑几台中继服务器，当作自己的「发件箱」（outbox）。'
                '你发的帖子会写进你自己的发件箱中继——就像在自己开的公告栏上贴告示，'
                '而不是漫天撒网。Costr 同时连着好几台中继，所以任何一台掉线、跑路，'
                '其他中继照常替你保管分发，帖子不会丢、不会断。',
          ),
          const _ExplainCard(
            title: '看帖＝去别人的「发件箱」取',
            body:
                '想看 A 的帖子，就去 A 的发件箱中继订阅——就像去 A 的公告栏看告示，'
                '而不是等告示飞到你面前。A 用一张「中继清单」（NIP-65）告诉全网'
                '「我的发件箱在哪几台中继」，Costr 按这张清单找过去取。你关注了谁，'
                '就去谁的发件箱取。私信等只给特定人的内容，则写到对方的「收件箱」'
                '（inbox）中继（NIP-17），只有对方能收到。没有中心服务器，谁也拦不下这条路径。',
          ),
          const SizedBox(height: 18),
          Text(
            'Costr · 更适合中文用户的 Nostr 开源社交客户端\n'
            'Nostr 是一个去中心化开放社交协议\n'
            'Costr 应用代码开源，谁都能审计',
            style: TextStyle(
              fontSize: 12,
              color: CostrColors.of(context).text3,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          const _AcknowledgmentsSection(),
        ],
      ),
    );
  }
}

/// 致谢 — 感谢 Nostr 协议社区、重点参考的 Amethyst/Jumble 客户端，以及
/// Costr 使用的开源项目。Markdown 渲染（链接可点）。
class _AcknowledgmentsSection extends StatelessWidget {
  const _AcknowledgmentsSection();

  static const String _md = '''
Costr 的诞生离不开 Nostr 生态与众多开源项目。

## Nostr 协议与社区

感谢 [Nostr 协议](https://github.com/nostr-protocol/nips) 及其开源社区——一套自由、抗审查、无需账号的社交协议，让 Costr 这种独立客户端成为可能。

## 重点参考的客户端

Costr 在协议实现与渲染上重点参考了两个出色的开源 Nostr 客户端：

- **[Amethyst](https://github.com/vitorpamplona/amethyst)**（作者 Vitor Pamplona）——Android 端功能最全的 Nostr 客户端。Costr 的 NIP-51 列表（关注集 / 兴趣集 / 书签 / 屏蔽列表，含 NIP-44 私密列表）、NIP-09 删除、NIP-65 outbox 路由、NIP-57 Zap 等数据模型均与其对齐，确保用户在两个客户端间无缝迁移。
- **[Jumble](https://github.com/CodyTseng/jumble)**（作者 CodyTseng）——跨平台 Nostr 客户端，其 UI/交互设计与渲染思路为 Costr 提供了借鉴。

## Costr 使用的开源项目

- **Flutter**——跨平台 UI 框架，一套 Dart 代码覆盖 Android / iOS / Windows / macOS / Linux。
- **协议与密码学**：[bip340](https://pub.dev/packages/bip340)、[pointycastle](https://pub.dev/packages/pointycastle)、[crypto](https://pub.dev/packages/crypto)、[hex](https://pub.dev/packages/hex)。
- **网络**：[web_socket_channel](https://pub.dev/packages/web_socket_channel)、[http](https://pub.dev/packages/http)。
- **状态与路由**：[flutter_riverpod](https://pub.dev/packages/flutter_riverpod)、[go_router](https://pub.dev/packages/go_router)。
- **本地存储与安全**：[drift](https://pub.dev/packages/drift)、[sqlite3_flutter_libs](https://pub.dev/packages/sqlite3_flutter_libs)、[flutter_secure_storage](https://pub.dev/packages/flutter_secure_storage)、[local_auth](https://pub.dev/packages/local_auth)、[path_provider](https://pub.dev/packages/path_provider)。
- **UI 与媒体**：[cached_network_image](https://pub.dev/packages/cached_network_image)、[flutter_markdown](https://pub.dev/packages/flutter_markdown)、[video_player](https://pub.dev/packages/video_player)、[image_cropper](https://pub.dev/packages/image_cropper)、[qr_flutter](https://pub.dev/packages/qr_flutter)、[gal](https://pub.dev/packages/gal)、[file_picker](https://pub.dev/packages/file_picker)、[share_plus](https://pub.dev/packages/share_plus)、[url_launcher](https://pub.dev/packages/url_launcher)。

*Costr 是开源软件，欢迎在 [GitHub](https://github.com/costr1024/costr) 反馈与贡献。*
''';

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            '致谢',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: CostrColors.of(context).text2,
            ),
          ),
        ),
        MarkdownBody(
          data: _md,
          styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
            p: TextStyle(fontSize: 14, color: CostrColors.of(context).text),
            h2: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: CostrColors.of(context).text,
            ),
            a: TextStyle(color: Theme.of(context).colorScheme.primary),
          ),
        ),
      ],
    );
  }
}

/// Plain-language explanation card (no icon — text-focused).
class _ExplainCard extends StatelessWidget {
  const _ExplainCard({required this.title, required this.body});
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: CostrColors.of(context).bg2,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Text(
            body,
            style: TextStyle(
              fontSize: 13.5,
              color: CostrColors.of(context).text2,
              height: 1.6,
            ),
          ),
        ],
      ),
    );
  }
}

/// A simple Nostr protocol principle diagram: 3 user apps (left) connected
/// many-to-many to 3 relays (right). Shows that every app talks to several
/// relays, and relays forward between each other — no central server.
class _NostrProtocolDiagram extends StatelessWidget {
  const _NostrProtocolDiagram();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border.all(color: CostrColors.of(context).border),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          Text(
            'Nostr 协议原理',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: CostrColors.of(context).text2,
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 150,
            child: CustomPaint(
              size: Size.infinite,
              painter: _ProtocolPainter(
                lineColor: CostrColors.of(context).border,
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Column(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: const [
                      _NodeLabel(icon: Icons.smartphone, label: '你'),
                      _NodeLabel(icon: Icons.smartphone, label: 'A'),
                      _NodeLabel(icon: Icons.smartphone, label: 'B'),
                    ],
                  ),
                  Column(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: const [
                      _NodeLabel(icon: Icons.dns_outlined, label: '中继1'),
                      _NodeLabel(icon: Icons.dns_outlined, label: '中继2'),
                      _NodeLabel(icon: Icons.dns_outlined, label: '中继3'),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            '每个 app 同时连多台中继；你把帖子写进自己的「发件箱」中继，别人去你的发件箱取。没有中心服务器。',
            style: TextStyle(
              fontSize: 12,
              color: CostrColors.of(context).text3,
              height: 1.5,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _NodeLabel extends StatelessWidget {
  const _NodeLabel({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: CostrColors.of(context).text2),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(fontSize: 12, color: CostrColors.of(context).text2),
        ),
      ],
    );
  }
}

/// Draws many-to-many lines between 3 left nodes (apps) and 3 right nodes (relays).
class _ProtocolPainter extends CustomPainter {
  _ProtocolPainter({required this.lineColor});
  final Color lineColor;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = lineColor
      ..strokeWidth = 1;
    const n = 3;
    final dx = size.width;
    for (int i = 0; i < n; i++) {
      final yL = size.height * (i + 0.5) / n;
      for (int j = 0; j < n; j++) {
        final yR = size.height * (j + 0.5) / n;
        canvas.drawLine(Offset(0, yL), Offset(dx, yR), paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// --- Helpers ---

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: CostrColors.of(context).text3,
      ),
    ),
  );
}

class _Row extends StatelessWidget {
  const _Row({
    required this.title,
    required this.subtitle,
    this.onTap,
    this.titleColor,
  });
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final Color? titleColor;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(color: CostrColors.of(context).border),
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 15,
                      color: titleColor ?? CostrColors.of(context).text,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 12,
                      color: CostrColors.of(context).text2,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: CostrColors.of(context).text3),
          ],
        ),
      ),
    );
  }
}

/// The logged-in account list (multi-account switcher). Tap a row to switch
/// the active account; long-press to remove an account from this device.
/// The active account shows a 「当前」 badge — only IT holds live connections
/// and notifications; switching tears the old account's subscriptions down
/// via the reactive identity chain.
class _AccountList extends ConsumerWidget {
  const _AccountList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accounts = ref.watch(accountsProvider).value;
    if (accounts == null || accounts.isEmpty) return const SizedBox.shrink();
    return Column(
      children: [
        for (final entry in accounts.accounts)
          _AccountTile(
            entry: entry,
            isActive: entry.pubkeyHex == accounts.activePubkey,
          ),
      ],
    );
  }
}

class _AccountTile extends ConsumerWidget {
  const _AccountTile({required this.entry, required this.isActive});

  final AccountEntry entry;
  final bool isActive;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final meta = ref.watch(metadataProvider(entry.pubkeyHex)).value;
    return InkWell(
      onTap: isActive ? null : () => _switchTo(context, ref),
      onLongPress: () => _confirmRemove(context, ref),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(color: CostrColors.of(context).border),
          ),
        ),
        child: Row(
          children: [
            Avatar(pubkey: entry.pubkeyHex, radius: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  DisplayName(
                    pubkey: entry.pubkeyHex,
                    meta: meta,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: isActive
                          ? FontWeight.w600
                          : FontWeight.normal,
                      color: CostrColors.of(context).text,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    shortenEntity(entry.npub),
                    style: TextStyle(
                      fontSize: 12,
                      color: CostrColors.of(context).text2,
                    ),
                  ),
                ],
              ),
            ),
            if (isActive)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: CostrColors.of(context).brand.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '当前',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: CostrColors.of(context).brand,
                  ),
                ),
              )
            else
              Icon(Icons.chevron_right, color: CostrColors.of(context).text3),
          ],
        ),
      ),
    );
  }

  Future<void> _switchTo(BuildContext context, WidgetRef ref) async {
    try {
      await ref.read(identityProvider.notifier).switchTo(entry.pubkeyHex);
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('切换失败：$e')));
    }
  }

  /// Remove-confirm sheet. Same teardown-safe pattern as [showLogoutSheet]:
  /// await the sheet's dismissal BEFORE mutating identity state, so the route
  /// refresh never rebuilds the tree under a mid-teardown sheet element.
  Future<void> _confirmRemove(BuildContext context, WidgetRef ref) async {
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('移除账号？', style: Theme.of(ctx).textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(
                isActive
                    ? '这是当前活跃账号。移除后它的私钥将从本机删除；'
                          '本地数据保留，下次用同一把私钥登录即可恢复。'
                    : '该账号的私钥将从这台手机移除。'
                          '本地数据保留，下次用同一把私钥登录即可恢复。',
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('取消'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      style: FilledButton.styleFrom(
                        backgroundColor: CostrColors.of(context).red,
                      ),
                      child: const Text('移除'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      await ref.read(identityProvider.notifier).removeAccount(entry.pubkeyHex);
      // Removing the LAST account leaves identity null → the router's refresh
      // listener redirects to /login; removing the active account activates
      // the next stored one and we stay on this page.
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('移除失败：$e')));
    }
  }
}

/// A LOCAL-only toggle row (never published to a relay). Styled like [_Row]
/// but with a [Switch] in place of the chevron. Used for client preferences
/// (代理媒体, 沉浸式浏览) that are no part of the Nostr identity.
class _LocalSwitchTile extends ConsumerWidget {
  const _LocalSwitchTile({
    required this.title,
    required this.subtitleOn,
    required this.subtitleOff,
    required this.enabled,
    required this.onChanged,
  });
  final String title;
  final String subtitleOn;
  final String subtitleOff;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: CostrColors.of(context).border)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 15,
                    color: CostrColors.of(context).text,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  enabled ? subtitleOn : subtitleOff,
                  style: TextStyle(
                    fontSize: 12,
                    color: CostrColors.of(context).text2,
                  ),
                ),
              ],
            ),
          ),
          Switch(value: enabled, onChanged: onChanged),
        ],
      ),
    );
  }
}

/// Footer version line (settings page bottom). Reads the running app's
/// version via package_info_plus so it always matches the actual build.
class _VersionFooter extends StatelessWidget {
  const _VersionFooter();

  static final Future<String> _label = _load();

  static Future<String> _load() async {
    final info = await PackageInfo.fromPlatform();
    return 'Costr v${info.version}';
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String>(
      future: _label,
      builder: (BuildContext context, AsyncSnapshot<String> snap) {
        final text = snap.data ?? 'Costr';
        return Text(
          text,
          style: Theme.of(context).textTheme.labelSmall,
          textAlign: TextAlign.center,
        );
      },
    );
  }
}

class _IntroCard extends StatelessWidget {
  const _IntroCard({
    required this.icon,
    required this.title,
    required this.body,
  });
  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        border: Border.all(color: CostrColors.of(context).border),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: CostrColors.of(context).bg2,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, size: 26),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  body,
                  style: TextStyle(
                    fontSize: 14,
                    color: CostrColors.of(context).text2,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
