/// Notification settings page (DESIGN.md §5.3).
/// 4 switches: 回复与提及 / 喜欢与转发 / 新关注者 / 整合通知.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';

class NotificationSettingsPage extends ConsumerWidget {
  const NotificationSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('通知设置')),
      body: ListView(
        children: [
          const _SectionHeader('哪些事要通知你'),
          _SwitchRow(
            title: '回复与提及',
            subtitle: '别人 @你 或回复你的帖子时通知',
            value: ref.watch(notifyRepliesMentionsProvider),
            onChanged: (v) =>
                ref.read(notifyRepliesMentionsProvider.notifier).set(v),
          ),
          _SwitchRow(
            title: '喜欢与转发',
            subtitle: '别人喜欢、转发你的帖子时通知',
            value: ref.watch(notifyLikesRepostsProvider),
            onChanged: (v) =>
                ref.read(notifyLikesRepostsProvider.notifier).set(v),
          ),
          _SwitchRow(
            title: '新关注者',
            subtitle: '有人开始关注你时通知',
            value: ref.watch(notifyNewFollowersProvider),
            onChanged: (v) =>
                ref.read(notifyNewFollowersProvider.notifier).set(v),
          ),
          _SwitchRow(
            title: '整合通知',
            subtitle: '同一帖子的多条互动合并成一条，少打扰你',
            value: ref.watch(aggregateNotificationsProvider),
            onChanged: (v) =>
                ref.read(aggregateNotificationsProvider.notifier).set(v),
          ),
          const _SectionHeader('提示'),
          const _InfoRow(
            title: '不在后台盯着你',
            subtitle: 'App 在后台时不会偷偷保持连接，回到前台才会拉取新通知，省电。',
          ),
          const _InfoRow(
            title: '只有最近 200 条帖子会被监听',
            subtitle: '太老的帖子基本不再有人互动，不再监听，省流量。',
          ),
          const SizedBox(height: 20),
          Text(
            '所有通知只存在你这台手机上。Costr 不收集、不上传你的通知记录。',
            style: TextStyle(
              fontSize: 12,
              color: CostrColors.of(context).text3,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

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

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });
  final String title;
  final String subtitle;
  final bool value;
  final void Function(bool) onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: CostrColors.of(context).border)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontSize: 15)),
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
          Switch(
            value: value,
            onChanged: onChanged,
            activeThumbColor: CostrColors.of(context).green,
          ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.title, required this.subtitle});
  final String title;
  final String subtitle;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: CostrColors.of(context).border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontSize: 15)),
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
    );
  }
}
