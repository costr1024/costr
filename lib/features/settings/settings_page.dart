/// Settings page (DESIGN.md §7 — 通知/账号/服务器/关于/退出登录).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../auth/login_page.dart' show showLogoutSheet;

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        children: [
          const _SectionHeader('通用'),
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
          const _SectionHeader('关于'),
          _Row(
            title: '关于 Costr',
            subtitle: '是什么、设计理念',
            onTap: () => context.push('/about'),
          ),
          const _SectionHeader('账号'),
          _Row(
            title: '退出登录',
            titleColor: CostrColors.red,
            subtitle: '保留本地数据，下次可恢复',
            onTap: () => showLogoutSheet(context, ref),
          ),
          const SizedBox(height: 24),
          Text(
            'Costr = Chinese Nostr\n'
            '更适合中文用户的 Nostr 开源社交客户端',
            style: Theme.of(context).textTheme.labelSmall,
            textAlign: TextAlign.center,
          ),
        ],
      ),
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
              style: TextStyle(fontSize: 13, color: CostrColors.text2),
            ),
          ),
          const SizedBox(height: 8),
          Center(
            child: Text(
              '更适合中文用户的 Nostr 开源社交客户端',
              style: TextStyle(fontSize: 14, color: CostrColors.text2),
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
            body: '不用手机号、不用邮箱、不实名。一串钥匙就是你的整个账号，不绑定任何现实身份。',
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
            style: TextStyle(fontSize: 12, color: CostrColors.text3),
            textAlign: TextAlign.center,
          ),
        ],
      ),
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
        color: CostrColors.bg2,
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
              color: CostrColors.text2,
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
        border: Border.all(color: CostrColors.border),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          Text(
            'Nostr 协议原理',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: CostrColors.text2,
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 150,
            child: CustomPaint(
              size: Size.infinite,
              painter: _ProtocolPainter(),
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
              color: CostrColors.text3,
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
        Icon(icon, size: 16, color: CostrColors.text2),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(fontSize: 12, color: CostrColors.text2)),
      ],
    );
  }
}

/// Draws many-to-many lines between 3 left nodes (apps) and 3 right nodes (relays).
class _ProtocolPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = CostrColors.border
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
        color: CostrColors.text3,
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
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: CostrColors.border)),
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
                      color: titleColor ?? CostrColors.text,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(fontSize: 12, color: CostrColors.text2),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: CostrColors.text3),
          ],
        ),
      ),
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
        border: Border.all(color: CostrColors.border),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: CostrColors.bg2,
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
                    color: CostrColors.text2,
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
